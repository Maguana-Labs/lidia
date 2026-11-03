import SwiftUI

/// Which notes the meeting page shows: the AI notes (summary merged with
/// yours, plus action items) or only what you typed.
enum MeetingNotesMode: String, CaseIterable, Identifiable {
    case ai
    case mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: "AI Notes"
        case .mine: "My Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .ai: "sparkles"
        case .mine: "pencil.line"
        }
    }
}

/// Meeting page header: a large centered title, then one row of chips —
/// notes view and Transcript on the left, status, participants and date on
/// the right.
struct MeetingHeaderView: View {
    @Bindable var meeting: Meeting
    var isLive: Bool
    var attendees: [MeetingAttendee]
    @Binding var notesMode: MeetingNotesMode
    var hasAINotes: Bool
    var isTranscriptShown: Bool
    /// False while the processing stepper already shows the status.
    var showsStatus = true
    var onToggleTranscript: () -> Void
    @Binding var showsAttendees: Bool

    @FocusState private var titleFocused: Bool

    /// The title is one LidIA wrote and the user hasn't changed.
    private var isAITitle: Bool {
        IntentStore.shared.aiTitle(for: meeting.id)?.title == meeting.title && !meeting.title.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isAITitle {
                    Button {
                        titleFocused = true
                    } label: {
                        Text("✦")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("LidIA wrote this title from your notes. Click to edit it.")
                    .accessibilityLabel("Title written by AI. Edit title")
                }
                TextField("Untitled Meeting", text: $meeting.title, axis: .vertical)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .fixedSize(horizontal: isAITitle, vertical: false)
                    .accessibilityLabel("Meeting title")
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: meeting.title) { _, newTitle in
                // Typed by the user: never retitled again.
                if titleFocused, NoteAutoTitle.isUserEdit(newTitle: newTitle, aiTitle: IntentStore.shared.aiTitle(for: meeting.id)) {
                    IntentStore.shared.markUserTitled(meeting.id)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    leadingChips
                    Spacer(minLength: 12)
                    trailingChips
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { leadingChips }
                    HStack(spacing: 8) { trailingChips }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Leading: view switcher, Transcript

    @ViewBuilder
    private var leadingChips: some View {
        if !isLive {
            notesSwitcher
            Button(action: onToggleTranscript) {
                Label("Transcript", systemImage: "text.quote")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(.capsule)
            }
            .buttonStyle(MeetingChipButtonStyle(isOn: isTranscriptShown))
            .help(isTranscriptShown ? "Hide the transcript (⌘2)" : "Show the transcript (⌘2)")
            .accessibilityLabel(isTranscriptShown ? "Hide transcript" : "Show transcript")
        }
    }

    private var notesSwitcher: some View {
        Menu {
            Picker("Notes", selection: $notesMode) {
                ForEach(MeetingNotesMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                        .selectionDisabled(mode == .ai && !hasAINotes)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if !hasAINotes {
                Text("AI notes appear after the meeting is processed.")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: notesMode.systemImage)
                    .imageScale(.small)
                Text(notesMode.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch between AI notes and your own notes (⌘1, ⌘3)")
        .accessibilityLabel("Notes view: \(notesMode.title)")
    }

    // MARK: - Trailing: status, people, date

    @ViewBuilder
    private var trailingChips: some View {
        if showsStatus {
            MeetingHeaderStatusBadge(status: meeting.status, isLive: isLive)
        }
        if !isLive {
            MeetingProjectChip(meeting: meeting)
        }
        if !attendees.isEmpty {
            AttendeeChip(attendees: attendees, isPresented: $showsAttendees)
        }
        Label(dateText, systemImage: "calendar")
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .help(fullDateText)
            .accessibilityLabel(fullDateText)
    }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(meeting.date) {
            return "Today " + meeting.date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(meeting.date, equalTo: .now, toGranularity: .year) {
            return meeting.date.formatted(.dateTime.month(.abbreviated).day())
        }
        return meeting.date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var fullDateText: String {
        var text = meeting.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
        if let duration = MeetingRowFormat.duration(meeting.duration) { text += " · \(duration)" }
        return text
    }
}

/// "👤 4" participants chip with the grouped popover.
private struct AttendeeChip: View {
    let attendees: [MeetingAttendee]
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                AttendeeAvatarStack(attendees: attendees, maxVisible: 3, size: 18)
                Text(label)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .buttonStyle(MeetingChipButtonStyle())
        .help(attendees.map(\.displayName).joined(separator: ", "))
        .accessibilityLabel("\(attendees.count) participants: \(attendees.map(\.displayName).joined(separator: ", "))")
        .accessibilityHint("Shows everyone with their email")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AttendeeListPopover(attendees: attendees)
        }
    }

    private var label: String {
        let others = attendees.filter { !$0.isCurrentUser }
        if attendees.count <= 2, let other = others.first { return other.name }
        return "\(attendees.count)"
    }
}

/// Status pill next to the date: the sidebar's `MeetingStatusBadge`, except a
/// meeting left in `.recording` that isn't actually recording shows "Interrupted".
struct MeetingHeaderStatusBadge: View {
    let status: MeetingStatus
    var isLive: Bool = false

    var body: some View {
        if status == .recording && !isLive {
            Label("Interrupted", systemImage: "exclamationmark.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.orange.opacity(0.14), in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status: Interrupted")
        } else {
            MeetingStatusBadge(status: status)
        }
    }
}
