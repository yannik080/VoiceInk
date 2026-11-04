import Foundation

// Compile together with RecordingShortcutModeHandler.swift, ShortcutAction.swift and
// RecordingState.swift (see scripts/check-shortcut-responsiveness.sh). The fake recorder mirrors
// RecorderUIManager.toggleRecorderPanel, so the handler runs exactly as in the app.

final class RecordingShortcutManager {
    enum Mode: String { case toggle, pushToTalk, hybrid, doubleTap }
}

struct StubModeConfiguration { let name: String }
struct StubModeTemplate { let id: UUID; let name: String }

final class ModeManager {
    static let shared = ModeManager()
    func getConfiguration(with id: UUID) -> StubModeConfiguration? { nil }
}

enum StarterModeCatalog {
    static let templates: [StubModeTemplate] = []
}

@MainActor
final class FakeRecorder {
    var state: RecordingState = .idle
    var isVisible = false
    var events: [String] = []

    /// Mirrors the real recorder, whose start awaits the audio engine: the toggle stays suspended
    /// until `resumeStart()`, so other shortcut events can run in between.
    var startSuspends = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    var isStartPending: Bool { startContinuation != nil }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func toggleAwaitingStart(modeId: UUID?) async {
        let wasVisible = isVisible
        toggle(modeId: modeId)
        if !wasVisible && startSuspends {
            state = .starting
            await withCheckedContinuation { startContinuation = $0 }
            if state == .starting { state = .recording }
        }
    }

    func toggle(modeId: UUID?) {
        let suffix = modeId.map { " mode=\($0.uuidString.prefix(4))" } ?? ""
        if isVisible {
            switch state {
            case .recording:
                state = .transcribing
                events.append("stop" + suffix)
            case .starting, .transcribing, .enhancing:
                cancel()
            case .idle, .busy:
                isVisible = false
                events.append("dismiss")
            }
        } else {
            isVisible = true
            state = .recording
            events.append("start" + suffix)
        }
    }

    func cancel() {
        state = .idle
        isVisible = false
        events.append("cancel")
    }

    /// A lone hybrid tap: dropped without a history entry.
    func discard() {
        state = .idle
        isVisible = false
        events.append("discard")
    }

    /// The pipeline closes the panel before pasting and reports idle last.
    func finishPipeline() {
        isVisible = false
        state = .idle
    }
}

/// Timers fire only when a scenario says time has passed, so the checks stay deterministic.
@MainActor
final class FakeTimers {
    var pending: [@MainActor () async -> Void] = []

    func fireAll() async {
        let due = pending
        pending.removeAll()
        for work in due { await work() }
    }
}

@MainActor
struct Scenario {
    let recorder = FakeRecorder()
    let timers = FakeTimers()
    let handler: RecordingShortcutModeHandler
    let mode: RecordingShortcutManager.Mode
    let action: ShortcutAction

    init(mode: RecordingShortcutManager.Mode, action: ShortcutAction = .primaryRecording) {
        let recorder = self.recorder
        let timers = self.timers
        self.mode = mode
        self.action = action
        handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                ![.transcribing, .enhancing, .busy].contains(recorder.state)
            },
            isRecorderVisible: { recorder.isVisible },
            recordingState: { recorder.state },
            toggleRecorderPanel: { modeId in await recorder.toggleAwaitingStart(modeId: modeId) },
            cancelRecording: { recorder.cancel() },
            discardRecording: { recorder.discard() },
            scheduleAfter: { _, work in timers.pending.append(work) }
        )
    }

    // Lines 1-120 are recovered verbatim (16.10.2026); from here on the file was rebuilt on
    // 04.11.2026 from the recovered scenario names, helper signatures and two recovered scenarios.

    func down(_ time: TimeInterval, modeId: UUID? = nil) async {
        await handler.handleShortcutDown(action: action, eventTime: time, mode: mode, modeId: modeId)
    }

    func up(_ time: TimeInterval, modeId: UUID? = nil) async {
        await handler.handleShortcutUp(action: action, eventTime: time, mode: mode, modeId: modeId)
    }

    func tap(_ time: TimeInterval, modeId: UUID? = nil) async {
        await down(time, modeId: modeId)
        await up(time + 0.05, modeId: modeId)
    }

    /// Lets every pending timer (the hybrid second-tap window) run out.
    func elapse() async {
        await timers.fireAll()
    }

    /// The engine reported a new recording state; mirrors RecordingShortcutManager's observer.
    func stateChanged(_ now: TimeInterval) async {
        await handler.resumeDeferredPress(now: now)
    }

    /// The previous dictation finished: panel closed, engine idle, observer fires.
    func finishPipeline(at now: TimeInterval) async {
        recorder.finishPipeline()
        await stateChanged(now)
    }
}

@MainActor
var failures = 0

