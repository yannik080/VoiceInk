import AppKit
import SwiftUI

// The glass mini recorder (design charter, variant B "Minimal": dot plus wave).
// Rebuilt on 04.11.2026 from the charter tokens after the original source was lost.

// MARK: - Tokens

/// Tint of the dark glass. The bar and the live text stay as light as their white content
/// allows over a white document; the brighter chat bubbles of the assistant need more.
enum RecorderGlassTint {
    static let bar: Double = 0.38
    static let assistant: Double = 0.66
}

enum RecorderGlassMetrics {
    static let barHeight: CGFloat = 34
    /// Half the bar height, with circular corners: a continuous 17-pt corner looks tighter
    /// than the capsule ends.
    static let cornerRadius: CGFloat = 17
    static let compactWidth: CGFloat = 118
    static let liveTextWidth: CGFloat = 300
    static let assistantWidth: CGFloat = 520
    static let hitArea: CGFloat = 28
    static let roundButtonSize: CGFloat = 21

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
    }
}

enum RecorderGlassColors {
    static let recording = AppTheme.Status.error
    /// Pure system red reaches only 2.8:1 on white; red that sits on white is darkened by a quarter.
    static let recordingOnWhite = AppTheme.Status.error.mix(with: .black, by: 0.25)
}

// MARK: - Glass Surface

/// Dark tinted Liquid Glass with a light edge. On macOS 26 only `.clear` glass carries the tint
/// over a light background; earlier systems fall back to the HUD material with the same tint.
struct RecorderGlassSurface: ViewModifier {
    let tint: Double

    func body(content: Content) -> some View {
        content
            .background { fallbackBackground }
            .modifier(GlassLayer(tint: tint))
            .overlay {
                RecorderGlassMetrics.shape
                    .strokeBorder(Self.lightEdge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RecorderGlassMetrics.shape)
    }

    /// White 55 % at the top, 8 % in the middle, 22 % at the bottom.
    static let lightEdge = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.55), location: 0),
            .init(color: .white.opacity(0.08), location: 0.5),
            .init(color: .white.opacity(0.22), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    @ViewBuilder
    private var fallbackBackground: some View {
        if #available(macOS 26.0, *) {
            EmptyView()
        } else {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(tint)
            }
        }
    }

    private struct GlassLayer: ViewModifier {
        let tint: Double

        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(.clear.tint(.black.opacity(tint)), in: RecorderGlassMetrics.shape)
            } else {
                content
            }
        }
    }
}

extension View {
    func recorderGlass(tint: Double) -> some View {
        modifier(RecorderGlassSurface(tint: tint))
    }
}

// MARK: - Voice Waveform

enum VoiceWaveformActivity: Equatable {
    /// Ready or starting: flat round dots.
    case resting
    /// Recording: the bars follow the voice.
    case listening
    /// Transcribing: a shimmer runs over the dots.
    case transcribing
    /// Enhancing or the assistant thinking: a breathing lens.
    case enhancing

    init(_ state: RecordingState) {
        switch state {
        case .idle, .starting, .busy: self = .resting
        case .recording: self = .listening
        case .transcribing: self = .transcribing
        case .enhancing: self = .enhancing
        }
    }
}

/// Round bars under a narrow, lens shaped envelope: at a loud voice the middle fills about two
/// thirds of the bar, the outer bars stay at about a fifth of the middle.
struct VoiceWaveform: View {
    let activity: VoiceWaveformActivity
    let audioMeterProvider: () -> AudioMeter

    var barCount = 13
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2.5
    var minHeight: CGFloat = 3
    var maxHeight: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = WaveLevelSmoother()

    static let shimmerPeriod: Double = 1.05
    static let breathPeriod: Double = 1.6

