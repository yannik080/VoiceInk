import AppKit
import Combine
import Foundation

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
            shortcutModeHandler.resetShortcutState(for: .primaryRecording)
            modeShortcutManager.recordingModeDidChange()
            updateStandaloneModifierActions()
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
            updateStandaloneModifierActions()
        }
    }
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private var recordingStateObserver: AnyCancellable?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"
        case doubleTap = "doubleTap"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            case .doubleTap: return String(localized: "Double Tap")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            discardRecording: {
                await recorderUIManager.cancelRecording(keepsCanceledRecording: false)
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        // `@Published` emits before the new value is stored, so the replay hops to the next main
        // actor turn and reads the settled state there.
        recordingStateObserver = engine.$recordingState
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.resumeDeferredShortcutPress()
                }
            }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }

    private func resumeDeferredShortcutPress() async {
        // A cancelled dictation goes idle while its pipeline is still winding down; starting a new
        // recording then would race the old session's cleanup.
        guard !engine.shouldCancelRecording else {
            shortcutModeHandler.discardDeferredPress()
            return
        }
        await shortcutModeHandler.resumeDeferredPress(now: ProcessInfo.processInfo.systemUptime)
    }

    private func refreshShortcutMonitoring() {
        removeAllMonitoring()

        refreshShortcutMonitor()
    }

    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            standaloneModifierActions: standaloneModifierActions,
            onShortcutDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleShortcutDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onShortcutUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleShortcutUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            },
            onStandaloneModifierChord: { [weak self] action in
                MainActor.assumeIsolated {
                    self?.shortcutModeHandler.clearPendingDoubleTap(for: action)
                }
            }
        )
    }

    private var standaloneModifierActions: Set<ShortcutAction> {
        var actions = Set<ShortcutAction>()
        if primaryRecordingShortcutMode == .toggle || primaryRecordingShortcutMode == .doubleTap {
            actions.insert(.primaryRecording)
        }
        if secondaryRecordingShortcutMode == .toggle || secondaryRecordingShortcutMode == .doubleTap {
            actions.insert(.secondaryRecording)
        }
        return actions
    }

    private func updateStandaloneModifierActions() {
        shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions)
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openQuickHistory:
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()

        shortcutModeHandler.reset()
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}
