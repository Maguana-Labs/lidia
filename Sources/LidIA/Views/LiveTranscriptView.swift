import SwiftUI

/// The live transcript as Granola shows it: one paragraph bubble per run of a speaker with
/// a timestamp, the current guess refining in place (lighter) at the end, and "…" while
/// someone speaks before words appear. Final text only grows at the end, so nothing jumps.
struct LiveTranscriptView: View {
    let words: [TranscriptWord]
    var localSpeakerName: String = "You"
    /// Room left at the bottom for the page's docked Ask field.
    var bottomInset: CGFloat = 16

    @Environment(RecordingSession.self) private var session

    @State private var pinnedToBottom = true
    @State private var showJumpButton = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let bubbles = LiveTranscriptBubbles.bubbles(
                words: words,
                volatile: session.liveVolatile,
                speaking: session.speakingSources(),
                now: session.elapsedTime
            )
            content(bubbles, phase: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(_ bubbles: [LiveBubble], phase: TimeInterval) -> some View {
        if bubbles.isEmpty {
            ContentUnavailableView {
                Label(session.isPaused ? "Paused" : "Listening…", systemImage: "waveform")
            } description: {
                Text(session.isPaused ? "The transcript continues when you resume." : "The transcript appears here as people speak.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomInset)
        } else {
            LiveBubbleList(
                bubbles: bubbles,
                localName: localSpeakerName,
                phase: phase,
                bottomInset: bottomInset,
                pinnedToBottom: $pinnedToBottom,
                showJumpButton: $showJumpButton
            )
        }
    }
}

/// The scrolling list; follows the newest text while you're at the bottom.
struct LiveBubbleList: View {
    let bubbles: [LiveBubble]
    let localName: String
    var phase: TimeInterval = 0
    var bottomInset: CGFloat = 16
    @Binding var pinnedToBottom: Bool
    @Binding var showJumpButton: Bool

    /// Changes whenever something visible at the end changes.
    private var tailToken: String {
        guard let last = bubbles.last else { return "" }
        return "\(bubbles.count)-\(last.text.count)-\(last.volatileText.count)-\(last.isTyping)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(bubbles) { bubble in
                            LiveBubbleView(bubble: bubble, localName: localName, phase: phase)
                                .id(bubble.id)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, bottomInset)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let maxOffset = max(0, geo.contentSize.height - geo.containerSize.height)
                    return (maxOffset - geo.contentOffset.y) < 48
                } action: { _, isPinned in
                    pinnedToBottom = isPinned
                    if isPinned { showJumpButton = false }
                }
                .onChange(of: tailToken) {
                    guard pinnedToBottom else {
                        showJumpButton = true
                        return
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo("live-bottom", anchor: .bottom) }

                if showJumpButton {
                    Button {
                        withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) }
                        showJumpButton = false
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.glass)
                    .padding(.trailing, 14)
                    .padding(.bottom, bottomInset + 6)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showJumpButton)
        }
    }
}

/// One speaker's paragraph: "You · 0:41" above, the text in a soft bubble.
struct LiveBubbleView: View {
    let bubble: LiveBubble
    let localName: String
    var phase: TimeInterval = 0

    var body: some View {
        VStack(alignment: bubble.isLocal ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(bubble.label(localName: localName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(bubble.isLocal ? Color.accentColor : Color.secondary)
                Text(TranscriptSegmenter.formatTimestamp(bubble.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            bubbleText
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    bubble.isLocal ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .frame(maxWidth: .infinity, alignment: bubble.isLocal ? .trailing : .leading)
        .padding(bubble.isLocal ? .leading : .trailing, 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bubble.label(localName: localName)), \(TranscriptSegmenter.formatTimestamp(bubble.start)): \(bubble.text) \(bubble.volatileText)")
    }

    /// Final text, then the guess (lighter), then the typing dots.
    private var bubbleText: Text {
        var text = Text(bubble.text)
        if !bubble.volatileText.isEmpty {
            text = text + Text((bubble.text.isEmpty ? "" : " ") + bubble.volatileText).foregroundStyle(.secondary)
        }
        if bubble.isTyping {
            let spacer = bubble.text.isEmpty && bubble.volatileText.isEmpty ? "" : " "
            text = text + Text(spacer) + typingDots
        }
        return text
    }

    /// "• • •" pulsing left to right.
    private var typingDots: Text {
        let step = Int(phase * 3) % 3
        return (0..<3).reduce(Text("")) { result, index in
            result + Text(index == 0 ? "●" : " ●")
                .font(.system(size: 7))
                .foregroundStyle(Color.secondary.opacity(index == step ? 0.9 : 0.35))
        }
    }
}
