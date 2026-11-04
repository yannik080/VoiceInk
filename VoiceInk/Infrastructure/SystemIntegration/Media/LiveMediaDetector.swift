import Foundation

/// Decides whether the Now Playing item is live (a livestream, a football match). Pausing live
/// media drops it out of live, so VoiceInk mutes it during the recording instead.
///
/// MediaRemote has no live flag. Live players show up in three ways:
/// - no finite duration (HTML video reports `Infinity` for a live stream, apps report nothing or 0),
/// - a position past the reported duration,
/// - a duration that grows with the clock: the seekable window of a live stream with rewind (DVR).
/// Music, podcasts and normal videos report a fixed duration and are still paused.
struct LiveMediaDetector {
    struct Observation: Equatable {
        /// Player and item, e.g. bundle identifier plus title.
        let identity: String
        let durationSeconds: Double?
        let elapsedSeconds: Double?
        /// System uptime of the observation.
        let uptime: TimeInterval
    }

    enum Reason: String {
        case noDuration = "no-duration"
        case pastEnd = "past-end"
        case growingDuration = "growing-duration"
    }

    /// A DVR window grows by about one second per second; smaller jitter is ignored.
    static let minimumGrowth: Double = 2
    /// Growth may exceed the time that passed only by this much, so a late metadata update
    /// (a duration of 30 s becoming 600 s) is not mistaken for a live window.
    static let growthTolerance: Double = 5
    static let pastEndTolerance: Double = 1

    private var lastObservation: Observation?
    private var growingIdentity: String?

    /// Feed every Now Playing update so a growing duration can be noticed.
    mutating func observe(_ observation: Observation) {
        defer { lastObservation = observation }
        if growingIdentity != nil, growingIdentity != observation.identity {
            growingIdentity = nil
        }
        guard let last = lastObservation, last.identity == observation.identity,
            let oldDuration = last.durationSeconds, let newDuration = observation.durationSeconds,
            oldDuration.isFinite, newDuration.isFinite, oldDuration > 0
        else { return }

        let growth = newDuration - oldDuration
        let passed = observation.uptime - last.uptime
        if growth >= Self.minimumGrowth, passed > 0, growth <= passed + Self.growthTolerance {
            growingIdentity = observation.identity
        }
    }

    /// Why the item counts as live, or nil for normal media.
    func liveReason(for observation: Observation) -> Reason? {
        guard let duration = observation.durationSeconds, duration.isFinite, duration > 0 else {
            return .noDuration
        }
        if let elapsed = observation.elapsedSeconds, elapsed.isFinite,
            elapsed > duration + Self.pastEndTolerance
        {
            return .pastEnd
        }
        if growingIdentity == observation.identity {
            return .growingDuration
        }
        return nil
    }
}
