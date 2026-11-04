import AppKit
import Combine
import CoreAudio
import Foundation
import MediaRemoteAdapter
import OSLog
import SwiftUI

@MainActor
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()
    private var mediaController: MediaRemoteAdapter.MediaController
    private struct OwnedPause {
        let id = UUID()
        let bundleID: String
        let stateRevision: UInt64
    }

    private var ownedPause: OwnedPause?
    private var recordingSessionID = UUID()
    private var mediaStateRevision: UInt64 = 0
    private var isMediaPlaying = false
    private var lastKnownTrackInfo: TrackInfo?
    private var stateRequests: [UUID: CheckedContinuation<TrackInfo?, Never>] = [:]
    private var listenerRestartTask: Task<Void, Never>?
    private var listenerRestartCount = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MediaPause")
    private var liveMediaDetector = LiveMediaDetector()
    /// Matches the recorder's mute delay, so the start sound is still heard.
    private let liveMuteDelayNanoseconds: UInt64 = 220_000_000

    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")

            if isPauseMediaEnabled {
                startMediaTracking()
            } else {
                stopMediaTracking()
            }
        }
    }

    /// Live media (streams, sports) keeps running muted instead of being paused, so it stays live.
    @Published var isLiveMediaMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isLiveMediaMuteEnabled") {
        didSet { UserDefaults.standard.set(isLiveMediaMuteEnabled, forKey: "isLiveMediaMuteEnabled") }
    }

    private init() {
        mediaController = MediaRemoteAdapter.MediaController()

        setupMediaControllerCallbacks()

        if isPauseMediaEnabled {
            startMediaTracking()
        }
    }

    private func setupMediaControllerCallbacks() {
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            // MediaRemoteAdapter delivers its callbacks on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
                self.lastKnownTrackInfo = trackInfo
                self.mediaStateRevision &+= 1
                if let trackInfo {
                    self.liveMediaDetector.observe(Self.liveObservation(trackInfo))
                }

            }
        }

        mediaController.onListenerTerminated = { [weak self] in
            // The adapter reports termination on the main queue.
            MainActor.assumeIsolated {
                self?.listenerDidTerminate()
            }
        }
    }

    private func startMediaTracking() {
        mediaController.startListening()
    }

    private func stopMediaTracking() {
        recordingSessionID = UUID()
        ownedPause = nil
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        mediaController.stopListening()
        isMediaPlaying = false
        lastKnownTrackInfo = nil
    }

    /// Without a running listener the cached state never changes again and
    /// every later recording would believe nothing is playing.
    private func listenerDidTerminate() {
        guard isPauseMediaEnabled else { return }
        listenerRestartCount += 1
        let delaySeconds = min(listenerRestartCount, 30)
        logger.notice(
            "Media listener terminated; restarting in \(delaySeconds, privacy: .public) s (restart #\(self.listenerRestartCount, privacy: .public))"
        )
        listenerRestartTask?.cancel()
        listenerRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.isPauseMediaEnabled else { return }
            self.mediaController.startListening()
        }
    }

    func beginRecordingSession() -> UUID {
        recordingSessionID = UUID()
        // A new recording inherits a pause whose restoration has not completed.
        return recordingSessionID
    }

    func pauseMedia(sessionID: UUID) async {
        guard sessionID == recordingSessionID, !Task.isCancelled, isPauseMediaEnabled else {
            return
        }
        if let ownedPause {
            if let currentApp = lastKnownTrackInfo?.payload.bundleIdentifier,
                currentApp != ownedPause.bundleID {
                self.ownedPause = nil
            } else if lastKnownTrackInfo?.payload.isPlaying != true {
                logPauseDecision("skip-still-paused-by-voiceink", source: "listener")
                return
            }
        }
        var stateSource = "listener"
        if !(isMediaPlaying && lastKnownTrackInfo?.payload.isPlaying == true) {
            // The listener can miss updates (restart window, events without a
            // title, a terminated helper). Ask MediaRemote directly before
            // concluding that nothing plays.
            let freshTrackInfo = await fetchCurrentTrackInfo()
            guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled else {
                return
            }
            if let freshTrackInfo {
                stateSource = "fresh"
                liveMediaDetector.observe(Self.liveObservation(freshTrackInfo))
                if freshTrackInfo.payload.isPlaying == true {
                    isMediaPlaying = true
                    lastKnownTrackInfo = freshTrackInfo
                    mediaStateRevision &+= 1
                }
            } else {
                stateSource = "fresh-unavailable"
            }
        }

        guard isMediaPlaying, lastKnownTrackInfo?.payload.isPlaying == true else {
            logPauseDecision("skip-not-playing", source: stateSource)
            return
        }
        guard let bundleId = lastKnownTrackInfo?.payload.bundleIdentifier else {
            logPauseDecision("skip-no-player", source: stateSource)
            return
        }

        // A growing live window needs two observations of the same item. When the listener's
        // single update does not show live yet, take one fresh look before pausing.
        if isLiveMediaMuteEnabled, stateSource == "listener", let trackInfo = lastKnownTrackInfo,
            liveMediaDetector.liveReason(for: Self.liveObservation(trackInfo)) == nil
        {
            if let freshTrackInfo = await fetchCurrentTrackInfo() {
                guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled else {
                    return
                }
                liveMediaDetector.observe(Self.liveObservation(freshTrackInfo))
                if freshTrackInfo.payload.isPlaying == true,
                    freshTrackInfo.payload.bundleIdentifier == bundleId
                {
                    lastKnownTrackInfo = freshTrackInfo
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled else {
            return
        }
        guard lastKnownTrackInfo?.payload.bundleIdentifier == bundleId,
            lastKnownTrackInfo?.payload.isPlaying == true else {
            logPauseDecision("skip-state-changed", source: stateSource)
            return
        }

        if isLiveMediaMuteEnabled, let trackInfo = lastKnownTrackInfo,
            let reason = liveMediaDetector.liveReason(for: Self.liveObservation(trackInfo))
        {
            if await muteLiveMedia(sessionID: sessionID, reason: reason, source: stateSource) {
                return
            }
            // The output cannot be muted (HDMI/DisplayPort, many USB DACs): pausing still keeps
            // the stream out of the microphone, so fall back to the normal pause.
            guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled,
                lastKnownTrackInfo?.payload.bundleIdentifier == bundleId,
                lastKnownTrackInfo?.payload.isPlaying == true
            else {
                return
            }
        }

        // Own only commands actually queued, not a cancelled 50 ms pre-pause delay.
        let pause = OwnedPause(bundleID: bundleId, stateRevision: mediaStateRevision)
        ownedPause = pause
        mediaController.pause()
        logPauseDecision("pause", source: stateSource)

        await verifyPause(pause, sessionID: sessionID)
    }

    /// Pausing a live stream drops it out of live: mute the output instead. The recorder restores
    /// it with the system mute when recording stops, and cancels this task if it stops first.
    /// Returns true when the output is muted; false when it was cancelled or could not be muted.
    private func muteLiveMedia(sessionID: UUID, reason: LiveMediaDetector.Reason, source: String) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: liveMuteDelayNanoseconds)
        } catch {
            return false
        }
        guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled else { return false }
        let muted = MediaController.shared.muteOutputForLiveMedia(sessionID: sessionID)
        logPauseDecision(
            muted ? "mute-live" : "mute-live-failed-pausing",
            source: "\(source) live=\(reason.rawValue)"
        )
        return muted
    }

    private static func liveObservation(_ trackInfo: TrackInfo) -> LiveMediaDetector.Observation {
        let payload = trackInfo.payload
        return LiveMediaDetector.Observation(
            identity: "\(payload.bundleIdentifier ?? "")|\(payload.title ?? "")",
            durationSeconds: payload.durationMicros.map { $0 / 1_000_000 },
            // Reported position, not extrapolated: a long gap since the last update must not look
            // like a position past the end.
            elapsedSeconds: payload.elapsedTimeMicros.map { $0 / 1_000_000 },
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Some players ignore the MediaRemote pause command but honour the media
    /// key. The recorder cancels this task when recording stops, so the key
    /// can only be sent while the recording is still running.
    private func verifyPause(_ pause: OwnedPause, sessionID: UUID) async {
        do {
            try await Task.sleep(nanoseconds: 1_200_000_000)
        } catch {
            return
        }
        guard canRestore(pause, sessionID: sessionID) else { return }
        let currentTrackInfo = await fetchCurrentTrackInfo()
        guard canRestore(pause, sessionID: sessionID) else { return }
        guard let currentTrackInfo,
            currentTrackInfo.payload.bundleIdentifier == pause.bundleID,
            currentTrackInfo.payload.isPlaying == true
        else {
            logger.notice(
                "Media pause confirmed player=\(pause.bundleID, privacy: .public) stateKnown=\(currentTrackInfo != nil, privacy: .public)"
            )
            return
        }
        logger.notice(
            "Media pause ignored by player=\(pause.bundleID, privacy: .public); sending media key"
        )
        Self.sendMediaPlayPauseKey()
    }

    private func logPauseDecision(_ decision: String, source: String) {
        let player = lastKnownTrackInfo?.payload.bundleIdentifier ?? "none"
        let playing = lastKnownTrackInfo?.payload.isPlaying.map(String.init) ?? "unknown"
        let duration = lastKnownTrackInfo?.payload.durationMicros.map { String(format: "%.0f", $0 / 1_000_000) } ?? "none"
        let audioOutput = Self.processesWithRunningAudioOutput().joined(separator: ",")
        logger.notice(
            "Media pause decision=\(decision, privacy: .public) source=\(source, privacy: .public) player=\(player, privacy: .public) playing=\(playing, privacy: .public) duration=\(duration, privacy: .public) audioOutput=\(audioOutput, privacy: .public)"
        )
    }

    /// Bundle identifiers of processes currently sending audio to an output
    /// device. Diagnostic only: shows sound VoiceInk could not pause because
    /// it does not come from the Now Playing app.
    private static func processesWithRunningAudioOutput() -> [String] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &listSize) == noErr,
            listSize > 0
        else {
            return []
        }
        var processObjects = [AudioObjectID](
            repeating: 0,
            count: Int(listSize) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObject,
            &listAddress,
            0,
            nil,
            &listSize,
            &processObjects
        ) == noErr else {
            return []
        }

        var result: [String] = []
        for processObject in processObjects {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                processObject,
                &runningAddress,
                0,
                nil,
                &runningSize,
                &isRunning
            ) == noErr, isRunning != 0 else {
                continue
            }

            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleID: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleStatus = withUnsafeMutablePointer(to: &bundleID) { pointer in
                AudioObjectGetPropertyData(processObject, &bundleAddress, 0, nil, &bundleSize, pointer)
            }
            if bundleStatus == noErr, let value = bundleID?.takeRetainedValue() as String?, !value.isEmpty {
                result.append(value)
            } else {
                result.append("unknown")
            }
        }
        return result.sorted()
    }

    func resumeMedia(sessionID: UUID) async {
        guard sessionID == recordingSessionID, !Task.isCancelled, isPauseMediaEnabled else {
            return
        }
        guard let pause = ownedPause else {
            return
        }
        // Recorder owns the cancellable restoration task; no nested task is needed.
        await restorePlayback(pause: pause, sessionID: sessionID)
    }

    private func canRestore(_ pause: OwnedPause, sessionID: UUID) -> Bool {
        !Task.isCancelled && isPauseMediaEnabled
            && sessionID == recordingSessionID && ownedPause?.id == pause.id
    }

    private func restorePlayback(pause: OwnedPause, sessionID: UUID) async {
        let delay = MediaController.shared.audioResumptionDelay

        // The adapter debounces state changes. Keep ownership while its pause update arrives.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while canRestore(pause, sessionID: sessionID),
            ProcessInfo.processInfo.systemUptime < deadline {
            if mediaStateRevision > pause.stateRevision,
                lastKnownTrackInfo?.payload.bundleIdentifier == pause.bundleID,
                lastKnownTrackInfo?.payload.isPlaying == false {
                break
            }
            if let currentApp = lastKnownTrackInfo?.payload.bundleIdentifier,
                currentApp != pause.bundleID {
                break
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }

        guard canRestore(pause, sessionID: sessionID) else { return }
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
        guard canRestore(pause, sessionID: sessionID) else { return }

        // Re-read live state after the delay: a global toggle must not pause media
        // the user already resumed, or act on another player.
        let currentTrackInfo = await fetchCurrentTrackInfo()
        guard canRestore(pause, sessionID: sessionID) else { return }
        guard isAppStillRunning(bundleId: pause.bundleID) else {
            ownedPause = nil
            return
        }
        guard let currentTrackInfo, let currentBundleId = currentTrackInfo.payload.bundleIdentifier else {
            // Do not blindly toggle or forget a pause if the state lookup failed.
            return
        }
        guard currentBundleId == pause.bundleID else {
            ownedPause = nil
            return
        }
        guard currentTrackInfo.payload.isPlaying != true else {
            ownedPause = nil
            return
        }
        guard currentTrackInfo.payload.isPlaying == false else {
            return
        }

        Self.sendMediaPlayPauseKey()
        ownedPause = nil
    }

    private func fetchCurrentTrackInfo() async -> TrackInfo? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                stateRequests[requestID] = continuation
                mediaController.getTrackInfo { [weak self] trackInfo in
                    MainActor.assumeIsolated {
                        self?.finishStateRequest(requestID, trackInfo: trackInfo)
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.finishStateRequest(requestID, trackInfo: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishStateRequest(requestID, trackInfo: nil)
            }
        }
    }

    private func finishStateRequest(_ requestID: UUID, trackInfo: TrackInfo?) {
        stateRequests.removeValue(forKey: requestID)?.resume(returning: trackInfo)
    }

    /// Simulate the hardware media Play/Pause key (NX_KEYTYPE_PLAY = 16).
    /// Some apps (e.g. Plexamp) ignore the MediaRemote `play` command but
    /// respond to the same HID key event the physical F8 key produces.
    private static func sendMediaPlayPauseKey() {
        func post(down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    private func isAppStillRunning(bundleId: String) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleId }
    }
}
