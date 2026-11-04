import Foundation

enum AutoLearnTextNormalizer {
    /// Produces a comparison-only representation of text exposed by editable
    /// web controls. The original field value remains untouched for anchoring.
    static func accessibilityComparable(_ text: String) -> String {
        let normalizedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")

        let normalizedBlankLines = normalizedLineEndings
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let value = String(line)
                return value.trimmingCharacters(in: .whitespaces).isEmpty ? "" : value
            }
            .joined(separator: "\n")

        return normalizedBlankLines
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

/// Finds pasted text in a field whose editor rewrote the whitespace, e.g. a
/// rich-text composer that turns blank lines between paragraphs into single
/// paragraph breaks. Compares with every whitespace run collapsed to one
/// space and maps the match back to the field's own UTF-16 range.
enum AutoLearnPastedRangeLocator {
    static func whitespaceInsensitiveRange(
        of pastedText: String,
        in fieldText: String,
        nearUTF16Location caretLocation: Int?
    ) -> NSRange? {
        let needle = collapsed(pastedText).text
        guard !needle.isEmpty else { return nil }
        let haystack = collapsed(fieldText)
        let collapsedField = haystack.text as NSString

        var matches: [NSRange] = []
        var searchLocation = 0
        while searchLocation < collapsedField.length {
            let match = collapsedField.range(
                of: needle,
                options: .literal,
                range: NSRange(location: searchLocation, length: collapsedField.length - searchLocation)
            )
            guard match.location != NSNotFound else { break }
            let start = haystack.startOffsets[match.location]
            let end = haystack.endOffsets[NSMaxRange(match) - 1]
            matches.append(NSRange(location: start, length: end - start))
            searchLocation = match.location + 1
        }

        if matches.count == 1 { return matches[0] }
        guard let caretLocation,
            let nearest = matches.min(by: {
                abs(NSMaxRange($0) - caretLocation) < abs(NSMaxRange($1) - caretLocation)
            })
        else { return nil }
        let maximumDistance = max(pastedText.utf16.count, 128)
        return abs(NSMaxRange(nearest) - caretLocation) <= maximumDistance ? nearest : nil
    }

    /// Trimmed text with whitespace runs as single spaces and zero-width
    /// characters removed, plus the original UTF-16 bounds of every unit.
    private static func collapsed(
        _ text: String
    ) -> (text: String, startOffsets: [Int], endOffsets: [Int]) {
        var result = ""
        var startOffsets: [Int] = []
        var endOffsets: [Int] = []
        var pendingWhitespace: (start: Int, end: Int)?
        var offset = 0

        for character in text {
            let length = character.utf16.count
            let characterStart = offset
            offset += length
            if character == "\u{200B}" || character == "\u{FEFF}" { continue }
            if character.isWhitespace {
                pendingWhitespace = (pendingWhitespace?.start ?? characterStart, offset)
                continue
            }
            if let whitespace = pendingWhitespace, !result.isEmpty {
                result.append(" ")
                startOffsets.append(whitespace.start)
                endOffsets.append(whitespace.end)
            }
            pendingWhitespace = nil
            result.append(character)
            for _ in 0..<length {
                startOffsets.append(characterStart)
                endOffsets.append(offset)
            }
        }
        return (result, startOffsets, endOffsets)
    }
}

enum AutoLearnReviewResponse {
    /// Models sometimes wrap the array in a code fence or prepend hidden
    /// reasoning. Keep only the outermost JSON array; the strict decoder still
    /// validates every decision.
    static func decisionArrayPayload(from text: String) -> String {
        var payload = text
        while let thinkStart = payload.range(of: "<think>"),
            let thinkEnd = payload.range(of: "</think>", range: thinkStart.upperBound..<payload.endIndex)
        {
            payload.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.hasPrefix("["),
            let arrayStart = payload.firstIndex(of: "["),
            let arrayEnd = payload.lastIndex(of: "]"),
            arrayStart < arrayEnd
        else {
            return payload
        }
        return String(payload[arrayStart...arrayEnd])
    }
}

/// Deterministic check that a learned replacement is a misrecognition and not
/// a content change such as "Linear" → "Notion". Uses the Cologne phonetic
/// code, which also fits English terms spoken in German well enough to
/// separate similar-sounding renderings from unrelated words. Similar-sounding
/// content changes ("Simulator" → "Emulator") pass; the reviewer prompt
/// rejects those.
enum AutoLearnPhoneticGate {
    static let minimumSimilarity = 0.5

