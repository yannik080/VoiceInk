import ApplicationServices
import Foundation
import OSLog

final class AutoLearnAXRuntime: @unchecked Sendable {
    private struct Session {
        let token: AutoLearnPasteToken
        let processID: pid_t
        let appElement: AXUIElement
        let targetElement: AXUIElement
        /// Every dictation into this field since it was entered or sent, the
        /// latest last. Earlier ones stay observed, so a correction made after
        /// dictating again still counts.
        var observations: [AutoLearnFieldObservation]
    }

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.auto-learn.accessibility")
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AutoLearnCapture"
    )
    private let textReader = AutoLearnAXTextReader()
    private var session: Session?
    /// Snapshots of dictations that ended while a new paste was captured.
    private var finishedSnapshots: [AutoLearnFieldSnapshot] = []

    /// Called when recording starts so Chromium/Electron have the whole
    /// dictation to build their accessibility tree before the paste.
    func prepareTarget(processID: pid_t) async {
        await perform { [self] in
            guard AXIsProcessTrusted(),
                processID != ProcessInfo.processInfo.processIdentifier
            else { return }
            let state = textReader.prepareWebAccessibility(processID: processID)
            logger.notice("Auto Learn target prepared manualAX=\(state, privacy: .public)")
        }
    }

    func capturePastedText(
        text: String,
        processID: pid_t,
        attempt: Int,
        isFinalAttempt: Bool
    ) async -> AutoLearnCaptureOutcome {
        await perform { [self] in
            guard AXIsProcessTrusted() else { return rejectCapture("accessibility-not-trusted") }
            guard processID != ProcessInfo.processInfo.processIdentifier else {
                return rejectCapture("target-is-voiceink")
            }
            guard !text.isEmpty else { return rejectCapture("empty-pasted-text") }
            guard text.count <= AutoLearnLimits.maximumPastedCharacters else {
                return rejectCapture("pasted-text-too-large")
            }

            var matchedReading: AutoLearnAXTextReading?
            var pastedRange: NSRange?
            var matchKind = ""
            var lastReading: AutoLearnAXTextReading?

            let readings = textReader.focusedReadings(processID: processID)
            for reading in readings {
                lastReading = reading
                if let resolved = resolvedPastedRange(
                    for: text,
                    selectionAfterPaste: reading.selection,
                    fieldText: reading.fieldText
                ) {
                    matchedReading = reading
                    pastedRange = resolved.range
                    matchKind = resolved.match
                    break
                }
            }

            guard let reading = matchedReading, let pastedRange else {
                let reason = lastReading == nil
                    ? "focused-text-reading-unavailable"
                    : "pasted-range-invalid"
                guard isFinalAttempt else { return .retryable }
                var detail = "attempts=\(attempt) \(textReader.lastFocusDiagnostic)"
                if let lastReading {
                    let selection = lastReading.selection.map { "\($0.location)+\($0.length)" } ?? "none"
                    detail += " fieldLength=\(lastReading.fieldText.utf16.count) pastedLength=\(text.utf16.count) selection=\(selection)"
                }
                return rejectCapture(reason, detail: detail)
            }

            let fieldText = reading.fieldText
            let observedPastedText = (fieldText as NSString).substring(with: pastedRange)

            AXUIElementSetMessagingTimeout(
                reading.appElement,
                AutoLearnLimits.accessibilityTimeoutSeconds
            )
            var observations = carriedObservations(
                into: reading.targetElement,
                processID: processID,
                fieldText: fieldText
            )
            observations.append(AutoLearnFieldObservation(
                baselineFieldText: fieldText,
                pastedRange: pastedRange,
                pastedText: observedPastedText
            ))
            let token = AutoLearnPasteToken(id: UUID())
            session = Session(
                token: token,
                processID: processID,
                appElement: reading.appElement,
                targetElement: reading.targetElement,
                observations: observations
            )
            logger.notice(
                "Auto Learn capture started attempt=\(attempt, privacy: .public) source=\(reading.source, privacy: .public) focus=\(reading.focusSource, privacy: .public) fieldLength=\(fieldText.utf16.count, privacy: .public) pastedLength=\(pastedRange.length, privacy: .public) match=\(matchKind, privacy: .public) dictations=\(observations.count, privacy: .public)"
            )
            return .captured(token)
        }
    }

    /// Records the current field text while the user edits. Chat apps clear
    /// the field when a message is sent; the last sample before that keeps
    /// the user's correction. Returns false once no dictation of the session
    /// is left to observe.
    func sampleField(token: AutoLearnPasteToken) async -> Bool {
        await perform { [self] in
            guard var active = session, active.token == token else { return true }
            guard active.observations.contains(where: \.isTracking) else { return false }
            guard let value = textReader.textValue(from: active.targetElement),
                value.text.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length
            else { return true }

            var results: [AutoLearnFieldObservation.SampleResult] = []
            for index in active.observations.indices {
                results.append(active.observations[index].record(value.text))
            }
            if results.contains(.disappeared) {
                logger.notice("Auto Learn field cleared; keeping last observed text")
            }
            if results.contains(.lost) {
                logger.notice("Auto Learn lost a dictation after the field was rewritten")
            }
            session = active
            return active.observations.contains(where: \.isTracking)
        }
    }

    /// Ends the session with `token` and returns its snapshots, together with
    /// those of dictations that ended while the latest paste was captured.
    func finishSnapshots(token: AutoLearnPasteToken?) async -> [AutoLearnFieldSnapshot] {
        await perform { [self] in
            var snapshots = finishedSnapshots
            finishedSnapshots = []
            guard let token, let active = session, active.token == token else { return snapshots }
            session = nil

            snapshots += self.snapshots(of: active.observations, finalValue: readFinalValue(of: active))
            return snapshots
        }
    }

    func targetIsFocused(token: AutoLearnPasteToken) async -> Bool {
        await perform { [self] in
            guard let active = session, active.token == token else { return false }
            return focusedElementMatches(active.targetElement, in: active.appElement)
        }
    }

    func discard() async {
        await perform { [self] in
            session = nil
            finishedSnapshots = []
        }
    }

    /// Dictations earlier pasted into the field that received the new paste.
    /// A paste into another field ends the earlier session instead.
    private func carriedObservations(
        into targetElement: AXUIElement,
        processID: pid_t,
        fieldText: String
    ) -> [AutoLearnFieldObservation] {
        guard let previous = session else { return [] }
        session = nil

        guard previous.processID == processID,
            CFEqual(previous.targetElement, targetElement)
        else {
            finishedSnapshots += snapshots(
                of: previous.observations,
                finalValue: readFinalValue(of: previous)
            )
            return []
        }

        var carried: [AutoLearnFieldObservation] = []
        var ended: [AutoLearnFieldObservation] = []
        for var observation in previous.observations {
            if observation.isTracking {
                // The paste itself never continues an earlier dictation.
                _ = observation.record(fieldText, attachesAdjacentTyping: false)
            }
            if observation.isTracking {
                carried.append(observation)
            } else {
                ended.append(observation)
            }
        }
        let overflow = max(0, carried.count + 1 - AutoLearnLimits.maximumTrackedDictations)
        ended += carried.prefix(overflow)
        carried.removeFirst(overflow)
        finishedSnapshots += snapshots(of: ended, finalValue: nil)
        return carried
    }

    private func readFinalValue(of session: Session) -> String? {
        guard session.observations.contains(where: \.isTracking),
            let value = textReader.textValue(from: session.targetElement),
            value.text.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length
        else {
            return nil
        }
        return value.text
    }

    private func snapshots(
        of observations: [AutoLearnFieldObservation],
        finalValue: String?
    ) -> [AutoLearnFieldSnapshot] {
        observations.compactMap { observation in
            let snapshot = observation.snapshot(finalValue: finalValue)
            guard !snapshot.dictationIsUnchanged else {
                logger.notice(
                    "Auto Learn snapshot unchanged source=\(snapshot.finalTextSource, privacy: .public)"
                )
                return nil
            }
            return snapshot
        }
    }

    /// Restores web accessibility everywhere VoiceInk switched it on, after
    /// Auto Learn is turned off. While it is on, the setting stays on: turning
    /// it off makes Chromium/Electron drop their accessibility tree, and
    /// rebuilding it in a large window takes longer than the capture window.
    func restoreAllWebAccessibility() async {
        await perform { [self] in
            for processID in textReader.webAccessibilityProcessIDs {
                textReader.restoreWebAccessibility(processID: processID)
            }
        }
    }

    private func textIsExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private func rejectCapture(_ reason: String, detail: String = "") -> AutoLearnCaptureOutcome {
        logger.notice(
            "Auto Learn capture rejected reason=\(reason, privacy: .public) \(detail, privacy: .public)"
        )
        return .rejected
    }

    private func focusedElementMatches(_ targetElement: AXUIElement, in appElement: AXUIElement) -> Bool {
        guard copyBoolAttribute(kAXFrontmostAttribute, from: appElement) != false else {
            return false
        }

        if let appFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ), CFEqual(appFocusedElement, targetElement) {
            return true
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        if let systemFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ), CFEqual(systemFocusedElement, targetElement) {
            return true
        }

        return copyBoolAttribute(kAXFocusedAttribute, from: targetElement) == true
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func pastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange,
        fieldUTF16Length: Int
    ) -> NSRange? {
        guard isValid(selectionAfterPaste, inUTF16Length: fieldUTF16Length) else { return nil }

        let pastedLength = pastedText.utf16.count
        if selectionAfterPaste.length == pastedLength {
            return selectionAfterPaste
        }

        guard selectionAfterPaste.length == 0,
            selectionAfterPaste.location >= pastedLength
        else {
            return nil
        }

        return NSRange(
            location: selectionAfterPaste.location - pastedLength,
            length: pastedLength
        )
    }

    private func resolvedPastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange?,
        fieldText: String
    ) -> (range: NSRange, match: String)? {
        if let range = strictPastedRange(
            for: pastedText,
            selectionAfterPaste: selectionAfterPaste,
            fieldText: fieldText
        ) {
            return (range, "strict")
        }
        // Rich-text composers rewrite whitespace, e.g. blank lines between
        // paragraphs. The session then uses the field's own representation.
        return AutoLearnPastedRangeLocator.whitespaceInsensitiveRange(
            of: pastedText,
            in: fieldText,
            nearUTF16Location: selectionAfterPaste.map { NSMaxRange($0) }
        ).map { ($0, "whitespace") }
    }

    private func strictPastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange?,
        fieldText: String
    ) -> NSRange? {
        let field = fieldText as NSString
        let normalizedPastedText = AutoLearnTextNormalizer.accessibilityComparable(pastedText)

        if let selectionAfterPaste {
            if let inferredRange = pastedRange(
                for: pastedText,
                selectionAfterPaste: selectionAfterPaste,
                fieldUTF16Length: field.length
            ) {
                let observedText = field.substring(with: inferredRange)
                if textIsExactlyEqual(observedText, pastedText) {
                    return inferredRange
                }
                if !normalizedPastedText.isEmpty,
                    AutoLearnTextNormalizer.accessibilityComparable(observedText)
                        == normalizedPastedText
                {
                    return inferredRange
                }
            }
        }

        let exactMatches = exactMatches(for: pastedText, in: fieldText)
        if exactMatches.count == 1 {
            return exactMatches[0]
        }

        guard let selectionAfterPaste else {
            if let boundaryMatch = uniqueBoundaryWhitespaceMatch(
                for: pastedText,
                in: fieldText
            ) {
                return boundaryMatch
            }
            return nil
        }

        if let exactMatch = nearestMatch(
            in: exactMatches,
            near: selectionAfterPaste.location,
            pastedLength: pastedText.utf16.count
        ) {
            return exactMatch
        }

        guard selectionAfterPaste.length == 0 else { return nil }

        let expectedLength = pastedText.utf16.count
        let maximumLengthAdjustment = min(max(expectedLength / 4, 8), 128)
        guard !normalizedPastedText.isEmpty else { return nil }
        let caretLocation = min(max(selectionAfterPaste.location, 0), field.length)

        // Browser editors can expose the caret immediately before their own
        // trailing whitespace. Search only the closest boundaries around it.
        for endOffset in symmetricOffsets(upTo: 8) {
            let candidateEnd = caretLocation + endOffset
            guard candidateEnd >= 0, candidateEnd <= field.length else { continue }

            for lengthOffset in symmetricOffsets(upTo: maximumLengthAdjustment) {
                let candidateLength = expectedLength + lengthOffset
                guard candidateLength >= 0, candidateLength <= candidateEnd else { continue }

                let candidateRange = NSRange(
                    location: candidateEnd - candidateLength,
                    length: candidateLength
                )
                let candidateText = field.substring(with: candidateRange)
                if AutoLearnTextNormalizer.accessibilityComparable(candidateText)
                    == normalizedPastedText
                {
                    return candidateRange
                }
            }
        }

        return nil
    }

    /// Web editors may turn pasted boundary whitespace into their own leading
    /// space or trailing newline. Match the unchanged core exactly and leave
    /// the editor-owned whitespace outside the observed pasted range.
    private func uniqueBoundaryWhitespaceMatch(
        for pastedText: String,
        in fieldText: String
    ) -> NSRange? {
        let coreText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coreText.isEmpty, !textIsExactlyEqual(coreText, pastedText) else {
            return nil
        }

        let matches = exactMatches(for: coreText, in: fieldText)
        return matches.count == 1 ? matches[0] : nil
    }

    private func symmetricOffsets(upTo maximum: Int) -> [Int] {
        guard maximum > 0 else { return [0] }
        var offsets = [0]
        offsets.reserveCapacity(maximum * 2 + 1)
        for offset in 1...maximum {
            offsets.append(offset)
            offsets.append(-offset)
        }
        return offsets
    }

    private func exactMatches(for pastedText: String, in fieldText: String) -> [NSRange] {
        let field = fieldText as NSString
        var searchRange = NSRange(location: 0, length: field.length)
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = field.range(of: pastedText, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)

            // Advance by one UTF-16 unit so overlapping occurrences are not skipped.
            let nextLocation = match.location + 1
            guard nextLocation < field.length else { break }
            searchRange = NSRange(location: nextLocation, length: field.length - nextLocation)
        }

        return matches
    }

    private func nearestMatch(
        in matches: [NSRange],
        near location: Int,
        pastedLength: Int
    ) -> NSRange? {
        let maximumDistance = max(pastedLength, 128)
        return matches.min {
            abs(NSMaxRange($0) - location) < abs(NSMaxRange($1) - location)
        }.flatMap {
            abs(NSMaxRange($0) - location) <= maximumDistance ? $0 : nil
        }
    }

    private func isValid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
