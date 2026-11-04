import Foundation

enum FinalSnapshotDiffEngine {
    static func revision(from snapshot: AutoLearnFieldSnapshot) -> AutoLearnRevision? {
        guard let correctedText = snapshot.finalDictationText else { return nil }

        let normalizedCorrectedText = AutoLearnTextNormalizer.accessibilityComparable(correctedText)
        let normalizedOriginalText = AutoLearnTextNormalizer.accessibilityComparable(
            snapshot.originalPastedText
        )
        // An emptied range means the dictation was deleted or sent, and a
        // truncated dictation (backspace held, deletion in progress) is not a
        // correction.
        guard !normalizedCorrectedText.isEmpty,
            !textIsExactlyEqual(normalizedOriginalText, normalizedCorrectedText),
            !normalizedOriginalText.hasPrefix(normalizedCorrectedText)
        else {
            return nil
        }

        return AutoLearnRevision(
            original: normalizedOriginalText,
            corrected: normalizedCorrectedText
        )
    }

    private static func textIsExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}

/// Tracks one dictation while the user edits the field. Each sample is diffed
/// against the previous one, so the dictated range follows edits elsewhere in
/// the field, including corrections in other dictations. Chat apps clear the
/// field when a message is sent; the last sample before that keeps the
/// correction.
struct AutoLearnFieldObservation: Sendable {
    enum SampleResult: Equatable {
        case unchanged
        case observed
        case lost
        case disappeared
        case ignoredAfterDisappearance
    }

    let baselineFieldText: String
    let pastedRange: NSRange
    let pastedText: String
    /// The last sample that still contained the dictation, and its range there.
    private(set) var trackedFieldText: String
    private(set) var trackedRange: NSRange
    private(set) var dictatedRangeDisappeared = false
    private(set) var dictatedRangeLost = false
    private var lastSampledFieldText: String?
    /// The user deleted into the dictation from this edge; text typed there
    /// next replaces what was deleted.
    private var trimmedEdges = AutoLearnRangeTracker.Edges()

    var isTracking: Bool { !dictatedRangeDisappeared && !dictatedRangeLost }

    init(baselineFieldText: String, pastedRange: NSRange, pastedText: String) {
        self.baselineFieldText = baselineFieldText
        self.pastedRange = pastedRange
        self.pastedText = pastedText
        trackedFieldText = baselineFieldText
        trackedRange = pastedRange
    }

    /// `attachesAdjacentTyping` is false when the change is a new paste, which
    /// never continues an earlier dictation.
    mutating func record(_ fieldText: String, attachesAdjacentTyping: Bool = true) -> SampleResult {
        guard !dictatedRangeDisappeared else { return .ignoredAfterDisappearance }
        guard !dictatedRangeLost else { return .lost }
        if let lastSampledFieldText,
            lastSampledFieldText.utf16.elementsEqual(fieldText.utf16)
        {
            return .unchanged
        }
        lastSampledFieldText = fieldText

        if AutoLearnTextNormalizer.accessibilityComparable(fieldText).isEmpty {
            dictatedRangeDisappeared = true
            return .disappeared
        }
        let canRegrow = attachesAdjacentTyping && trackedRange.length < pastedRange.length
        guard let mapping = AutoLearnRangeTracker.map(
            trackedRange,
            from: Array(trackedFieldText.utf16),
            to: Array(fieldText.utf16),
            attachesAdjacentTyping: attachesAdjacentTyping,
            regrowing: AutoLearnRangeTracker.Edges(
                start: canRegrow && trimmedEdges.start,
                end: canRegrow && trimmedEdges.end
            )
        ) else {
            dictatedRangeLost = true
            return .lost
        }
        trackedFieldText = fieldText
        trackedRange = mapping.range
        trimmedEdges.start = trimmedEdges.start || mapping.trimmed.start
        trimmedEdges.end = trimmedEdges.end || mapping.trimmed.end
        return .observed
    }

    /// The state to diff when observation ends. `finalValue` is the field read
    /// at that moment, nil if unreadable.
    func snapshot(finalValue: String?) -> AutoLearnFieldSnapshot {
        var observation = self
        let source: String
        if let finalValue {
            switch observation.record(finalValue) {
            case .unchanged, .observed:
                source = "final"
            case .disappeared, .ignoredAfterDisappearance:
                source = "last-observed-before-clear"
            case .lost:
                source = "last-observed-before-loss"
            }
        } else if dictatedRangeDisappeared {
            source = "last-observed-before-clear"
        } else if dictatedRangeLost {
            source = "last-observed-before-loss"
        } else {
            source = "last-observed-unreadable"
        }
        return AutoLearnFieldSnapshot(
            baselineFieldText: baselineFieldText,
            finalFieldText: observation.trackedFieldText,
            pastedRange: pastedRange,
            originalPastedText: pastedText,
            finalPastedRange: observation.trackedRange,
            finalTextSource: source
        )
    }
}

/// Follows a range of a text field through the user's edits, in UTF-16 units.
enum AutoLearnRangeTracker {
    struct Edit: Equatable {
        let oldRange: Range<Int>
        let newRange: Range<Int>
    }

    struct Edges: Equatable {
        var start = false
        var end = false
    }

