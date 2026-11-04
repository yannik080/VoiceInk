import AppKit
import Carbon.HIToolbox

// Compile together with ShortcutMonitor.swift, Shortcut.swift, ShortcutAction.swift and
// UserSessionInputPolicy.swift (see scripts/check-shortcut-monitor.sh). Feeds the monitor the
// modifier events WindowServer delivers and checks which shortcut transitions it reports.

struct StubModeConfiguration { let name: String }
struct StubModeTemplate { let id: UUID; let name: String }

final class ModeManager {
    static let shared = ModeManager()
    func getConfiguration(with id: UUID) -> StubModeConfiguration? { nil }
}

enum StarterModeCatalog {
    static let templates: [StubModeTemplate] = []
}

struct LegacyKeyboardShortcut {
    let carbonKeyCode: Int
    let carbonModifiers: Int
}

final class Recorder {
    var events: [String] = []
}

func run(_ name: String, shortcut: Shortcut, feed: (ShortcutMonitor) -> Void, expect expected: [String]) -> Bool {
    let monitor = ShortcutMonitor()
    let recorder = Recorder()
    monitor.start(
        shortcuts: [.primaryRecording: shortcut],
        interruptibleActions: [.primaryRecording],
        onShortcutDown: { _, time in recorder.events.append(String(format: "down@%.2f", time)) },
        onShortcutUp: { _, time in recorder.events.append(String(format: "up@%.2f", time)) }
    )
    feed(monitor)
    // Callbacks are delivered asynchronously on the main queue.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    monitor.stop()
    let passed = recorder.events == expected
    print("\(passed ? "PASS" : "FAIL"): \(name)\(passed ? "" : " got \(recorder.events), expected \(expected)")")
    return passed
}

func flags(_ monitor: ShortcutMonitor, _ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags, at time: TimeInterval) {
    _ = monitor.handleEvent(kind: .flagsChanged, inputCode: UInt16(keyCode), modifierFlags: modifierFlags, eventTime: time)
}

let fn = Shortcut.modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
var allPassed = true

allPassed = run("fn: press and release", shortcut: fn, feed: { m in
    flags(m, kVK_Function, [.function], at: 1.0)
    flags(m, kVK_Function, [], at: 1.1)
}, expect: ["down@1.00", "up@1.10"]) && allPassed

allPassed = run("fn: clean double tap", shortcut: fn, feed: { m in
    flags(m, kVK_Function, [.function], at: 1.0)
    flags(m, kVK_Function, [], at: 1.04)
    flags(m, kVK_Function, [.function], at: 1.10)
    flags(m, kVK_Function, [], at: 1.14)
}, expect: ["down@1.00", "up@1.04", "down@1.10", "up@1.14"]) && allPassed

// Seen in the app log (16.10.2026): while the recorder starts, release 1 and press 2 arrive as one
// event that still has fn down. Before the fix this ended the first tap and lost the second.
allPassed = run("fn: coalesced release and press is a second tap", shortcut: fn, feed: { m in
    flags(m, kVK_Function, [.function], at: 1.0)
    flags(m, kVK_Function, [.function], at: 1.10)
    flags(m, kVK_Function, [], at: 1.14)
}, expect: ["down@1.00", "up@1.10", "down@1.10", "up@1.14"]) && allPassed

allPassed = run("fn: another modifier while fn is held changes nothing", shortcut: fn, feed: { m in
    flags(m, kVK_Function, [.function], at: 1.0)
    flags(m, kVK_Shift, [.function, .shift], at: 1.05)
    flags(m, kVK_Shift, [.function], at: 1.08)
    flags(m, kVK_Function, [], at: 1.2)
}, expect: ["down@1.00", "up@1.20"]) && allPassed

allPassed = run("fn: releasing fn while shift is held releases", shortcut: fn, feed: { m in
    flags(m, kVK_Function, [.function], at: 1.0)
    flags(m, kVK_Shift, [.function, .shift], at: 1.05)
    flags(m, kVK_Function, [.shift], at: 1.1)
}, expect: ["down@1.00", "up@1.10"]) && allPassed

let rightCommand = Shortcut.rightCommand
allPassed = run("right command: coalesced release and press is a second tap", shortcut: rightCommand, feed: { m in
    flags(m, kVK_RightCommand, [.command], at: 2.0)
    flags(m, kVK_RightCommand, [.command], at: 2.1)
    flags(m, kVK_RightCommand, [], at: 2.2)
}, expect: ["down@2.00", "up@2.10", "down@2.10", "up@2.20"]) && allPassed

print(allPassed ? "All shortcut monitor scenarios passed" : "Shortcut monitor scenarios FAILED")
exit(allPassed ? 0 : 1)