    var body: some View {
        Group {
            if activity == .resting {
                bars(heights: Array(repeating: minHeight, count: barCount), opacities: Array(repeating: 0.55, count: barCount))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let frame = frame(at: context.date)
                    bars(heights: frame.heights, opacities: frame.opacities)
                }
            }
        }
        .frame(height: maxHeight)
        .accessibilityHidden(true)
    }

    private func bars(heights: [CGFloat], opacities: [Double]) -> some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .circular)
                    .fill(Color.white.opacity(opacities[index]))
                    .frame(width: barWidth, height: heights[index])
            }
        }
    }

    private struct Frame {
        var heights: [CGFloat]
        var opacities: [Double]
    }

    private func frame(at date: Date) -> Frame {
        let time = date.timeIntervalSinceReferenceDate
        switch activity {
        case .resting:
            return Frame(heights: Array(repeating: minHeight, count: barCount), opacities: Array(repeating: 0.55, count: barCount))

        case .listening:
            let rawLevel = audioMeterProvider().averagePower
            let level = smoother.update(target: Self.visibleLevel(rawLevel), at: time)
            let heights = (0..<barCount).map { index -> CGFloat in
                // The bars oscillate around the level by ±7 %; Reduce Motion drops the ripple.
                let ripple = reduceMotion ? 1.0 : 1.0 + 0.07 * sin(time * 9 + Double(index) * 0.9)
                let amount = level * Self.envelope(index: index, count: barCount) * ripple
                return min(maxHeight, minHeight + CGFloat(max(0, amount)) * (maxHeight - minHeight))
            }
            return Frame(heights: heights, opacities: Array(repeating: 0.92, count: barCount))

        case .transcribing:
            let heights = Array(repeating: minHeight, count: barCount)
            if reduceMotion {
                let pulse = 0.5 - 0.5 * cos(2 * .pi * time / Self.shimmerPeriod)
                return Frame(heights: heights, opacities: Array(repeating: 0.4 + 0.4 * pulse, count: barCount))
            }
            let progress = (time / Self.shimmerPeriod).truncatingRemainder(dividingBy: 1)
            let position = -0.3 + 1.6 * progress
            let opacities = (0..<barCount).map { index -> Double in
                let x = Double(index) / Double(max(1, barCount - 1))
                let highlight = max(0, 1 - abs(x - position) / 0.22)
                return 0.35 + 0.57 * highlight
            }
            return Frame(heights: heights, opacities: opacities)

        case .enhancing:
            let breath = 0.5 - 0.5 * cos(2 * .pi * time / Self.breathPeriod)
            if reduceMotion {
                let heights = (0..<barCount).map { index in
                    minHeight + CGFloat(0.3 * Self.envelope(index: index, count: barCount)) * (maxHeight - minHeight)
                }
                return Frame(heights: heights, opacities: Array(repeating: 0.5 + 0.4 * breath, count: barCount))
            }
            let amount = 0.18 + 0.2 * breath
            let heights = (0..<barCount).map { index in
                minHeight + CGFloat(amount * Self.envelope(index: index, count: barCount)) * (maxHeight - minHeight)
            }
            return Frame(heights: heights, opacities: Array(repeating: 0.85, count: barCount))
        }
    }

    /// The same level curve as the original visualizer, boosted for visibility.
    static func visibleLevel(_ averagePower: Double) -> Double {
        guard averagePower.isFinite else { return 0 }
        return max(0, min(1, pow(max(0, averagePower), 0.7)))
    }

    /// Narrow lens: 1 in the middle, a fifth at the outer bars.
    static func envelope(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let half = Double(count - 1) / 2
        let x = (Double(index) - half) / half
        return 0.2 + 0.8 * (1 - x * x)
    }
}

/// Follows the meter (about 20 Hz) per frame with a 50 ms time constant, so the wave moves
/// smoothly between level updates.
final class WaveLevelSmoother {
    static let timeConstant: Double = 0.05

    private(set) var value: Double = 0
    private var lastTime: Double?

    func update(target: Double, at time: Double) -> Double {
        defer { lastTime = time }
        guard let lastTime, time > lastTime else {
            if self.lastTime == nil { value = target }
            return value
        }
        let alpha = 1 - exp(-(time - lastTime) / Self.timeConstant)
        value += (target - value) * alpha
        return value
    }
}

// MARK: - Live Dot Button

/// The start/stop control on the leading end of the bar. Red only while recording; under the
/// pointer it becomes a white disc that shows what a click does (start dot or stop square).
struct RecorderLiveDotButton: View {
    let recordingState: RecordingState
    var isAssistantThinking = false
    let action: () -> Void

    @State private var isHovering = false

