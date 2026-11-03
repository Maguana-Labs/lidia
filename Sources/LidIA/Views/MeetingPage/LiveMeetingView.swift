import SwiftUI

/// Live mode, as calm as Granola's: the title, one row of chips (Notes, Transcript with a
/// live meter, the timer and Stop; Pause in a menu), at most one plain-sentence notice
/// with a fix button, then your notes and the transcript, side by side when the window
/// is wide and switchable when it isn't. Ask is docked at the bottom by the page.
struct LiveMeetingView: View {
    @Bindable var meeting: Meeting
    var notesFocused: FocusState<Bool>.Binding
    /// Space the page's docked Ask field takes at the bottom.
    var bottomInset: CGFloat = 72

    @Environment(RecordingSession.self) private var session
    @Environment(AppSettings.self) private var settings

    /// Which pane shows when there's room for only one.
    @AppStorage("livePage.narrowPane") private var narrowPane: LivePane = .transcript
    /// Whether the transcript shows next to the notes when there's room for both.
    @AppStorage("livePage.transcriptBesideNotes") private var transcriptBesideNotes = true

    /// Window width from which notes and transcript sit side by side.
    static let splitWidth: CGFloat = 900

    var body: some View {
        GeometryReader { geometry in
            let split = geometry.size.width >= Self.splitWidth
            VStack(spacing: 0) {
                LiveHeader(
                    meeting: meeting,
                    split: split,
                    narrowPane: $narrowPane,
                    transcriptBesideNotes: $transcriptBesideNotes
                )
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 10)

                if NoteTranscriptionState.shared.startedFromNote.contains(meeting.id) {
                    NoteTranscribeChip(isLive: true, onStart: {}, onStop: { stopFromChip() })
                        .padding(.horizontal, 28)
                        .padding(.bottom, 6)
                }

                LiveNoticeRow()
                    .padding(.horizontal, 28)

                content(split: split)
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(EventKitManager.self) private var eventKitManager

    private func stopFromChip() {
        session.stopRecording(modelContext: modelContext, settings: settings, eventKitManager: eventKitManager)
    }

    @ViewBuilder
    private func content(split: Bool) -> some View {
        if split {
            HStack(spacing: 0) {
                notesPane
                    .frame(minWidth: 320, maxWidth: .infinity)
                if transcriptBesideNotes {
                    Divider()
                    transcriptPane
                        .frame(minWidth: 320, idealWidth: 420, maxWidth: 480)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.2), value: transcriptBesideNotes)
        } else {
            switch narrowPane {
            case .notes: notesPane
            case .transcript: transcriptPane
            }
        }
    }

    private var notesPane: some View {
        MeetingNotesEditor(
            text: $meeting.notes,
            placeholder: "Write notes as you go. LidIA merges them into the AI notes.",
            isFocused: notesFocused
        )
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var transcriptPane: some View {
        LiveTranscriptView(
            words: session.transcriptWords,
            localSpeakerName: "You",
            bottomInset: bottomInset
        )
    }
}

/// "Transcribing · Stop" on a note that started transcribing by itself, or
/// a one-tap "Start transcribing" on a new note.
struct NoteTranscribeChip: View {
    var isLive: Bool
    var onStart: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isLive {
                Circle().fill(.red).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("Transcribing")
                    .font(.callout.weight(.medium))
                Text("·").foregroundStyle(.tertiary)
                Button("Stop", action: onStop)
                    .buttonStyle(.link)
                    .font(.callout.weight(.medium))
                    .help("Stop transcribing this note. Your notes stay.")
            } else {
                Button(action: onStart) {
                    Label("Start transcribing", systemImage: "waveform")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.glass)
                .help("Transcribe this note with the microphone (and the call's audio)")
            }
        }
        .padding(.horizontal, isLive ? 12 : 0)
        .padding(.vertical, isLive ? 6 : 0)
        .background {
            if isLive { Capsule().fill(Color.red.opacity(0.08)) }
        }
        .accessibilityElement(children: .combine)
    }
}

enum LivePane: String {
    case notes
    case transcript
}

// MARK: - Header

/// Title, then Notes / Transcript chips on the left and the timer, Stop and a menu with
/// Pause on the right.
private struct LiveHeader: View {
    @Bindable var meeting: Meeting
    var split: Bool
    @Binding var narrowPane: LivePane
    @Binding var transcriptBesideNotes: Bool

