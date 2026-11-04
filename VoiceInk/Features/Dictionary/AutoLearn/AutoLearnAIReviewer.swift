import Foundation
import LLMkit
import OSLog

@MainActor
final class AutoLearnAIReviewer: @unchecked Sendable {
    private struct AutoLearnReviewRequest: Encodable {
        struct CandidateForReview: Encodable {
            let candidateID: Int
            let originalText: String
            let correctedText: String
        }

        let candidatesForReview: [CandidateForReview]
    }

    private struct CandidateReviewDecision: Decodable {
        let candidateID: Int
        let learningAction: AutoLearnReviewAction
        let incorrectTextToReplace: String?
        let correctedVocabularyTerm: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case candidateID
            case learningAction
            case incorrectTextToReplace
            case correctedVocabularyTerm
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let returnedKeys = Set(container.allKeys.map(\.stringValue))
            let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
            guard returnedKeys == expectedKeys else {
                throw DecodingError.dataCorruptedError(
                    forKey: .candidateID,
                    in: container,
                    debugDescription: "Each decision must contain exactly the four required fields."
                )
            }

            candidateID = try container.decode(Int.self, forKey: .candidateID)
            learningAction = try container.decode(AutoLearnReviewAction.self, forKey: .learningAction)
            incorrectTextToReplace = try container.decodeIfPresent(
                String.self,
                forKey: .incorrectTextToReplace
            )
            correctedVocabularyTerm = try container.decodeIfPresent(
                String.self,
                forKey: .correctedVocabularyTerm
            )
        }
    }

    private enum ReviewError: LocalizedError {
        case unavailable
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(
                    localized: "The configured AI enhancement provider cannot review Auto Learn candidates."
                )
            case .invalidResponse:
                return String(localized: "The AI returned an invalid Auto Learn review response.")
            }
        }
    }

    private let enhancementService: AIEnhancementService
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AutoLearnAIReview"
    )

    init(enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }

    /// True when a review could run right now. Used to defer queued reviews
    /// while providers are still starting up instead of recording a failure.
    var hasAvailableProvider: Bool {
        guard let aiService = enhancementService.getAIService() else { return false }
        let connectedProviders = availableProviders(in: aiService)
        if let selected = AutoLearnSettings.selectedProvider {
            return connectedProviders.contains(selected)
        }
        return !connectedProviders.isEmpty
    }

    func review(_ candidates: [AutoLearnReviewCandidate]) async throws -> AutoLearnReviewResult {
        guard !candidates.isEmpty else {
            return AutoLearnReviewResult(reviewDecisions: [], unresolvedReviews: [])
        }
        guard let aiService = enhancementService.getAIService() else {
            throw ReviewError.unavailable
        }

        let connectedProviders = availableProviders(in: aiService)
        // Respect the user's provider choice. Ollama keeps correction review on-device.
        guard let provider = AutoLearnSettings.selectedProvider ?? connectedProviders.first,
            connectedProviders.contains(provider)
        else {
            throw ReviewError.unavailable
        }
        let modelName = AutoLearnSettings.selectedModel ?? aiService.selectedModel(for: provider)

        let candidatesForReview = candidates.enumerated().map { index, candidate in
            AutoLearnReviewRequest.CandidateForReview(
                candidateID: index,
                originalText: candidate.originalText,
                correctedText: candidate.correctedText
            )
        }
        let requestData = try JSONEncoder().encode(
            AutoLearnReviewRequest(candidatesForReview: candidatesForReview)
        )
        let requestText = String(decoding: requestData, as: UTF8.self)

        let loggedModelName = modelName ?? "provider-default"
        logger.notice(
            "Auto Learn review started provider=\(provider.rawValue, privacy: .public) model=\(loggedModelName, privacy: .public) candidates=\(candidates.count, privacy: .public)"
        )
        let fallback = reviewFallback(for: provider, modelName: modelName, in: aiService)
        let responseText: String
        do {
            responseText = try await aiService.reviewAutoLearnCandidates(
                payload: requestText,
                systemPrompt: Self.reviewPrompt,
                provider: provider,
                modelName: modelName,
                clientRetries: fallback == nil
            )
        } catch {
            // Groq's free tier shares a small per-minute token budget with
            // dictation enhancement; a refused review moves to Cerebras like
            // the enhancement does instead of failing.
            guard let fallback, Self.isProviderRefusal(error) else { throw error }
            logger.notice(
                "Auto Learn review falling back provider=\(fallback.provider.rawValue, privacy: .public) model=\(fallback.model, privacy: .public)"
            )
            responseText = try await aiService.reviewAutoLearnCandidates(
                payload: requestText,
                systemPrompt: Self.reviewPrompt,
                provider: fallback.provider,
                modelName: fallback.model
            )
        }
        let candidateReviewDecisions = try decodeResponse(
            responseText,
            provider: provider,
            modelName: loggedModelName
        )
        let expectedCandidateIDs = Set(candidates.indices)
        let decisionsByCandidateID = Dictionary(grouping: candidateReviewDecisions) {
            $0.candidateID
        }
        let correctedContexts = candidates.map(\.correctedText)
        for unknownCandidateID in decisionsByCandidateID.keys
        where !expectedCandidateIDs.contains(unknownCandidateID) {
            logger.warning(
                "Ignoring Auto Learn decision with unknown candidate ID=\(unknownCandidateID, privacy: .public)"
            )
        }

        var reviewDecisions: [AutoLearnReviewDecision] = []
        var unresolvedReviews: [AutoLearnUnresolvedReview] = []

        for (index, candidate) in candidates.enumerated() {
            guard let matchingDecisions = decisionsByCandidateID[index] else {
                unresolvedReviews.append(
                    unresolvedReview(for: candidate, reason: .missingDecision)
                )
                continue
            }

            // One diff candidate can contain adjacent corrections with no
            // unchanged token between them. Let the reviewer separate those
            // terms, but never mix an accepted correction with a rejection.
            if matchingDecisions.count > 1,
                matchingDecisions.contains(where: { $0.learningAction == .rejectCorrection })
            {
                unresolvedReviews.append(
                    unresolvedReview(
                        for: candidate,
                        reason: .conflictingDecisions,
                        decision: matchingDecisions.first
                    )
                )
                continue
            }

            var validatedDecisions: [AutoLearnReviewDecision] = []
            var unresolvedDecision: AutoLearnUnresolvedReview?
            for decision in matchingDecisions {
                let validation = validate(
                    decision,
                    for: candidate,
                    correctedContexts: correctedContexts
                )
                guard let validatedDecision = validation.decision else {
                    unresolvedDecision = unresolvedReview(
                        for: candidate,
                        reason: validation.failure ?? .invalidRequiredActionValues,
                        decision: decision
                    )
                    break
                }
                validatedDecisions.append(validatedDecision)
            }

            if let unresolvedDecision {
                unresolvedReviews.append(unresolvedDecision)
            } else if !decisionsAreIndependent(validatedDecisions, for: candidate) {
                unresolvedReviews.append(
                    unresolvedReview(
                        for: candidate,
                        reason: .conflictingDecisions,
                        decision: matchingDecisions.first
                    )
                )
            } else {
                reviewDecisions.append(contentsOf: validatedDecisions)
            }
        }

        return AutoLearnReviewResult(
            reviewDecisions: reviewDecisions,
            unresolvedReviews: unresolvedReviews
        )
    }

    /// Same route as dictation enhancement (see `EnhancementFallbackRoute`).
    private func reviewFallback(
        for provider: AIProvider,
        modelName: String,
        in aiService: AIService
    ) -> (provider: AIProvider, model: String)? {
        guard let route = EnhancementFallbackRoute.fallback(
            forProvider: provider.rawValue,
            model: modelName
        ),
            let fallbackProvider = AIProvider(rawValue: route.provider),
            availableProviders(in: aiService).contains(fallbackProvider)
        else {
            return nil
        }
        return (fallbackProvider, route.model)
    }

    private static func isProviderRefusal(_ error: Error) -> Bool {
        guard let error = error as? LLMKitError else { return false }
        switch error {
        case .httpError(let statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        case .timeout:
            return true
        default:
            return false
        }
    }

    private func availableProviders(in aiService: AIService) -> [AIProvider] {
        aiService.connectedProviders.filter {
            AutoLearnProviderPolicy.isSupported($0)
                && ($0 != .ollama || !aiService.availableModels(for: $0).isEmpty)
        }
    }

    private func unresolvedReview(
        for candidate: AutoLearnReviewCandidate,
        reason: AutoLearnUnresolvedReason,
        decision: CandidateReviewDecision? = nil
    ) -> AutoLearnUnresolvedReview {
        AutoLearnUnresolvedReview(
            candidateID: candidate.candidateID,
            reason: reason,
            learningAction: decision?.learningAction,
            incorrectTextToReplace: decision?.incorrectTextToReplace,
            correctedVocabularyTerm: decision?.correctedVocabularyTerm
        )
    }

    private func validate(
        _ decision: CandidateReviewDecision,
        for candidate: AutoLearnReviewCandidate,
        correctedContexts: [String]
    ) -> (decision: AutoLearnReviewDecision?, failure: AutoLearnUnresolvedReason?) {
        if decision.learningAction == .rejectCorrection {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .rejectCorrection,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: nil
                ),
                nil
            )
        }

        guard let correctedVocabularyTerm = decision.correctedVocabularyTerm?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return (nil, .missingRequiredActionValues)
        }
        guard !correctedVocabularyTerm.isEmpty,
            correctedVocabularyTerm.count <= AutoLearnLimits.maximumCandidateCharacters,
            isGrounded(correctedVocabularyTerm, in: correctedContexts)
        else {
            return (nil, .invalidRequiredActionValues)
        }

        if decision.learningAction == .addVocabularyOnly {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .addVocabularyOnly,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: correctedVocabularyTerm
                ),
                nil
            )
        }

        guard let incorrectTextToReplace = decision.incorrectTextToReplace?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return (nil, .missingRequiredActionValues)
        }
        guard !incorrectTextToReplace.isEmpty,
            incorrectTextToReplace != correctedVocabularyTerm,
            incorrectTextToReplace.count <= AutoLearnLimits.maximumCandidateCharacters,
            !incorrectTextToReplace.contains(","),
            isExactSubstring(incorrectTextToReplace, of: candidate.originalText)
        else {
            return (nil, .invalidRequiredActionValues)
        }

        if differsOnlyByLetterCase(incorrectTextToReplace, correctedVocabularyTerm)
            || !AutoLearnPhoneticGate.soundsAlike(incorrectTextToReplace, correctedVocabularyTerm)
        {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .rejectCorrection,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: nil
                ),
                nil
            )
        }

        return (
            AutoLearnReviewDecision(
                candidateID: candidate.candidateID,
                learningAction: decision.learningAction,
                incorrectTextToReplace: incorrectTextToReplace,
                correctedVocabularyTerm: correctedVocabularyTerm
            ),
            nil
        )
    }

    private func differsOnlyByLetterCase(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private func isExactSubstring(_ term: String, of context: String) -> Bool {
        context.range(of: term, options: .literal) != nil
    }

    private func isGrounded(_ term: String, in contexts: [String]) -> Bool {
        contexts.contains { isExactSubstring(term, of: $0) }
    }

    private func decisionsAreIndependent(
        _ decisions: [AutoLearnReviewDecision],
        for candidate: AutoLearnReviewCandidate
    ) -> Bool {
        let originalTerms = decisions.compactMap(\.incorrectTextToReplace)
        guard canLocateWithoutOverlap(originalTerms, in: candidate.originalText) else {
            return false
        }

        // Batch canonicalization may intentionally return a corrected term
        // from another candidate, so only test terms present in this snippet.
        let localCorrectedTerms = decisions.compactMap(\.correctedVocabularyTerm).filter {
            isExactSubstring($0, of: candidate.correctedText)
        }
        return canLocateWithoutOverlap(localCorrectedTerms, in: candidate.correctedText)
    }

    private func canLocateWithoutOverlap(_ terms: [String], in text: String) -> Bool {
        guard terms.count > 1 else { return true }
        let text = text as NSString
        let rangesByTerm = terms.map { term -> [NSRange] in
            var matches: [NSRange] = []
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: term, options: .literal, range: searchRange)
                guard match.location != NSNotFound else { break }
                matches.append(match)
                let nextLocation = match.location + 1
                guard nextLocation < text.length else { break }
                searchRange = NSRange(
                    location: nextLocation,
                    length: text.length - nextLocation
                )
            }
            return matches
        }

        func assign(_ termIndex: Int, occupied: [NSRange]) -> Bool {
            guard termIndex < rangesByTerm.count else { return true }
            for range in rangesByTerm[termIndex]
            where occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) {
                if assign(termIndex + 1, occupied: occupied + [range]) {
                    return true
                }
            }
            return false
        }

        return assign(0, occupied: [])
    }

    private func decodeResponse(
        _ text: String,
        provider: AIProvider,
        modelName: String
    ) throws -> [CandidateReviewDecision] {
        let payload = AutoLearnReviewResponse.decisionArrayPayload(from: text)
        let data = Data(payload.utf8)

        do {
            return try JSONDecoder().decode([CandidateReviewDecision].self, from: data)
        } catch {
            let diagnostic = invalidResponseDiagnostic(for: data)
            logInvalidResponse(
                payload,
                provider: provider,
                modelName: modelName,
                reason: diagnostic.reason,
                shape: diagnostic.shape
            )
            throw ReviewError.invalidResponse
        }
    }

    private func logInvalidResponse(
        _ payload: String,
        provider: AIProvider,
        modelName: String,
        reason: String,
        shape: String = "unknown"
    ) {
        let preview = String(payload.prefix(1_000))
        logger.error(
            "Auto Learn response invalid provider=\(provider.rawValue, privacy: .public) model=\(modelName, privacy: .public) reason=\(reason, privacy: .public) shape=\(shape, privacy: .public) characters=\(payload.count, privacy: .public) responsePreview=\(preview, privacy: .private)"
        )
    }

    private func invalidResponseDiagnostic(for data: Data) -> (reason: String, shape: String) {
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return ("malformed-json", "invalid-json")
        }
        if value is [Any] { return ("invalid-decision-array", "array") }
        if value is [String: Any] { return ("expected-top-level-array", "object") }
        return ("unsupported-json-shape", "scalar")
    }

    private static let reviewPrompt = """
        Review speech-to-text corrections. Each candidate has originalText and correctedText containing the edit plus up to three surrounding words on each side. The text may be German, English, or a mix of both. The user corrected the recognizer's output by hand, so a correction that passes the gates below is evidence that the recognizer does not know the term.

        Mandatory personal-name rule: A personal name is one indivisible term. For a visible multiword personal name, incorrectTextToReplace and correctedVocabularyTerm must contain every visible name component, including every unchanged component. Apply this rule even when only a middle name, surname, particle, spacing, punctuation, or suffix changed. Returning only the changed fragment or one component of a visible multiword name is invalid. When only one personal-name component is visible, such as only a first name or only a surname, it may qualify for addReplacementOnly but must not be added to Vocabulary. Allow a single-word personal name into Vocabulary only when context clearly establishes that the person is genuinely known by that complete mononym, not merely because only one name component appears in the snippet. Never invent name components that are not visible.

        Identify every independently reusable correction. Usually return one decision per candidate. Separate adjacent independent terms. If learnable and ordinary edits are mixed, return only the learnable corrections. Return rejectCorrection only when nothing is learnable, and never mix rejection with acceptance for one candidateID.

        Before selecting an action, every acceptance must pass both gates:

        1. Phonetic evidence: the changed source and destination spans must recognizably resemble two renderings of the same spoken term. Judge a multiword personal name collectively. Differences caused by accent, transliteration, word boundaries, hyphenation, or omitted diacritics may still be phonetic when the pronunciations plausibly correspond. Related meaning, context, specificity, private status, and Vocabulary usefulness are not themselves phonetic evidence. Reject absent or uncertain resemblance.

        2. No semantic rewrite: reject edits that change meaning or replace coherent language—a description, role, category, purpose, location, relationship, criterion, synonym, or placeholder—with a specific person, place, product, service, or term. Discard them completely even when the destination qualifies for Vocabulary. A misrecognition that renders a name or term as similar-sounding ordinary words is not a semantic rewrite: "super base" → "Supabase", "Voice Inc" → "VoiceInk", "X code" → "Xcode", "Orka" → "Orca", "Klaud" → "Claude", "Wisper Flow" → "Wispr Flow". Replacing one real name, product, or word with a different one that does not sound alike ("Linear" → "Notion", "Slack" → "Teams", "Simulator" → "Emulator") is a content change, not a misrecognition; reject it.

        Only edits passing both gates may be accepted. Audit every acceptance against both gates before returning it; convert failures or uncertainty to rejectCorrection with both text fields null.

        Choose one learningAction:

        1. addReplacementAndVocabulary: the corrected term passes the Vocabulary gate and the original plausibly sounds like it.
        2. addReplacementOnly: use for a distinctive, unambiguous correction that is worth applying again but whose corrected term should not enter Vocabulary. This includes a learnable correction to a single visible first name or surname when the person's complete name is not visible. Never use this for ordinary dictionary words or generic terms.
        3. addVocabularyOnly: the corrected term passes the Vocabulary gate and the pair passes the phonetic gate, but the source is too broad or ambiguous for a safe global replacement. Never use this for a partial personal name, coherent descriptions, semantic rewrites, deliberate abbreviations, or expansions.
        4. rejectCorrection: nothing is safely reusable, including ordinary wording, grammar, inflection, word order, style, meaning, facts, numbers, dates, abbreviations, expansions, changed qualifiers, editions, generic type words, and edits where the original already was a correct rendering of what was said.

        Vocabulary is for terms the recognizer gets wrong: complete personal names, and non-person names and technical terms such as brands, companies, products, apps, services, projects, programming languages, frameworks, libraries, tools, commands, file formats, usernames, places, and domain jargon. A person's first name, surname, or other single component must not enter Vocabulary by itself unless it is clearly the person's complete mononym. This personal-name restriction does not apply to non-person terms.

        Use context to identify user-specific entities. “Call”, “email”, “ask”, “invite”, or “send to” supports interpreting the adjacent text as a personal name. For a phonetically plausible personal name, spelling, apostrophe, spacing, hyphenation, and diacritic corrections are learnable—not formatting-only edits. A personal name remains learnable when it belongs to a well-known or public person. Labels such as “project”, “internal”, “repository”, “account”, “tenant”, or “pipeline” similarly support a user-specific entity. Context never substitutes for phonetic evidence or permits a semantic rewrite.

        Learn brands, products, technologies, places, and organizations—well-known ones included, such as Supabase, Xcode, GitHub, PostgreSQL, Tailwind, or Kubernetes—whenever the original is a phonetic misrecognition of them; use addReplacementAndVocabulary when the misrecognized form is specific enough to replace safely, otherwise addVocabularyOnly. Spelling, spacing, joining, and capitalization inside such a term (for example "Git Hub" → "GitHub", "post gres" → "Postgres", "Voice Ink" → "VoiceInk") are learnable when the words also changed in spelling or spacing. Do not learn ordinary dictionary words of German or English (common nouns, verbs, adjectives, function words), even when they were misrecognized as another ordinary word. Capitalization or proper-noun appearance alone is insufficient; when uncertain, reject.

        Reject case-only changes and partial unsafe mappings.

        Batch canonicalization: when corrected terms are clearly spelling or pronunciation variants of one entity, use one corrected form already present in correctedText for all related acceptances. Prefer the most frequent, then most complete plausible form. Never invent a form or merge by meaning alone.

        For replacement actions, incorrectTextToReplace must be an exact nonempty contiguous substring of that candidate's originalText and correctedVocabularyTerm must be copied from correctedText, except canonicalization may copy it from another candidate. For addVocabularyOnly set incorrectTextToReplace to null. For rejectCorrection set both fields to null.

        Before returning a personal-name decision, treat a visible multiword name as one indivisible term and verify that both fields contain the complete original and corrected names, even if only one component changed. Example: "Prakash Joshi Pages" to "Prakash Joshi Pax" must use the complete names, never only "Pages" to "Pax". If only one first name or surname is visible and the correction is otherwise safe and learnable, return addReplacementOnly for that visible component. Do not add it to Vocabulary and do not reject it merely because the person's full name is unavailable. Use a Vocabulary action for a single-word personal name only when the context clearly identifies a genuine mononym.

        Return only one JSON array. Do not return an outer object, reviewDecisions key, explanation, Markdown, or code fence. Each array object must contain exactly these four fields: candidateID, learningAction, incorrectTextToReplace, and correctedVocabularyTerm.

        Exact output format:
        [{"candidateID":0,"learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"original term","correctedVocabularyTerm":"corrected term"},{"candidateID":1,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null}]

        Allowed actions are addReplacementAndVocabulary, addReplacementOnly, addVocabularyOnly, and rejectCorrection. Copy every integer candidateID exactly and return each input candidateID at least once. Repeat an ID only for independent accepted corrections.

        """
}
