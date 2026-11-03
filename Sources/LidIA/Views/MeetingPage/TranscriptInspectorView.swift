import SwiftUI

/// Inspector tab: speaker-labelled, searchable transcript with audio playback.
struct TranscriptInspectorView: View {
    let meeting: Meeting
    /// Live words while this meeting is recording (nil otherwise).
    var liveWords: [TranscriptWord]?
    @Bindable var player: TranscriptAudioPlayer
    var onEditTranscript: (() -> Void)?

    @Environment(AppSettings.self) private var settings

    @State private var segments: [TranscriptSegment] = []
    @State private var bubbles: [TranscriptBubble] = []
    @State private var searchText = ""
    @State private var matchCursor = 0
    @State private var followPlayback = true
    @FocusState private var searchFocused: Bool

    private var localName: String {
        settings.displayName.isEmpty ? "Me" : settings.displayName
    }

    private var audioURL: URL? {
        MeetingAudioLocator.url(for: meeting.audioFilePath)
    }

    private var matches: [Int] {
        TranscriptChatModel.matchingIndices(in: bubbles, query: searchText)
    }

    private var effectiveTranscript: String {
        let edited = meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? meeting.refinedTranscript : edited
    }

    var body: some View {
        VStack(spacing: 0) {
            if let liveWords {
                liveTranscript(liveWords)
            } else {
                if meeting.audioFilePath != nil {
                    playerBar
                    Divider()
                }
                if !bubbles.isEmpty {
                    searchBar
                }
                transcriptList
            }
        }
        .onAppear {
            recomputeSegments()
            player.load(url: audioURL)
        }
        .onChange(of: meeting.rawTranscript) { recomputeSegments() }
        .onChange(of: effectiveTranscript) { recomputeSegments() }
        .onChange(of: meeting.audioFilePath) { player.load(url: audioURL) }
        .onChange(of: searchText) { matchCursor = 0 }
    }

    // MARK: - Live

    @ViewBuilder
    private func liveTranscript(_ words: [TranscriptWord]) -> some View {
        // Shows "Listening…" itself until the first words or guess.
        LiveTranscriptView(words: words, localSpeakerName: "You")
    }

    // MARK: - Player

    @ViewBuilder
    private var playerBar: some View {
        if audioURL == nil {
            // Audio never syncs: a meeting recorded on another device keeps its audio there.
            Label(meeting.isOwnedByThisDevice ? "Audio file not found" : "Audio stays on the device that recorded it",
                  systemImage: "speaker.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help(meeting.audioFilePath ?? "")
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                    }
                    .accessibilityLabel("Back 15 seconds")
                    .help("Back 15 seconds")

                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 24)
                    }
                    .keyboardShortcut(.space, modifiers: [.option])
                    .accessibilityLabel(player.isPlaying ? "Pause audio" : "Play audio")
                    .help(player.isPlaying ? "Pause (⌥Space)" : "Play (⌥Space)")

                    Button {
                        player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                    }
                    .accessibilityLabel("Forward 15 seconds")
                    .help("Forward 15 seconds")

                    Spacer(minLength: 4)