    private enum Face: Equatable {
        case ready, starting, recording, transcribing, enhancing, busy
    }

    private var face: Face {
        switch recordingState {
        case .idle: return isAssistantThinking ? .enhancing : .ready
        case .starting: return .starting
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .enhancing: return .enhancing
        case .busy: return .busy
        }
    }

    private var isDisabled: Bool {
        face != .ready && face != .recording
    }

    private var showsHoverDisc: Bool {
        isHovering && !isDisabled
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if showsHoverDisc {
                    hoverDisc.transition(.opacity)
                } else {
                    mark.transition(.opacity)
                }
            }
            .frame(width: RecorderGlassMetrics.hitArea, height: RecorderGlassMetrics.hitArea)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: face)
            .animation(.easeOut(duration: 0.1), value: showsHoverDisc)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var mark: some View {
        switch face {
        case .ready:
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: 9, height: 9)
        case .starting:
            Circle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 9, height: 9)
        case .recording:
            Circle()
                .fill(RecorderGlassColors.recordingOnWhite)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .frame(width: 11, height: 11)
        case .busy:
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
                .frame(width: 9, height: 9)
        case .transcribing:
            RecorderGlassSpinner()
        case .enhancing:
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
        }
    }

    private var hoverDisc: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.88))
                .frame(width: RecorderGlassMetrics.roundButtonSize, height: RecorderGlassMetrics.roundButtonSize)
            if face == .recording {
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(RecorderGlassColors.recordingOnWhite)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(RecorderGlassColors.recordingOnWhite)
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var accessibilityLabel: String {
        switch face {
        case .ready: return String(localized: "Start recording")
        case .starting: return String(localized: "Starting recording")
        case .recording: return String(localized: "Stop recording")
        case .transcribing: return String(localized: "Transcribing recording")
        case .enhancing:
            return isAssistantThinking ? String(localized: "Thinking") : String(localized: "Enhancing recording")
        case .busy: return String(localized: "Recorder unavailable")
        }
    }
}

/// White arc spinner in place of the dot while transcribing. The AppKit spinner draws grey and
/// disappears on the tinted glass. Reduce Motion: no rotation, only brightness.
struct RecorderGlassSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            if reduceMotion {
                Circle()
                    .strokeBorder(Color.white.opacity(0.45 + 0.4 * (0.5 - 0.5 * cos(2 * .pi * time / 1.05))), lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            } else {
                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(Color.white.opacity(0.86), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees((time.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360))
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Round Buttons

/// 21-pt disc for close, copy and send. Active (send): white 88 % with a dark symbol.
struct RecorderRoundButton: View {
    let systemName: String
    let label: String
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.white.opacity(0.88) : Color.white.opacity(0.13))
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(isActive ? 0 : 0.18), lineWidth: 0.6)
                    )
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black.opacity(0.82) : Color.white.opacity(0.86))
            }
            .frame(width: RecorderGlassMetrics.roundButtonSize, height: RecorderGlassMetrics.roundButtonSize)
            .opacity(isEnabled ? 1 : 0.5)
            .frame(width: RecorderGlassMetrics.hitArea, height: RecorderGlassMetrics.hitArea)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Copy as a round button that confirms with a checkmark.
struct RecorderCopyButton: View {
    let text: String
    let label: String

    @State private var copied = false

    var body: some View {
        RecorderRoundButton(systemName: copied ? "checkmark" : "doc.on.doc", label: label) {
            _ = ClipboardManager.copyToClipboard(text)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.12)) { copied = false }
            }
        }
    }
}

// MARK: - Glass Live Text

/// The live transcript above the bar, in the same glass. Its height follows the text up to four
/// lines, then it scrolls and keeps the newest words in view.
struct RecorderGlassLiveText: View {
    let text: String

    static let maxHeight: CGFloat = 68

    @State private var textHeight: CGFloat = 0

    private var isScrolling: Bool {
        textHeight > Self.maxHeight
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                label
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                    .id("bottom")
            }
            .scrollDisabled(!isScrolling)
            .frame(height: min(max(textHeight, 1), Self.maxHeight))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: isScrolling ? .clear : .black, location: 0),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: textHeight) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .transaction { $0.disablesAnimations = true }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}