    @Environment(RecordingSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(\.modelContext) private var modelContext
    @FocusedValue(\.appActions) private var appActions
    @FocusState private var titleFocused: Bool
    @State private var isConfirmingStop = false

    var body: some View {
        VStack(spacing: 14) {
            TextField("Untitled Meeting", text: $meeting.title, axis: .vertical)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .lineLimit(1...2)
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Meeting title")
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                if !split {
                    chip("Notes", systemImage: "pencil.line", isOn: narrowPane == .notes) { narrowPane = .notes }
                        .help("Show your notes")
                }
                transcriptChip
                Spacer(minLength: 12)
                timer
                stopButton
                moreMenu
            }
        }
        .stopRecordingConfirmation(isPresented: $isConfirmingStop) {
            session.stopRecording(modelContext: modelContext, settings: settings, eventKitManager: eventKitManager)
        }
    }

    private var transcriptIsOn: Bool {
        split ? transcriptBesideNotes : narrowPane == .transcript
    }

    private var transcriptChip: some View {
        Button {
            if split { transcriptBesideNotes.toggle() } else { narrowPane = .transcript }
        } label: {
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    LiveMeterBars(level: LiveAudioLevels.from(session: session).mic, isPaused: session.isPaused)
                }
                .frame(width: 16, height: 14)
                Text("Transcript")
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .buttonStyle(MeetingChipButtonStyle(isOn: transcriptIsOn))
        .help(split ? (transcriptBesideNotes ? "Hide the transcript" : "Show the transcript") : "Show the live transcript")
        .accessibilityLabel(transcriptIsOn ? "Transcript, shown" : "Show transcript")
    }

    private func chip(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(.capsule)
        }
        .buttonStyle(MeetingChipButtonStyle(isOn: isOn))
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isPaused ? Color.orange : Brand.red)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(session.isPaused ? "Paused" : RecordingInlineView.formatTime(session.elapsedTime))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(session.isPaused ? Color.orange : Color.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.isPaused ? "Recording paused" : "Recording, \(RecordingInlineView.formatTime(session.elapsedTime))")
        }
    }

    private var stopButton: some View {
        Button {
            if let appActions, appActions.isRecording {
                appActions.toggleRecording()
            } else {
                isConfirmingStop = true
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Brand.red)
        .controlSize(.small)
        .help("Stop recording and write the notes (⌘R)")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                if session.isPaused { session.resumeRecording() } else { session.pauseRecording() }
            } label: {
                Label(session.isPaused ? "Resume Recording" : "Pause Recording",
                      systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(MeetingChipButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pause and more")
        .accessibilityLabel("Recording options")
    }
}

/// The small green bars in the Transcript chip.
struct LiveMeterBars: View {
    var level: Float
    var isPaused: Bool

    private static let weights: [CGFloat] = [0.6, 1, 0.75]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(isPaused ? Color.secondary.opacity(0.5) : Color.green)
                    .frame(width: 3, height: height(index))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }

    private func height(_ index: Int) -> CGFloat {
        guard !isPaused else { return 3 }
        let value = min(1, CGFloat(level) * Self.weights[index] * 1.6)
        return 3 + 10 * value
    }
}

// MARK: - Notice

/// At most one sentence about the recording, with the button that fixes it.
private struct LiveNoticeRow: View {
    @Environment(RecordingSession.self) private var session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let notice = currentNotice {
                LiveNoticeView(notice: notice) { perform($0) }
                    .padding(.bottom, 8)
            }
        }
    }

    private var currentNotice: LiveNotice? {
        LiveNotice.current(
            isPaused: session.isPaused,
            autoStopSeconds: session.autoStopCountdown,
            autoStopReason: session.autoStopReason,
            quality: session.audioQualityState,
            systemAudioMissing: session.systemAudioFallbackReason != nil,
            liveTranscriptNotice: session.liveTranscriptNotice,
            captureMessage: session.captureStatusMessage
        )
    }

    private func perform(_ action: LiveNotice.Action) {
        switch action {
        case .keepRecording:
            session.cancelAutoStop()
        default:
            if let url = LiveNotice.settingsURL(for: action) { NSWorkspace.shared.open(url) }
        }
    }
}

struct LiveNoticeView: View {
    let notice: LiveNotice
    var perform: (LiveNotice.Action) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Text(notice.text)
                .font(.callout)
                .foregroundStyle(notice.needsAttention ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action, let title = notice.actionTitle {
                Button(title) { perform(action) }
                    .buttonStyle(.accentLink)
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Plain multi-line notes editor with a placeholder.
struct MeetingNotesEditor: View {
    @Binding var text: String
    var placeholder: String = "Write your notes…"
    var isFocused: FocusState<Bool>.Binding
    var minHeight: CGFloat? = nil
    /// When true the editor grows with its text (for use inside a ScrollView)
    /// instead of scrolling internally.
    var growsWithContent = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if growsWithContent {
                // Invisible copy of the text sizes the ZStack; the editor fills it.
                Text(text.isEmpty ? " " : text + "\n")
                    .font(.body)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused(isFocused)
                .frame(minHeight: minHeight)
                .accessibilityLabel("Your notes")

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
