import Foundation

// Compile together with LiveMediaDetector.swift (see scripts/check-live-media.sh).
// Live media is muted during a recording instead of paused; everything else is still paused.

var failures = 0

func check(_ name: String, _ got: LiveMediaDetector.Reason?, _ expected: LiveMediaDetector.Reason?) {
    if got == expected {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name): got \(got?.rawValue ?? "pause"), expected \(expected?.rawValue ?? "pause")")
    }
}

func obs(_ identity: String, duration: Double?, elapsed: Double?, at uptime: TimeInterval) -> LiveMediaDetector.Observation {
    .init(identity: identity, durationSeconds: duration, elapsedSeconds: elapsed, uptime: uptime)
}

// Normal media is paused.
do {
    let d = LiveMediaDetector()
    check("song with fixed duration is paused", d.liveReason(for: obs("Spotify|Song", duration: 215, elapsed: 40, at: 10)), nil)
    check("video near its end is paused", d.liveReason(for: obs("Safari|Video", duration: 600, elapsed: 599.5, at: 10)), nil)
}

// No finite duration: a live stream.
do {
    let d = LiveMediaDetector()
    check("missing duration is live", d.liveReason(for: obs("Safari|Twitch", duration: nil, elapsed: 120, at: 10)), .noDuration)
    check("zero duration is live", d.liveReason(for: obs("Chrome|Match", duration: 0, elapsed: 0, at: 10)), .noDuration)
    check("infinite duration is live", d.liveReason(for: obs("Safari|Stream", duration: .infinity, elapsed: 50, at: 10)), .noDuration)
    check("NaN duration is live", d.liveReason(for: obs("Safari|Stream", duration: .nan, elapsed: 50, at: 10)), .noDuration)
}

// Position past the end.
do {
    let d = LiveMediaDetector()
    check("position past the duration is live", d.liveReason(for: obs("Chrome|Live", duration: 3600, elapsed: 3700, at: 10)), .pastEnd)
    check("position just at the end is paused", d.liveReason(for: obs("Chrome|Video", duration: 3600, elapsed: 3600.5, at: 10)), nil)
}

// A rewindable live stream: the duration grows with the clock.
do {
    var d = LiveMediaDetector()
    d.observe(obs("Chrome|Bundesliga", duration: 7200, elapsed: 7195, at: 100))
    d.observe(obs("Chrome|Bundesliga", duration: 7230, elapsed: 7225, at: 130))
    check("growing duration is live", d.liveReason(for: obs("Chrome|Bundesliga", duration: 7230, elapsed: 7225, at: 130)), .growingDuration)
    d.observe(obs("Spotify|Song", duration: 215, elapsed: 3, at: 140))
    check("next item with fixed duration is paused again", d.liveReason(for: obs("Spotify|Song", duration: 215, elapsed: 3, at: 140)), nil)
}

// Metadata that arrives late is not a live window.
do {
    var d = LiveMediaDetector()
    d.observe(obs("Safari|Video", duration: 30, elapsed: 1, at: 100))
    d.observe(obs("Safari|Video", duration: 600, elapsed: 2, at: 101))
    check("duration jump larger than the time passed is paused", d.liveReason(for: obs("Safari|Video", duration: 600, elapsed: 2, at: 101)), nil)
    d.observe(obs("Safari|Other", duration: 0, elapsed: 0, at: 102))
    d.observe(obs("Safari|Other", duration: 900, elapsed: 0, at: 200))
    check("duration appearing after zero is paused", d.liveReason(for: obs("Safari|Other", duration: 900, elapsed: 0, at: 200)), nil)
}

// Small jitter and a different item with the same growth are not live.
do {
    var d = LiveMediaDetector()
    d.observe(obs("Music|Song", duration: 215.0, elapsed: 10, at: 100))
    d.observe(obs("Music|Song", duration: 215.8, elapsed: 20, at: 110))
    check("duration jitter under two seconds is paused", d.liveReason(for: obs("Music|Song", duration: 215.8, elapsed: 20, at: 110)), nil)
    d.observe(obs("Chrome|A", duration: 100, elapsed: 10, at: 120))
    d.observe(obs("Chrome|B", duration: 130, elapsed: 10, at: 150))
    check("growth across two items is paused", d.liveReason(for: obs("Chrome|B", duration: 130, elapsed: 10, at: 150)), nil)
}

print(failures == 0 ? "All live media scenarios passed" : "\(failures) live media scenario(s) FAILED")
exit(failures == 0 ? 0 : 1)
