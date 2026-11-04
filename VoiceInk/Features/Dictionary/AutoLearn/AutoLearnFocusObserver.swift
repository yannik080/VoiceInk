import ApplicationServices
import Foundation

private final class AutoLearnFocusCallbackBridge: @unchecked Sendable {
    let token: AutoLearnPasteToken
    let handler: @Sendable (AutoLearnPasteToken) -> Void
    let valueHandler: @Sendable (AutoLearnPasteToken) -> Void

    init(
        token: AutoLearnPasteToken,
        handler: @escaping @Sendable (AutoLearnPasteToken) -> Void,
        valueHandler: @escaping @Sendable (AutoLearnPasteToken) -> Void
    ) {
        self.token = token
        self.handler = handler
        self.valueHandler = valueHandler
    }

    func notify(_ notification: CFString) {
        if CFEqual(notification, kAXValueChangedNotification as CFString) {
            valueHandler(token)
        } else {
            handler(token)
        }
    }
}

private let autoLearnFocusCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let bridge = Unmanaged<AutoLearnFocusCallbackBridge>.fromOpaque(refcon).takeUnretainedValue()
    bridge.notify(notification)
}

final class AutoLearnFocusObserver: @unchecked Sendable {
    private struct State {
        var generation: UUID?
        var runLoop: CFRunLoop?
        var shouldRun: Bool = false
    }

    private let lock = NSLock()
    private var state = State()

    func start(
        processID: pid_t,
        token: AutoLearnPasteToken,
        handler: @escaping @Sendable (AutoLearnPasteToken) -> Void,
        valueHandler: @escaping @Sendable (AutoLearnPasteToken) -> Void
    ) {
        stop()

        let generation = UUID()
        withLock {
            state.generation = generation
            state.runLoop = nil
            state.shouldRun = true
        }

        let thread = Thread { [weak self] in
            self?.run(
                processID: processID,
                token: token,
                generation: generation,
                handler: handler,
                valueHandler: valueHandler
            )
        }
        thread.name = "VoiceInk Auto Learn Focus Observer"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        let runLoop = withLock { () -> CFRunLoop? in
            state.generation = nil
            state.shouldRun = false
            let runLoop = state.runLoop
            state.runLoop = nil
            return runLoop
        }

        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    deinit {
        stop()
    }

    private func run(
        processID: pid_t,
        token: AutoLearnPasteToken,
        generation: UUID,
        handler: @escaping @Sendable (AutoLearnPasteToken) -> Void,
        valueHandler: @escaping @Sendable (AutoLearnPasteToken) -> Void
    ) {
        autoreleasepool {
            let appElement = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(appElement, AutoLearnLimits.accessibilityTimeoutSeconds)

            var observer: AXObserver?
            guard AXObserverCreate(processID, autoLearnFocusCallback, &observer) == .success,
                let observer
            else {
                clearState(for: generation)
                return
            }

            let bridge = AutoLearnFocusCallbackBridge(
                token: token,
                handler: handler,
                valueHandler: valueHandler
            )
            let refcon = Unmanaged.passRetained(bridge).toOpaque()
            let requestedNotifications = [
                kAXFocusedUIElementChangedNotification as String,
                kAXFocusedWindowChangedNotification as String,
                kAXApplicationDeactivatedNotification as String,
            ]
            var registeredNotifications: [(element: AXUIElement, name: String)] = []

            for notification in requestedNotifications {
                if AXObserverAddNotification(observer, appElement, notification as CFString, refcon) == .success {
                    registeredNotifications.append((appElement, notification))
                }
            }

            guard !registeredNotifications.isEmpty else {
                Unmanaged<AutoLearnFocusCallbackBridge>.fromOpaque(refcon).release()
                clearState(for: generation)
                return
            }

            // Value changes only on the dictated field; registering on the
            // application would report every changing control in a browser.
            var focusedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            ) == .success,
                let focusedValue,
                CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
            {
                let focusedElement = focusedValue as! AXUIElement
                if AXObserverAddNotification(
                    observer,
                    focusedElement,
                    kAXValueChangedNotification as CFString,
                    refcon
                ) == .success {
                    registeredNotifications.append(
                        (focusedElement, kAXValueChangedNotification as String)
                    )
                }
            }

            let runLoop = CFRunLoopGetCurrent()
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(runLoop, source, .defaultMode)

            let shouldRun = withLock { () -> Bool in
                guard state.shouldRun, state.generation == generation else { return false }
                state.runLoop = runLoop
                return true
            }
            guard shouldRun else {
                CFRunLoopRemoveSource(runLoop, source, .defaultMode)
                for registration in registeredNotifications {
                    AXObserverRemoveNotification(observer, registration.element, registration.name as CFString)
                }
                Unmanaged<AutoLearnFocusCallbackBridge>.fromOpaque(refcon).release()
                clearState(for: generation)
                return
            }

            // Bounded slices catch `stop()` calls that arrive just before the
            // run loop starts and would otherwise be lost.
            var isRunning = true
            while isRunning {
                CFRunLoopRunInMode(.defaultMode, 0.25, true)
                isRunning = withLock { state.shouldRun && state.generation == generation }
            }

            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            for registration in registeredNotifications {
                AXObserverRemoveNotification(observer, registration.element, registration.name as CFString)
            }
            Unmanaged<AutoLearnFocusCallbackBridge>.fromOpaque(refcon).release()
            clearState(for: generation)
        }
    }

    private func clearState(for generation: UUID) {
        withLock {
            guard state.generation == generation else { return }
            state.generation = nil
            state.runLoop = nil
            state.shouldRun = false
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