    static func soundsAlike(_ original: String, _ corrected: String) -> Bool {
        similarity(original, corrected) >= minimumSimilarity
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(code(for: lhs))
        let right = Array(code(for: rhs))
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(left, right)) / Double(longest)
    }

    static func code(for text: String) -> String {
        let letters = Array(
            text.lowercased()
                .replacingOccurrences(of: "ß", with: "s")
                .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_DE"))
                .filter { $0.isLetter && $0.isASCII }
        )
        var raw: [Character] = []
        for (index, letter) in letters.enumerated() {
            let previous: Character? = index > 0 ? letters[index - 1] : nil
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            switch letter {
            case "a", "e", "i", "j", "o", "u", "y":
                raw.append("0")
            case "h":
                continue
            case "b":
                raw.append("1")
            case "p":
                raw.append(next == "h" ? "3" : "1")
            case "d", "t":
                raw.append(next.map { "csz".contains($0) } == true ? "8" : "2")
            case "f", "v", "w":
                raw.append("3")
            case "g", "k", "q":
                raw.append("4")
            case "c":
                if let previous {
                    let hard = next.map { "ahkoqux".contains($0) } == true
                    raw.append(hard && !"sz".contains(previous) ? "4" : "8")
                } else {
                    raw.append(next.map { "ahkloqrux".contains($0) } == true ? "4" : "8")
                }
            case "x":
                if let previous, "ckq".contains(previous) {
                    raw.append("8")
                } else {
                    raw.append(contentsOf: ["4", "8"])
                }
            case "l":
                raw.append("5")
            case "m", "n":
                raw.append("6")
            case "r":
                raw.append("7")
            case "s", "z":
                raw.append("8")
            default:
                continue
            }
        }

        var collapsed: [Character] = []
        for digit in raw where collapsed.last != digit {
            collapsed.append(digit)
        }
        return String(collapsed.enumerated().filter { $0.offset == 0 || $0.element != "0" }.map(\.element))
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

struct AutoLearnPasteToken: Hashable, Sendable {
    let id: UUID
}

struct AutoLearnRevision: Sendable {
    let original: String
    let corrected: String
}

struct AutoLearnFieldSnapshot: Sendable {
    let baselineFieldText: String
    let finalFieldText: String
    let pastedRange: NSRange
    let originalPastedText: String
    /// Where the dictation sits in `finalFieldText`.
    let finalPastedRange: NSRange
    /// Where `finalFieldText` came from, for privacy-safe diagnostics.
    var finalTextSource: String = "final"

    var finalDictationText: String? {
        let field = finalFieldText as NSString
        let range = finalPastedRange
        guard range.location != NSNotFound,
            range.location >= 0,
            range.length > 0,
            range.length <= field.length - range.location
        else {
            return nil
        }
        return field.substring(with: range)
    }

    var dictationIsUnchanged: Bool {
        finalDictationText.map { $0.utf16.elementsEqual(originalPastedText.utf16) } ?? false
    }
}

enum AutoLearnCaptureOutcome: Sendable {
    case captured(AutoLearnPasteToken)
    /// The field was not readable yet; Chromium and Electron build their
    /// accessibility tree asynchronously, so a later attempt may succeed.
    case retryable
    case rejected
}

struct DetectedCorrectionCandidate: Hashable, Sendable {
    let originalText: String
    let correctedText: String
}

struct AutoLearnReviewCandidate: Sendable {
    let candidateID: UUID
    let originalText: String
    let correctedText: String
}

enum AutoLearnReviewAction: String, Codable, Sendable {
    case addReplacementAndVocabulary
    case addReplacementOnly
    case addVocabularyOnly
    case rejectCorrection
}

struct AutoLearnReviewDecision: Sendable {
    let candidateID: UUID
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

enum AutoLearnUnresolvedReason: String, Sendable {
    case missingDecision
    case conflictingDecisions
    case missingRequiredActionValues
    case invalidRequiredActionValues
}

struct AutoLearnUnresolvedReview: Sendable {
    let candidateID: UUID
    let reason: AutoLearnUnresolvedReason
    let learningAction: AutoLearnReviewAction?
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

struct AutoLearnReviewResult: Sendable {
    let reviewDecisions: [AutoLearnReviewDecision]
    let unresolvedReviews: [AutoLearnUnresolvedReview]
}

struct AutoLearnReviewProposal: Codable, Identifiable, Sendable {
    let id: UUID
    let candidateID: UUID
    let originalText: String
    let correctedText: String
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?

    var addsReplacement: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addReplacementOnly
    }

    var addsVocabulary: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addVocabularyOnly
    }

    var reviewCandidate: AutoLearnReviewCandidate {
        AutoLearnReviewCandidate(
            candidateID: candidateID,
            originalText: originalText,
            correctedText: correctedText
        )
    }

    var reviewDecision: AutoLearnReviewDecision {
        AutoLearnReviewDecision(
            candidateID: candidateID,
            learningAction: learningAction,
            incorrectTextToReplace: incorrectTextToReplace,
            correctedVocabularyTerm: correctedVocabularyTerm
        )
    }
}

struct AutoLearnReviewSelection: Sendable {
    let proposalID: UUID
    let includesReplacement: Bool
    let includesVocabulary: Bool
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String
}

struct AutoLearnMutationSummary: Sendable {
    let createdCount: Int
    let updatedCount: Int
    let vocabularyCount: Int
    let learnedCorrections: [AutoLearnAppliedCorrection]

    var hasChanges: Bool {
        createdCount > 0 || updatedCount > 0 || vocabularyCount > 0
    }

    static let empty = AutoLearnMutationSummary(
        createdCount: 0,
        updatedCount: 0,
        vocabularyCount: 0,
        learnedCorrections: []
    )
}

struct AutoLearnAppliedCorrection: Sendable {
    let incorrectTextToReplace: String
    let correctedVocabularyTerm: String
    let replacementSourceWasAdded: Bool
    let vocabularyCreationDate: Date?
}

enum AutoLearnReviewSchedule: String, CaseIterable, Identifiable {
    case immediately
    case manually

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .manually: String(localized: "Manually")
        }
    }

}

enum AutoLearnLimits {
    /// Observation ends this long after the latest paste unless the field is
    /// sent or left first; reading a long dictation back takes a while.
    static let observationDurationNanoseconds: UInt64 = 120_000_000_000
    static let verificationDelayNanoseconds: UInt64 = 120_000_000
    /// Waits before each further capture attempt (about 5 s in total): a
    /// large Electron window can need seconds to build its accessibility tree.
    static let captureRetryDelaysNanoseconds: [UInt64] = [
        250_000_000, 400_000_000, 600_000_000, 900_000_000, 1_200_000_000, 1_500_000_000,
    ]
    /// Fallback sampling for apps that do not post value-change notifications.
    static let fieldSampleIntervalNanoseconds: UInt64 = 1_000_000_000
    static let focusChangeGraceNanoseconds: UInt64 = 250_000_000
    static let accessibilityTimeoutSeconds: Float = 0.20
    static let captureAccessibilityTimeoutSeconds: Float = 0.25
    static let maximumFieldUTF16Length = 100_000
    /// Dictations into one field observed together until it is sent or left.
    static let maximumTrackedDictations = 12
    /// Above this many changed UTF-16 units between two samples, the change
    /// is treated as one edit instead of being diffed in detail.
    static let maximumSplitDiffUTF16Length = 4_000
    static let maximumPastedCharacters = 12_000
    static let maximumDiffSegments = 2_048
    static let maximumCandidateCharacters = 256
    static let maximumCandidateSegments = 24
    static let reviewContextSegmentsPerSide = 3
    static let maximumUnspacedCandidateCharacters = 32
    static let maximumReviewBatchCandidates = 100
}

enum AutoLearnProviderPolicy {
    static func isSupported(_ provider: AIProvider) -> Bool {
        provider.supportsEnhancement
            && provider != .voiceInkRefine
    }
}