    /// Maps `range` of `old` into `new`. Text typed against a word at the
    /// range's edge continues that word and joins the range, as when the last
    /// letters of a dictated word are retyped; so does any text typed at an
    /// edge in `regrowing`. Other text inserted at an edge stays outside.
    /// `trimmed` reports edges the user deleted into. Returns nil when the
    /// range is gone or was replaced along with text around it (select all,
    /// field reused for another message).
    static func map(
        _ range: NSRange,
        from old: [UInt16],
        to new: [UInt16],
        attachesAdjacentTyping: Bool,
        regrowing: Edges = Edges()
    ) -> (range: NSRange, trimmed: Edges)? {
        let start = range.location
        let end = NSMaxRange(range)
        guard range.location != NSNotFound, start >= 0, start < end, end <= old.count else {
            return nil
        }

        let changes = edits(from: old, to: new)
        var mappedStart = start
        var mappedEnd = end
        var startResolved = false
        var endResolved = false
        var trimmed = Edges()

        for edit in changes {
            let lower = edit.oldRange.lowerBound
            let upper = edit.oldRange.upperBound
            if lower <= start, upper >= end, lower < start || upper > end {
                return nil
            }
            if lower == 0, upper == old.count {
                return nil
            }
            if edit.newRange.isEmpty {
                trimmed.start = trimmed.start || (lower == start && upper > start)
                trimmed.end = trimmed.end || (upper == end && lower < end)
            }

            if !startResolved {
                if lower < start, upper > start {
                    mappedStart = edit.newRange.lowerBound
                    startResolved = true
                } else if lower == start, upper == start,
                    attachesAdjacentTyping,
                    regrowing.start
                        || (isWordUnit(old[start]) && isWordUnit(new[edit.newRange.upperBound - 1]))
                {
                    mappedStart = edit.newRange.lowerBound
                    startResolved = true
                } else if upper <= start {
                    mappedStart = start - upper + edit.newRange.upperBound
                } else {
                    startResolved = true
                }
            }

            if !endResolved {
                if lower < end, upper > end {
                    mappedEnd = edit.newRange.upperBound
                    endResolved = true
                } else if lower == end, upper == end {
                    if attachesAdjacentTyping,
                        regrowing.end
                            || (isWordUnit(old[end - 1]) && isWordUnit(new[edit.newRange.lowerBound]))
                    {
                        mappedEnd = edit.newRange.upperBound
                    }
                    endResolved = true
                } else if lower < end, upper <= end {
                    mappedEnd = end - upper + edit.newRange.upperBound
                } else {
                    endResolved = true
                }
            }
        }

        guard mappedStart < mappedEnd, mappedEnd <= new.count else { return nil }
        return (NSRange(location: mappedStart, length: mappedEnd - mappedStart), trimmed)
    }

    /// The edits that turn `old` into `new`. Text unchanged around a burst of
    /// edits is trimmed first; a Myers diff then splits the rest when it is
    /// small enough, so two corrections between samples stay separate. Short
    /// matches between larger edits are coincidental letters of unrelated
    /// text, so those edits are joined again.
    static func edits(from old: [UInt16], to new: [UInt16]) -> [Edit] {
        let shorterCount = min(old.count, new.count)
        var prefix = 0
        while prefix < shorterCount, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorterCount - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }

        let oldEnd = old.count - suffix
        let newEnd = new.count - suffix
        guard prefix < oldEnd || prefix < newEnd else { return [] }

        let whole = Edit(oldRange: prefix..<oldEnd, newRange: prefix..<newEnd)
        guard prefix < oldEnd, prefix < newEnd,
            (oldEnd - prefix) + (newEnd - prefix) <= AutoLearnLimits.maximumSplitDiffUTF16Length
        else {
            return [whole]
        }

        let oldMiddle = Array(old[prefix..<oldEnd])
        let newMiddle = Array(new[prefix..<newEnd])
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _):
                removed.insert(offset)
            case .insert(let offset, _, _):
                inserted.insert(offset)
            }
        }

        var result: [Edit] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
            if oldIndex < oldMiddle.count, newIndex < newMiddle.count,
                !removed.contains(oldIndex), !inserted.contains(newIndex)
            {
                oldIndex += 1
                newIndex += 1
                continue
            }
            let oldStart = oldIndex
            let newStart = newIndex
            while oldIndex < oldMiddle.count, removed.contains(oldIndex) {
                oldIndex += 1
            }
            while newIndex < newMiddle.count, inserted.contains(newIndex) {
                newIndex += 1
            }
            guard oldIndex > oldStart || newIndex > newStart else { return [whole] }
            if let last = result.last,
                last.oldRange.upperBound == prefix + oldStart,
                last.newRange.upperBound == prefix + newStart
            {
                result[result.count - 1] = Edit(
                    oldRange: last.oldRange.lowerBound..<prefix + oldIndex,
                    newRange: last.newRange.lowerBound..<prefix + newIndex
                )
            } else {
                result.append(Edit(
                    oldRange: prefix + oldStart..<prefix + oldIndex,
                    newRange: prefix + newStart..<prefix + newIndex
                ))
            }
        }
        return joiningCoincidentalMatches(result)
    }

    /// Joins two edits when the unchanged text between them is no longer than
    /// either edit, as in a semantic diff cleanup.
    private static func joiningCoincidentalMatches(_ edits: [Edit]) -> [Edit] {
        var result = edits
        var joined = true
        while joined {
            joined = false
            var index = 0
            while index + 1 < result.count {
                let left = result[index]
                let right = result[index + 1]
                let gap = right.oldRange.lowerBound - left.oldRange.upperBound
                if gap <= max(left.oldRange.count, left.newRange.count),
                    gap <= max(right.oldRange.count, right.newRange.count)
                {
                    result[index] = Edit(
                        oldRange: left.oldRange.lowerBound..<right.oldRange.upperBound,
                        newRange: left.newRange.lowerBound..<right.newRange.upperBound
                    )
                    result.remove(at: index + 1)
                    joined = true
                } else {
                    index += 1
                }
            }
        }
        return result
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
