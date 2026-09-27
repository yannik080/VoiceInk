import Foundation

// Compile this executable together with UpdaterViewModel.swift using -D LOCAL_BUILD.
// Run inside a bundle with an isolated identifier; never use VoiceInk's preferences.
@main
struct LocalBuildUpdaterCheck {
    @MainActor
    static func main() {
        guard Bundle.main.bundleIdentifier == "local.voiceink.updater-regression" else {
            fatalError("Run only from the isolated updater regression bundle")
        }
        let defaults = UserDefaults.standard
        let preference = "VoiceInkChecksForUpdatesOnLaunch"
        defaults.set(true, forKey: preference)
        defer { defaults.removePersistentDomain(forName: "local.voiceink.updater-regression") }

        let model = UpdaterViewModel()
        guard !model.checksForUpdatesWhenDashboardAppears, !model.canCheckForUpdates else {
            print("FAIL: local build enables the official updater with an existing opt-in")
            exit(1)
        }
        model.setChecksForUpdatesWhenDashboardAppears(true)
        model.checkForUpdatesIfDue()
        model.checkForUpdates()
        guard !model.checksForUpdatesWhenDashboardAppears,
              !model.canCheckForUpdates,
              model.availableUpdate == nil,
              defaults.bool(forKey: preference) else {
            print("FAIL: local update actions changed updater state or the saved preference")
            exit(1)
        }
        print("PASS: local updater stays disabled; existing update preference is preserved")
    }
}
