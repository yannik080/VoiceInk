import SwiftUI

/// The mini recorder as a capsule of dark tinted Liquid Glass: the live dot on the leading end,
/// the voice wave as the one hero. Live text and the assistant fold out upwards in the same glass.
/// Tokens: `docs/design/charta.md`, brief `docs/design/briefs/2026-11-04-glas-recorder-wiederaufbau.md`.
struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        showLiveTranscript
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var isExpanded: Bool {
        hasLiveTranscript || hasAssistantResponse
    }

    private var isAssistantThinking: Bool {
        hasAssistantResponse && assistantSession.isBusy
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var width: CGFloat {
        if hasAssistantResponse { return RecorderGlassMetrics.assistantWidth }
        if hasLiveTranscript { return RecorderGlassMetrics.liveTextWidth }
        return RecorderGlassMetrics.compactWidth
    }

    private var waveActivity: VoiceWaveformActivity {
        if stateProvider.recordingState == .idle, isAssistantThinking {
            return .enhancing
        }
        return VoiceWaveformActivity(stateProvider.recordingState)
    }

    private var conversationText: String {
        assistantSession.messages.map { message in
            let prefix = message.role == .user ? "You" : "Assistant"
            return "\(prefix): \(message.content)"
        }.joined(separator: "\n\n")
    }

    /// Fold out in 150 ms, fold in faster (60 ms). Reduce Motion: no size animation.
    private var layoutAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return isExpanded ? .easeOut(duration: 0.15) : .easeIn(duration: 0.06)
    }

    /// Text arrives 60 ms after the glass starts to grow and fades in over 80 ms.
    private var textTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.08).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.06))
        )
    }

    /// Dot and wave keep the compact 118-pt bar in every state and stay centred when the glass
    /// grows. The copy button sits just outside the bar, mirroring the close button.
    private var controlBar: some View {
        HStack(spacing: 0) {
            Group {
                if shouldShowCloseButton {
                    RecorderRoundButton(
                        systemName: "xmark",
                        label: String(localized: "Close"),
                        action: onCloseTapped
                    )
                } else {
                    RecorderLiveDotButton(
                        recordingState: stateProvider.recordingState,
                        isAssistantThinking: isAssistantThinking,
                        action: onRecordButtonTapped
                    )
                }
            }
            .frame(width: RecorderGlassMetrics.hitArea, height: RecorderGlassMetrics.hitArea)

            Spacer(minLength: 0)

            VoiceWaveform(
                activity: waveActivity,
                audioMeterProvider: recorder.audioMeterSnapshot
            )

            Spacer(minLength: 0)
        }
        .padding(.leading, RecorderGlassMetrics.barLeadingInset)
        .padding(.trailing, RecorderGlassMetrics.barTrailingInset)
        .frame(width: RecorderGlassMetrics.compactWidth, height: RecorderGlassMetrics.barHeight)
        .overlay(alignment: .trailing) {
            if hasAssistantResponse, !assistantSession.messages.isEmpty {
                RecorderCopyButton(
                    text: conversationText,
                    label: String(localized: "Copy conversation")
                )
                .offset(x: RecorderGlassMetrics.hitArea - RecorderGlassMetrics.barTrailingInset)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(RecorderGlassMetrics.dividerOpacity))
            .frame(height: RecorderGlassMetrics.dividerHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                VStack(spacing: 0) {
                    AssistantPanelView(
                        session: assistantSession,
                        liveFollowUpText: liveAssistantFollowUpText,
                        style: .glass,
                        onSend: onAssistantFollowUp
                    )
                    divider
                }
                .transition(textTransition)
            } else if hasLiveTranscript {
                VStack(spacing: 0) {
                    RecorderGlassLiveText(text: stateProvider.partialTranscript)
                    divider
                }
                .transition(textTransition)
            }
            controlBar
        }
        .frame(width: width)
        .recorderGlass(tint: hasAssistantResponse ? RecorderGlassTint.assistant : RecorderGlassTint.bar)
        .animation(layoutAnimation, value: isExpanded)
        .animation(layoutAnimation, value: width)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.9, anchor: .bottom)
        .onAppear {
            withAnimation(.spring(response: 0.14, dampingFraction: 0.85)) { hasAppeared = true }
        }
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