@main
enum RecordingShortcutResponsivenessCheck {
    @MainActor
    static func expect(_ name: String, _ scenario: Scenario, events: [String], state: RecordingState) {
        let passed = scenario.recorder.events == events && scenario.recorder.state == state
        if passed {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name): got \(scenario.recorder.events) / \(scenario.recorder.state), expected \(events) / \(state)")
        }
    }

    @MainActor
    static func main() async {
        // Toggle: a tap while the previous dictation is still transcribing waits for it and then
        // starts the next one instead of being lost.
        do {
            let s = Scenario(mode: .toggle)
            await s.tap(0)
            await s.tap(1.0)
            await s.tap(1.5)
            await s.finishPipeline(at: 1.8)
            await s.tap(3.0)
            expect("toggle: tap during transcribing starts the next dictation, next tap stops it", s,
                   events: ["start", "stop", "start", "stop"], state: .transcribing)
        }

        // A deliberate stop-then-start right after the pipeline finished.
        do {
            let s = Scenario(mode: .toggle)
            await s.tap(0)
            await s.tap(1.0)
            await s.finishPipeline(at: 1.1)
            await s.tap(1.25)
            expect("toggle: tap 250 ms after stopping starts again", s,
                   events: ["start", "stop", "start"], state: .recording)
        }

        // Key bounce and accidental double presses are still filtered.
        do {
            let s = Scenario(mode: .toggle)
            await s.tap(0)
            await s.tap(0.15)
            expect("toggle: a second press within 200 ms is ignored", s,
                   events: ["start"], state: .recording)
        }

        // Push to talk: a press held during transcribing records as soon as the engine is idle.
        do {
            let s = Scenario(mode: .pushToTalk)
            await s.down(0)
            await s.up(1.0)
            await s.down(1.2)
            await s.finishPipeline(at: 1.5)
            await s.up(3.0)
            expect("push to talk: held press during transcribing records until release", s,
                   events: ["start", "stop", "start", "stop"], state: .transcribing)
        }

        // Push to talk: a tap released before recording could start records nothing.
        do {
            let s = Scenario(mode: .pushToTalk)
            await s.down(0)
            await s.up(1.0)
            await s.tap(1.2)
            await s.finishPipeline(at: 1.5)
            expect("push to talk: tap released during transcribing is dropped", s,
                   events: ["start", "stop"], state: .idle)
        }

        // A tap made early in a long enhancement would start seconds later; it is dropped.
        do {
            let s = Scenario(mode: .toggle)
            await s.tap(0)
            await s.tap(1.0)
            s.recorder.state = .enhancing
            await s.tap(1.3)
            await s.finishPipeline(at: 3.0)
            await s.tap(3.5)
            expect("toggle: stale tap during long enhancement is dropped, next tap starts", s,
                   events: ["start", "stop", "start"], state: .recording)
        }

        // Hybrid: a long hold that waited for the pipeline counts as push to talk.
        do {
            let s = Scenario(mode: .hybrid)
            await s.down(0)
            await s.up(1.0)
            await s.down(1.2)
            await s.finishPipeline(at: 1.4)
            await s.up(2.5)
            expect("hybrid: held press during transcribing stops on release", s,
                   events: ["start", "stop", "start", "stop"], state: .transcribing)
        }

        // Hybrid (Yannik's setting) works like Wispr Flow from here on.
        // Holding is push to talk.
        do {
            let s = Scenario(mode: .hybrid)
            await s.down(0)
            await s.up(1.0)
            expect("hybrid: hold records, release stops", s,
                   events: ["start", "stop"], state: .transcribing)
        }

        // A lone short tap records only until the second-tap window runs out, then is dropped.
        do {
            let s = Scenario(mode: .hybrid)
            await s.tap(0)
            expect("hybrid: single tap records while waiting for a second tap", s,
                   events: ["start"], state: .recording)
            await s.elapse()
            expect("hybrid: single tap without second tap is discarded", s,
                   events: ["start", "discard"], state: .idle)
        }

        // Double tap latches hands-free; the next press stops and pastes.
        do {
            let s = Scenario(mode: .hybrid)
            await s.tap(0)
            await s.tap(0.18)
            await s.elapse()
            expect("hybrid: double tap keeps recording hands-free", s,
                   events: ["start"], state: .recording)
            await s.tap(3.0)
            expect("hybrid: press after double tap stops", s,
                   events: ["start", "stop"], state: .transcribing)
        }

        // A busy main thread makes WindowServer coalesce release 1 and press 2 into one event; the
        // monitor then reports both at the same instant. That is still a double tap.
        do {
            let s = Scenario(mode: .hybrid)
            await s.down(0)
            await s.up(0.10)
            await s.down(0.10)
            await s.up(0.14)
            await s.elapse()
            expect("hybrid: coalesced release and second press latches hands-free", s,
                   events: ["start"], state: .recording)
        }

        // Holding the second tap of a double tap does not stop on release.
        do {
            let s = Scenario(mode: .hybrid)
            await s.tap(0)
            await s.down(0.18)
            await s.up(1.5)
            await s.elapse()
            expect("hybrid: releasing the latching second tap changes nothing", s,
                   events: ["start"], state: .recording)
            await s.down(3.0)
            await s.up(4.0)
            expect("hybrid: holding the stop press stops once", s,
                   events: ["start", "stop"], state: .transcribing)
        }

        // Taps further apart than the second-tap window are two separate lone taps.
        do {
            let s = Scenario(mode: .hybrid)
            await s.tap(0)
            await s.elapse()
            await s.tap(1.0)
            await s.elapse()
            expect("hybrid: two slow taps are two discarded single taps", s,
                   events: ["start", "discard", "start", "discard"], state: .idle)
        }

        // A second tap after the window (timer not yet run) is a press on a running recording.
        do {
            let s = Scenario(mode: .hybrid)
            await s.tap(0)
            await s.tap(0.6)
            await s.elapse()
            expect("hybrid: a late tap stops instead of latching", s,
                   events: ["start", "stop"], state: .transcribing)
        }

        // The recording was cancelled elsewhere (Esc) before the window ran out.
        do {
            let s = Scenario(mode: .hybrid)
            await s.tap(0)
            s.recorder.cancel()
            await s.elapse()
            expect("hybrid: timer after an external cancel does nothing", s,
                   events: ["start", "cancel"], state: .idle)
        }

        // Both taps of a double tap arrive while the previous dictation is still transcribing.
        do {
            let s = Scenario(mode: .hybrid)
            await s.down(0)
            await s.up(1.0)
            await s.tap(1.2)
            await s.tap(1.4)
            await s.finishPipeline(at: 1.6)
            await s.elapse()
            await s.tap(3.0)
            expect("hybrid: double tap during transcribing starts hands-free, next press stops", s,
                   events: ["start", "stop", "start", "stop"], state: .transcribing)
        }

        // Starting the recorder takes longer than a quick tap: the key-up arrives mid-start.
        do {
            let s = Scenario(mode: .hybrid)
            s.recorder.startSuspends = true
            let press = Task { @MainActor in await s.down(0) }
            while !s.recorder.isStartPending { await Task.yield() }
            await s.up(0.05)
            s.recorder.resumeStart()
            await press.value
            await s.elapse()
            expect("hybrid: tap released while the recorder starts is still discarded", s,
                   events: ["start", "discard"], state: .idle)
        }

        // A lone tap during transcribing never records.
        do {
            let s = Scenario(mode: .hybrid)
            await s.down(0)
            await s.up(1.0)
            await s.tap(1.2)
            await s.finishPipeline(at: 1.4)
            await s.elapse()
            expect("hybrid: single tap during transcribing is dropped", s,
                   events: ["start", "stop"], state: .idle)
        }

        // First tap while transcribing, second tap right after the pipeline finished.
        do {
            let s = Scenario(mode: .hybrid)
            await s.down(0)
            await s.up(1.0)
            await s.tap(1.2)
            await s.finishPipeline(at: 1.3)
            await s.tap(1.45)
            await s.elapse()
            expect("hybrid: double tap across the end of transcribing latches hands-free", s,
                   events: ["start", "stop", "start"], state: .recording)
        }

        // Another key joined a waiting press: a key combination, not a request to record.
        do {
            let s = Scenario(mode: .pushToTalk)
            await s.down(0)
            await s.up(1.0)
            await s.down(1.2)
            await s.handler.handleInterruption(action: s.action)
            await s.up(1.3)
            await s.finishPipeline(at: 1.5)
            expect("push to talk: interrupted press during transcribing is discarded", s,
                   events: ["start", "stop"], state: .idle)
        }

        // Cancelling the dictation a tap is waiting for also drops the tap.
        do {
            let s = Scenario(mode: .toggle)
            await s.tap(0)
            await s.tap(1.0)
            await s.tap(1.2)
            s.recorder.cancel()
            s.handler.discardDeferredPress()
            await s.stateChanged(1.3)
            expect("toggle: waiting tap is dropped when the dictation is cancelled", s,
                   events: ["start", "stop", "cancel"], state: .idle)
        }

        // A mode shortcut's replayed tap keeps its mode.
        do {
            let modeId = UUID()
            let tag = " mode=\(modeId.uuidString.prefix(4))"
            let s = Scenario(mode: .toggle, action: .mode(modeId))
            await s.tap(0, modeId: modeId)
            await s.tap(1.0, modeId: modeId)
            await s.tap(1.3, modeId: modeId)
            await s.finishPipeline(at: 1.5)
            expect("mode shortcut: replayed tap starts in its own mode", s,
                   events: ["start" + tag, "stop" + tag, "start" + tag], state: .recording)
        }

        // Double-tap mode keeps ignoring presses while the pipeline is busy.
        do {
            let s = Scenario(mode: .doubleTap)
            await s.tap(0)
            await s.tap(0.2)
            await s.tap(1.0)
            await s.tap(1.2)
            await s.tap(1.5)
            await s.tap(1.7)
            await s.finishPipeline(at: 2.0)
            expect("double tap: presses during transcribing are ignored as before", s,
                   events: ["start", "stop"], state: .idle)
        }

        if failures == 0 {
            print("All shortcut responsiveness scenarios passed")
            exit(0)
        }
        print("\(failures) shortcut responsiveness scenario(s) FAILED")
        exit(1)
    }
}
