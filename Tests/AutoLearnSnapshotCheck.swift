import Foundation

// Compile together with the Auto Learn engine files (see
// scripts/check-auto-learn.sh). Replays how a dictated field changes in chat
// apps and editors and checks which text Auto Learn hands to the reviewer.

enum AIProvider {
    case groq
    case voiceInkRefine

    var supportsEnhancement: Bool { true }
}

@main
struct AutoLearnSnapshotCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    /// The field contains only the dictation (typical chat composer).
    static func chatObservation(_ dictation: String) -> AutoLearnFieldObservation {
        AutoLearnFieldObservation(
            baselineFieldText: dictation,
            pastedRange: NSRange(location: 0, length: dictation.utf16.count),
            pastedText: dictation
        )
    }

    static func candidates(
        _ observation: AutoLearnFieldObservation,
        finalValue: String?
    ) -> (source: String, candidates: [DetectedCorrectionCandidate])? {
        let snapshot = observation.snapshot(finalValue: finalValue)
        guard let revision = FinalSnapshotDiffEngine.revision(from: snapshot) else {
            return (snapshot.finalTextSource, [])
        }
        return (snapshot.finalTextSource, CorrectionDiffEngine.candidates(from: revision))
    }

    static func learned(_ result: (source: String, candidates: [DetectedCorrectionCandidate])?) -> [String] {
        (result?.candidates ?? []).map { "\($0.originalText) → \($0.correctedText)" }
    }

    /// Observation of a dictation that sits at `prefix.count` in `field`.
    static func observing(_ text: String, after prefix: String, in field: String) -> AutoLearnFieldObservation {
        AutoLearnFieldObservation(
            baselineFieldText: field,
            pastedRange: NSRange(location: prefix.utf16.count, length: text.utf16.count),
            pastedText: text
        )
    }

    static func main() {
        let dictation = "Ich nutze super base für das Backend"
        let corrected = "Ich nutze Supabase für das Backend"

        // 1. Chat: correct, send (field cleared), start typing the next message.
        var chat = chatObservation(dictation)
        expect(chat.record(dictation) == .observed, "chat: pasted text is observed")
        expect(chat.record(corrected) == .observed, "chat: corrected text is observed")
        expect(chat.record("") == .disappeared, "chat: sending clears the field")
        expect(
            chat.record("Nächste Nachricht") == .ignoredAfterDisappearance,
            "chat: text typed after sending is ignored"
        )
        if let result = candidates(chat, finalValue: "Nächste Nachricht") {
            expect(result.source == "last-observed-before-clear", "chat: uses the text before sending")
            expect(
                result.candidates.count == 1
                    && result.candidates[0].originalText.contains("super base")
                    && result.candidates[0].correctedText.contains("Supabase"),
                "chat: one candidate super base → Supabase"
            )
        } else {
            expect(false, "chat: snapshot available after sending")
        }

        // 2. Before this change the final read alone saw an empty field.
        let clearedSnapshot = AutoLearnFieldSnapshot(
            baselineFieldText: dictation,
            finalFieldText: "",
            pastedRange: NSRange(location: 0, length: dictation.utf16.count),
            originalPastedText: dictation,
            finalPastedRange: NSRange(location: 0, length: 0)
        )
        expect(
            FinalSnapshotDiffEngine.revision(from: clearedSnapshot) == nil,
            "cleared field is not treated as a correction"
        )

        // 3. Editor with surrounding text: the final read wins when it still anchors.
        let before = "Hallo Team,\n"
        let after = "\nViele Grüße"
        let baseline = before + dictation + after
        var editor = AutoLearnFieldObservation(
            baselineFieldText: baseline,
            pastedRange: NSRange(location: before.utf16.count, length: dictation.utf16.count),
            pastedText: dictation
        )
        _ = editor.record(baseline)
        let finalEditor = before + corrected + after + "\nPS: bis morgen"
        if let result = candidates(editor, finalValue: finalEditor) {
            expect(result.source == "final", "editor: final read is used while anchors hold")
            expect(
                result.candidates.contains { $0.correctedText.contains("Supabase") },
                "editor: correction is detected"
            )
        } else {
            expect(false, "editor: snapshot available")
        }

        // 4. Field became unreadable (element re-created) after a correction.
        var rerendered = chatObservation(dictation)
        _ = rerendered.record(corrected)
        expect(
            rerendered.snapshot(finalValue: nil).finalTextSource == "last-observed-unreadable",
            "unreadable final field falls back to the last observation"
        )

        // 5. Holding backspace: the truncated dictation is not a correction.
        var deleting = chatObservation(dictation)
        _ = deleting.record(dictation)
        _ = deleting.record("Ich nutze sup")
        _ = deleting.record("")
        let deletion = candidates(deleting, finalValue: nil)
        expect(deletion?.candidates.isEmpty == true, "deleting the dictation yields no candidates")

        // 6. Unchanged dictation that is then sent yields nothing.
        var untouched = chatObservation(dictation)
        _ = untouched.record(dictation)
        _ = untouched.record("")
        expect(candidates(untouched, finalValue: nil)?.candidates.isEmpty == true, "unchanged dictation yields no candidates")

        // 7. Nothing observed and field cleared: no snapshot at all.
        var neverSampled = chatObservation(dictation)
        _ = neverSampled.record("")
        expect(neverSampled.snapshot(finalValue: nil).dictationIsUnchanged, "no observation, nothing changed")

        // 8. Reviewer response payloads.
        let array = #"[{"candidateID":0,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null}]"#
        expect(AutoLearnReviewResponse.decisionArrayPayload(from: array) == array, "plain array unchanged")
        expect(
            AutoLearnReviewResponse.decisionArrayPayload(from: "```json\n\(array)\n```") == array,
            "code fence removed"
        )
        expect(
            AutoLearnReviewResponse.decisionArrayPayload(from: "<think>prüfe Kandidat 0</think>\n\(array)") == array,
            "hidden reasoning removed"
        )
        expect(
            AutoLearnReviewResponse.decisionArrayPayload(from: #"{"reviewDecisions":[]}"#) == "[]",
            "array inside an object is extracted (strict decoder still validates it)"
        )

        // 9. Phonetic gate for learned replacements (live review cases).
        let misrecognitions: [(String, String)] = [
            ("Voice Inc", "VoiceInk"), ("super base", "Supabase"), ("X code", "Xcode"),
            ("Ohrka", "Orca"), ("Jannik Muth", "Yannik Muth"), ("Tail wind", "Tailwind"),
            ("Klaud Code", "Claude Code"), ("Git hab", "GitHub"), ("Postgres Kuel", "PostgreSQL"),
            ("Dschemini", "Gemini"), ("Wisper Flow", "Wispr Flow"), ("Prakash Joshi Pages", "Prakash Joshi Pax"),
            ("Kör sa", "Cursor"), ("Wersell", "Vercel"), ("T drei Code", "T3 Code"),
        ]
        for (original, corrected) in misrecognitions {
            expect(
                AutoLearnPhoneticGate.soundsAlike(original, corrected),
                "phonetic gate keeps \(original) → \(corrected) (\(AutoLearnPhoneticGate.code(for: original)) / \(AutoLearnPhoneticGate.code(for: corrected)))"
            )
        }
        // Similar-sounding content changes such as "Simulator" → "Emulator"
        // pass this gate; the reviewer prompt rejects those.
        let contentChanges: [(String, String)] = [
            ("Linear", "Notion"), ("Slack", "Teams"), ("gutes", "schönes"),
            ("gestern", "heute"), ("iPhone", "Android"),
        ]
        for (original, corrected) in contentChanges {
            expect(
                !AutoLearnPhoneticGate.soundsAlike(original, corrected),
                "phonetic gate rejects \(original) → \(corrected) (\(AutoLearnPhoneticGate.code(for: original)) / \(AutoLearnPhoneticGate.code(for: corrected)))"
            )
        }

        // 10. Rich-text composer rewrote the paste's whitespace (live case
        // 18:19: enhanced text with blank lines between paragraphs).
        let pastedParagraphs = "Ich nutze super base.\n\nDas Backend läuft dort."
        let composerText = "Hallo\nIch nutze super base.\nDas Backend läuft dort."
        let located = AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
            of: pastedParagraphs,
            in: composerText,
            nearUTF16Location: composerText.utf16.count
        )
        expect(
            located.map { (composerText as NSString).substring(with: $0) }
                == "Ich nutze super base.\nDas Backend läuft dort.",
            "paragraph breaks rewritten by the editor still locate the paste"
        )
        if let located {
            var composer = AutoLearnFieldObservation(
                baselineFieldText: composerText,
                pastedRange: located,
                pastedText: (composerText as NSString).substring(with: located)
            )
            _ = composer.record(composerText.replacingOccurrences(of: "super base", with: "Supabase"))
            _ = composer.record("")
            expect(
                candidates(composer, finalValue: nil)?.candidates.contains {
                    $0.correctedText.contains("Supabase")
                } == true,
                "correction in a rewritten paste becomes a candidate"
            )
        }
        let nbspField = "Wir nehmen super\u{00A0}base."
        expect(
            AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
                of: "super base", in: nbspField, nearUTF16Location: nil
            ).map { (nbspField as NSString).substring(with: $0) } == "super\u{00A0}base",
            "non-breaking space matches a space"
        )
        let trimmedField = "Text: super base"
        expect(
            AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
                of: " super base\n", in: trimmedField, nearUTF16Location: nil
            ).map { (trimmedField as NSString).substring(with: $0) } == "super base",
            "boundary whitespace of the paste stays outside the range"
        )
        let twice = "super base und super base"
        expect(
            AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
                of: "super  base", in: twice, nearUTF16Location: nil
            ) == nil,
            "ambiguous match without caret is rejected"
        )
        expect(
            AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
                of: "super  base", in: twice, nearUTF16Location: twice.utf16.count
            ) == NSRange(location: 15, length: 10),
            "ambiguous match picks the occurrence at the caret"
        )
        expect(
            AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
                of: "Supabase", in: "Ich nutze super base", nearUTF16Location: nil
            ) == nil,
            "different text is not located"
        )

        // 11. Live case 20:00: two dictations into one composer. The earlier one
        // is corrected after the later one was pasted, a note is typed, sent.
        let firstText = "Hallo, Superbass. "
        let earlier = "Супербейс. Супербейс. "
        let fieldAfterFirst = earlier + firstText
        var first = observing(firstText, after: earlier, in: fieldAfterFirst)
        _ = first.record(fieldAfterFirst)
        let secondText = "Kannst du Superbass benutzen? "
        let fieldAfterSecond = fieldAfterFirst + secondText
        expect(
            first.record(fieldAfterSecond, attachesAdjacentTyping: false) == .observed,
            "multi: earlier dictation survives the next paste"
        )
        var second = observing(secondText, after: fieldAfterFirst, in: fieldAfterSecond)
        let correctedFirst = earlier + "Hallo, Supabase. " + secondText
        let withNote = correctedFirst + "das kam heraus. "
        for text in [correctedFirst, withNote, ""] {
            _ = first.record(text)
            _ = second.record(text)
        }
        expect(
            learned(candidates(first, finalValue: nil)) == ["Superbass → Supabase"],
            "multi: correction in the earlier dictation is learned (\(learned(candidates(first, finalValue: nil))))"
        )
        expect(
            second.snapshot(finalValue: nil).dictationIsUnchanged,
            "multi: later dictation is unchanged; the typed note stays outside"
        )

        // 12. Backspace through the end of a dictation and retype it.
        let single = "Hallo, Superbass. "
        var retyped = observing(single, after: "", in: single)
        var typedField = single
        while typedField != "Hallo, " {
            typedField.removeLast()
            _ = retyped.record(typedField)
        }
        for character in "Supabase. " {
            typedField.append(character)
            _ = retyped.record(typedField)
        }
        for character in "Und weiter" {
            typedField.append(character)
            _ = retyped.record(typedField)
        }
        _ = retyped.record("")
        expect(
            learned(candidates(retyped, finalValue: nil)).first == "Superbass → Supabase",
            "retyped ending is learned (\(learned(candidates(retyped, finalValue: nil))))"
        )

        // 13. Selecting everything and typing something else is not a correction.
        let surrounded = "Intro. " + single + "Ende."
        var replacedField = observing(single, after: "Intro. ", in: surrounded)
        expect(replacedField.record("Neuer Text") == .lost, "select-all replacement loses the dictation")
        expect(candidates(replacedField, finalValue: nil)?.candidates.isEmpty == true, "lost dictation yields nothing")

        // 14. Two corrections between samples are split into separate edits.
        let twoField = "Ich nutze super base. " + "Wir bauen mit X code. "
        var left = observing("Ich nutze super base. ", after: "", in: twoField)
        var right = observing("Wir bauen mit X code. ", after: "Ich nutze super base. ", in: twoField)
        let twoCorrected = "Ich nutze Supabase. Wir bauen mit Xcode. "
        _ = left.record(twoCorrected)
        _ = right.record(twoCorrected)
        let leftLearned = learned(candidates(left, finalValue: nil))
        let rightLearned = learned(candidates(right, finalValue: nil))
        expect(
            leftLearned.count == 1 && leftLearned[0].contains("super base") && leftLearned[0].hasSuffix("Supabase")
                && rightLearned.count == 1 && rightLearned[0].contains("X code") && rightLearned[0].hasSuffix("Xcode"),
            "coalesced edits stay with their dictation (\(leftLearned) / \(rightLearned))"
        )

        // 15. A paste right against an earlier dictation does not join it.
        let unspaced = "Hallo Superbass"
        var joined = observing(unspaced, after: "", in: unspaced)
        _ = joined.record(unspaced + "Weiter geht es", attachesAdjacentTyping: false)
        expect(
            joined.snapshot(finalValue: nil).finalDictationText == unspaced,
            "a new paste stays outside the earlier dictation"
        )

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("all Auto Learn snapshot checks passed")
    }
}