                    Text("\(TranscriptSegmenter.formatTimestamp(player.currentTime)) / \(TranscriptSegmenter.formatTimestamp(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Position \(TranscriptSegmenter.formatTimestamp(player.currentTime)) of \(TranscriptSegmenter.formatTimestamp(player.duration))")
                }
                .buttonStyle(.borderless)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0, play: player.isPlaying) }
                    ),
                    in: 0...max(player.duration, 1)
                )
                .controlSize(.mini)
                .accessibilityLabel("Playback position")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in transcript", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { step(1) }
                .accessibilityLabel("Find in transcript")

            if !searchText.isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(matchCursor, matches.count - 1) + 1) of \(matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .accessibilityLabel("Previous match")

                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .accessibilityLabel("Next match")

                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        followPlayback = false
        matchCursor = (matchCursor + delta + matches.count) % matches.count
    }

    // MARK: - List

    @ViewBuilder
    private var transcriptList: some View {
        if bubbles.isEmpty {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "text.quote")
            } description: {
                Text(meeting.status == .processing ? "Transcribing…" : "This meeting has no transcript.")
            }
        } else {
            let activeIndex = (player.isLoaded && !segments.isEmpty)
                ? TranscriptSegmenter.activeIndex(in: segments, at: player.currentTime)
                : nil
            let currentMatch: Int? = matches.isEmpty ? nil : matches[min(matchCursor, matches.count - 1)]
            let matchSet = Set(matches)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                            let previous = index > 0 ? bubbles[index - 1] : nil
                            TranscriptBubbleRow(
                                bubble: bubble,
                                showsSpeaker: bubble.speaker != nil && previous?.speaker != bubble.speaker,
                                isActive: bubble.id == activeIndex,
                                isMatch: matchSet.contains(index),
                                isCurrentMatch: index == currentMatch,
                                canPlay: player.isLoaded && !segments.isEmpty && bubble.start != nil,
                                onTap: {
                                    followPlayback = true
                                    if let start = bubble.start { player.seek(to: start, play: true) }
                                }
                            )
                            .padding(.top, previous == nil ? 4 : (previous?.speaker != bubble.speaker ? 12 : 4))
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .onChange(of: currentMatch) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: activeIndex) { _, target in
                    guard followPlayback, player.isPlaying, let target,
                          let row = bubbles.firstIndex(where: { $0.id == target }) else { return }
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let onEditTranscript {
                    HStack {
                        Text("\(bubbles.count) lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit Transcript…", action: onEditTranscript)
                            .buttonStyle(.accentLink)
                            .font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
                }
            }
        }
    }

    private func recomputeSegments() {
        segments = TranscriptSegmenter.segments(from: meeting.rawTranscript, meetingDuration: meeting.duration)
        if !segments.isEmpty {
            bubbles = TranscriptChatModel.bubbles(from: segments, localName: localName)
        } else {
            let names: Set<String> = settings.displayName.isEmpty ? [] : [settings.displayName]
            bubbles = TranscriptChatModel.bubbles(fromText: effectiveTranscript, localNames: names)
        }
    }
}

/// One transcript line as a chat bubble: you on the right in the accent
/// colour, everyone else on the left in grey, the time in the margin.
/// With audio, clicking a line plays from there.
private struct TranscriptBubbleRow: View {
    let bubble: TranscriptBubble
    let showsSpeaker: Bool
    let isActive: Bool
    let isMatch: Bool
    let isCurrentMatch: Bool
    let canPlay: Bool
    let onTap: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if isCurrentMatch { return .yellow.opacity(0.38) }
        if isMatch { return .yellow.opacity(0.18) }
        return bubble.isLocal ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(bubble.start.map(TranscriptSegmenter.formatTimestamp) ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 34, alignment: .trailing)
                .padding(.top, showsSpeaker ? 22 : 7)
                .opacity(hovering || isActive || showsSpeaker || bubble.speaker == nil ? 1 : 0)
                .accessibilityHidden(true)

            VStack(alignment: bubble.isLocal ? .trailing : .leading, spacing: 3) {
                if showsSpeaker, let speaker = bubble.speaker {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bubble.isLocal ? Color.accentColor : .secondary)
                        .padding(.horizontal, 4)
                }
                Text(bubble.text)
                    .font(.callout)
                    .lineSpacing(1.5)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                        }
                    }
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: bubble.isLocal ? .trailing : .leading)
            .padding(bubble.isLocal ? .leading : .trailing, 28)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if canPlay { onTap() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bubble.speaker.map { "\($0), " } ?? "")\(bubble.start.map(TranscriptSegmenter.formatTimestamp) ?? ""), \(bubble.text)")
        .accessibilityHint(canPlay ? "Double-click to play the recording from here" : "")
        .accessibilityAddTraits(canPlay ? .isButton : [])
        .accessibilityAction { if canPlay { onTap() } }
        .contextMenu {
            if canPlay {
                Button("Play from Here", systemImage: "play") { onTap() }
            }
            Button("Copy Line", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bubble.text, forType: .string)
            }
        }
    }
}
