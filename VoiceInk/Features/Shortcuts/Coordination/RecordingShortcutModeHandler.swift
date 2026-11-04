import Foundation

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void
    private let discardRecording: @MainActor () async -> Void
    private let scheduleAfter: @MainActor (TimeInterval, @escaping @MainActor () async -> Void) -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: TimeInterval?
    private var pendingDoubleTapReleaseTimes: [ShortcutAction: TimeInterval] = [:]
    private var deferredPress: DeferredPress?
    /// Hybrid: a short tap whose recording is kept only if a second tap follows (Wispr Flow).
    private var pendingSingleTap: (action: ShortcutAction, releasedAt: TimeInterval, generation: Int)?
    private var singleTapGeneration = 0
    /// Hybrid: a lone tap made while the pipeline was busy. It recorded nothing, but a second tap
    /// right after the pipeline finished still completes the double tap.
    private var unrecordedTap: (action: ShortcutAction, releasedAt: TimeInterval)?
    /// Hybrid: the held press started the recording, so its release decides push to talk vs. tap.
    private var activePressStartedRecording = false
    /// Hybrid: the held press stopped a recording or latched hands-free; its release does nothing.
    private var activePressIgnoresRelease = false

    /// Only filters key bounce and accidental double presses. A deliberate stop-then-start is
    /// well above this, so it no longer eats the second press.
    private let shortcutPressCooldown: TimeInterval = 0.2
    /// How long a tap made while the previous dictation is still being processed may wait for it.
    /// Covers local transcription; a tap made early in a long enhancement would start a recording
    /// seconds later, so it is dropped instead.
    private let deferredTapLifetime: TimeInterval = 0.6
    private let hybridPressThreshold: TimeInterval = 0.5
    /// Hybrid: how long after a short tap the second tap of a double tap may come.
    private let hybridSecondTapWindow: TimeInterval = 0.45
    /// Hybrid needs quick double taps (~150 ms apart), so it only filters key bounce.
    private let hybridPressCooldown: TimeInterval = 0.05
    private let doubleTapThreshold: TimeInterval = 0.7

    /// A press that arrived while the previous dictation was still transcribing or enhancing.
    /// It is replayed as soon as the engine is idle again instead of being dropped.
    private struct DeferredPress {
        let action: ShortcutAction
        let mode: RecordingShortcutManager.Mode
        let modeId: UUID?
        let pressedAt: TimeInterval
        var releasedAt: TimeInterval?
        var isDiscarded = false
        /// Hybrid: the second tap of a double tap made while the pipeline was busy.
        var isSecondTap = false
    }

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        discardRecording: @escaping @MainActor () async -> Void,
        scheduleAfter: @escaping @MainActor (TimeInterval, @escaping @MainActor () async -> Void) -> Void = {
            delay, work in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await work()
            }
        }
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
        self.discardRecording = discardRecording
        self.scheduleAfter = scheduleAfter
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearActivePressFlags()
        pendingSingleTap = nil
        unrecordedTap = nil
        deferredPress = nil
        clearPendingDoubleTaps()
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    func clearPendingDoubleTap(for action: ShortcutAction) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
    }

    func clearPendingModeDoubleTaps() {
        pendingDoubleTapReleaseTimes = pendingDoubleTapReleaseTimes.filter { action, _ in
            if case .mode = action { return false }
            return true
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
        if deferredPress?.action == action {
            deferredPress = nil
        }
        if pendingSingleTap?.action == action {
            pendingSingleTap = nil
        }
        if unrecordedTap?.action == action {
            unrecordedTap = nil
        }
        guard activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearActivePressFlags()
    }

    private func clearActivePressFlags() {
        activePressStartedRecording = false
        activePressIgnoresRelease = false
    }

    func handleShortcutDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            clearPendingDoubleTap(for: action)
            return
        }

        let cooldown = mode == .hybrid ? hybridPressCooldown : shortcutPressCooldown
        if mode != .doubleTap, let lastTrigger = lastShortcutPressTime,
            eventTime - lastTrigger >= 0,
            eventTime - lastTrigger < cooldown
        {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = eventTime
        }
        shortcutPressStartTime = eventTime
        clearActivePressFlags()

        // Second tap of a double tap: the recording the first tap started stays on, hands-free.
        if mode == .hybrid, let pending = pendingSingleTap, pending.action == action {
            pendingSingleTap = nil
            activeShortcutCanCancelAccidentalStart = false
            if eventTime - pending.releasedAt >= 0, eventTime - pending.releasedAt <= hybridSecondTapWindow,
                isRecorderVisible(), isRecordingOrStarting
            {
                isHandsFreeRecording = true
                activePressIgnoresRelease = true
                return
            }
        }

        if mode == .hybrid, let tap = unrecordedTap, tap.action == action {
            unrecordedTap = nil
            if eventTime - tap.releasedAt >= 0, eventTime - tap.releasedAt <= hybridSecondTapWindow,
                !isProcessingPreviousDictation
            {
                await performShortcutDown(mode: mode, modeId: modeId, latchesHandsFree: true)
                return
            }
        }

        if mode != .doubleTap && isProcessingPreviousDictation {
            var press = DeferredPress(action: action, mode: mode, modeId: modeId, pressedAt: eventTime)
            if mode == .hybrid, let previous = deferredPress, previous.action == action, !previous.isDiscarded,
                let previousRelease = previous.releasedAt,
                eventTime - previousRelease >= 0,
                eventTime - previousRelease <= hybridSecondTapWindow
            {
                press.isSecondTap = true
            }
            deferredPress = press
            return
        }

        await performShortcutDown(mode: mode, modeId: modeId)
    }

    /// `latchesHandsFree`: the press is the second tap of a double tap whose first tap recorded nothing.
    private func performShortcutDown(
        mode: RecordingShortcutManager.Mode,
        modeId: UUID?,
        latchesHandsFree: Bool = false
    ) async {
        switch mode {
        case .hybrid:
            // Wispr Flow: a press on a running recording stops it; otherwise it starts one and the
            // release decides between push to talk and the first tap of a double tap.
            if isRecorderVisible() && (isHandsFreeRecording || isRecordingOrStarting) {
                isHandsFreeRecording = false
                activePressIgnoresRelease = true
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            guard canHandleShortcutAction() else {
                isHandsFreeRecording = false
                activePressIgnoresRelease = true
                return
            }
            // Decided before the await: starting the recorder takes longer than a quick tap, so the
            // key-up usually arrives while this press is still starting the recording.
            isHandsFreeRecording = latchesHandsFree
            activePressIgnoresRelease = latchesHandsFree
            activePressStartedRecording = !latchesHandsFree
            await toggleRecorderPanel(modeId)

        case .toggle:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .doubleTap:
            break
        }
    }

    func handleShortcutUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        let pressStartedRecording = activePressStartedRecording
        let pressIgnoresRelease = activePressIgnoresRelease
        clearActivePressFlags()

        // The down half of this press has not run yet, so neither may the up half. A tap is kept
        // for replay; releasing push to talk before recording could start means there is nothing
        // left to record.
        if var press = deferredPress, press.action == action {
            shortcutPressStartTime = nil
            if press.isDiscarded || press.mode == .pushToTalk {
                deferredPress = nil
            } else {
                press.releasedAt = eventTime
                deferredPress = press
            }
            return
        }

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            guard pressStartedRecording, !pressIgnoresRelease else { break }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold {
                // Held: push to talk, releasing stops and pastes.
                if isRecorderVisible() && isRecordingOrStarting {
                    shortcutPressStartTime = nil
                    guard canHandleShortcutAction() else { return }
                    await toggleRecorderPanel(modeId)
                    return
                }
            } else {
                // Short tap: only a second tap keeps this recording (hands-free).
                armSingleTap(for: action, releasedAt: eventTime)
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                clearPendingDoubleTap(for: action)
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                await toggleRecorderPanel(modeId)
                isHandsFreeRecording = isRecorderVisible()
            } else {
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }

        shortcutPressStartTime = nil
    }

    private func armSingleTap(for action: ShortcutAction, releasedAt: TimeInterval) {
        singleTapGeneration += 1
        let generation = singleTapGeneration
        pendingSingleTap = (action, releasedAt, generation)
        scheduleAfter(hybridSecondTapWindow) { [weak self] in
            await self?.discardUnconfirmedSingleTap(generation: generation)
        }
    }

    /// A lone short tap is not a dictation: Wispr Flow drops it without pasting anything.
    private func discardUnconfirmedSingleTap(generation: Int) async {
        guard let pending = pendingSingleTap, pending.generation == generation else { return }
        pendingSingleTap = nil
        guard isRecorderVisible(), isRecordingOrStarting, !isHandsFreeRecording else { return }
        await discardRecording()
    }

    /// Replays a press that arrived while the previous dictation was still being processed.
    /// Call on every engine state change; `now` must use the shortcut event clock (system uptime).
    func resumeDeferredPress(now: TimeInterval) async {
        // A discarded press that is still held keeps its slot so its key-up is swallowed too.
        // While the recorder is busy, the press simply waits for the next state change.
        guard let press = deferredPress, !press.isDiscarded, !isProcessingPreviousDictation,
            canHandleShortcutAction()
        else { return }
        deferredPress = nil

        guard let releasedAt = press.releasedAt else {
            // Still held: continue exactly as if the press had just arrived.
            guard isShortcutPressed, activeRecordingShortcutAction == press.action else { return }
            activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
            await performShortcutDown(mode: press.mode, modeId: press.modeId, latchesHandsFree: press.isSecondTap)
            return
        }

        // A lone hybrid tap never records; only the second tap of a double tap does.
        if press.mode == .hybrid && !press.isSecondTap {
            unrecordedTap = (press.action, releasedAt)
            return
        }

        guard releasedAt >= press.pressedAt,
            now - press.pressedAt >= 0,
            now - press.pressedAt <= deferredTapLifetime,
            !isShortcutPressed
        else { return }

        await performShortcutDown(mode: press.mode, modeId: press.modeId)
        clearActivePressFlags()
        // A replayed toggle tap or completed hybrid double tap records hands-free.
        isHandsFreeRecording = true
    }

    /// Drops a waiting press, e.g. when the dictation it was waiting for is cancelled.
    func discardDeferredPress() {
        deferredPress?.isDiscarded = true
        if deferredPress?.releasedAt != nil {
            deferredPress = nil
        }
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        // Another key joined a press that is still waiting: it was a key combination, not a
        // request to record.
        if deferredPress?.action == action {
            deferredPress?.isDiscarded = true
            return
        }

        if activeShortcutIsDoubleTap {
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var isRecordingOrStarting: Bool {
        let state = recordingState()
        return state == .recording || state == .starting
    }

    private var isProcessingPreviousDictation: Bool {
        let state = recordingState()
        return state == .transcribing || state == .enhancing
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
