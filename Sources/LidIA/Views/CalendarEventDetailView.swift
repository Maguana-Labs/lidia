import SwiftUI
import SwiftData

struct CalendarEventDetailView: View {
    let event: AgendaEvent
    /// Starts recording with the typed notes; `join` opens the call link first.
    let onRecord: (_ notes: String, _ join: Bool) -> Void
    var onBack: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(RecordingSession.self) private var session
    @State private var notes = ""
    @State private var prepContext = ""
    /// Observed directly (not cached in state): an item deleted elsewhere (MCP inbox,
    /// voice assistant, sync) leaves this query before the section can read it.
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted }) private var openActionItems: [ActionItem]
    @State private var showAttendeesPopover = false

    private let relationshipStore = RelationshipStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                countdown
                chips
                if !pendingItems.isEmpty {
                    pendingActionItemsSection
                }
                if !prepContext.isEmpty {
                    prepSection
                }
                notesSection
                actionButtons
            }
            .padding(32)
            .frame(maxWidth: 700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            prepContext = relationshipStore.prepContext(for: event.attendees, modelContext: modelContext)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Today", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text(event.title)
                .font(.largeTitle)
                .fontWeight(.bold)
        }
    }

    // MARK: - Countdown

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let interval = event.start.timeIntervalSince(now)
            let endInterval = event.end.timeIntervalSince(now)

            if endInterval <= 0 {
                // Already ended — don't show
                EmptyView()
            } else {
                Text(countdownText(interval: interval))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(countdownColor(interval: interval).opacity(0.15), in: Capsule())
                    .foregroundStyle(countdownColor(interval: interval))
            }
        }
    }

    private func countdownText(interval: TimeInterval) -> String {
        if interval <= 0 {
            let ago = -interval
            if ago < 60 {
                return "Starting now"
            }
            let minutes = Int(ago / 60)
            if minutes < 60 {
                return "Started \(minutes) min ago"
            }
            let hours = minutes / 60
            return "Started \(hours)h \(minutes % 60)m ago"
        }
        let minutes = Int(interval / 60)
        if minutes < 1 {
            return "Starting now"
        } else if minutes < 60 {
            return "In \(minutes) min"
        } else {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return "In \(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "In \(hours)h \(remainingMinutes)m"
        }
    }

    private func countdownColor(interval: TimeInterval) -> Color {
        if interval <= 0 {
            return .green
        } else if interval <= 15 * 60 {
            return .orange
        } else {
            return .secondary
        }
    }

    // MARK: - Chips

    private var chips: some View {
        HStack(spacing: 8) {
            Label(dateChipLabel, systemImage: "calendar")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: Capsule())

            Label(timeRangeLabel, systemImage: "clock")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: Capsule())

            if !event.attendees.isEmpty {
                Button {
                    showAttendeesPopover.toggle()
                } label: {
                    Label(attendeeChipLabel, systemImage: "person.2")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(event.attendees.count) attendee\(event.attendees.count == 1 ? "" : "s")")
                .accessibilityHint("Shows the attendee list")
                .popover(isPresented: $showAttendeesPopover) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(event.attendees, id: \.self) { attendee in
                            HStack(spacing: 8) {
                                Image(systemName: "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(attendee)
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var dateChipLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.start) {
            return "Today"
        } else if calendar.isDateInTomorrow(event.start) {
            return "Tomorrow"
        } else {
            return event.start.formatted(.dateTime.weekday(.wide))
        }
    }

    private var timeRangeLabel: String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private var attendeeChipLabel: String {
        let first = event.attendees[0]
        if event.attendees.count == 1 {
            return first
        }
        return "\(first) + \(event.attendees.count - 1) more"
    }

    // MARK: - Pending Action Items with Attendees

    private var pendingActionItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pending with attendees", systemImage: "checklist")
                .font(.headline)

            ForEach(pendingItems, id: \.item.id) { entry in
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.title)
                            .font(.callout)
                        HStack(spacing: 4) {
                            if let assignee = entry.item.assignee {
                                Text(assignee)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("from \(entry.meetingTitle)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var pendingItems: [(item: ActionItem, meetingTitle: String)] {
        let lowercasedAttendees = event.attendees.map { $0.lowercased() }
        return openActionItems.compactMap { item in
            guard let assignee = item.assignee?.lowercased(), !assignee.isEmpty else { return nil }
            let matches = lowercasedAttendees.contains { attendee in
                attendee.contains(assignee) || assignee.contains(attendee)
            }
            guard matches else { return nil }
            let meetingTitle = item.meeting?.title ?? "Unknown"
            return (item: item, meetingTitle: meetingTitle)
        }
    }

    // MARK: - Prep Section

    private var prepSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Meeting Prep", systemImage: "lightbulb")
                .font(.headline)

            Text(LocalizedStringKey(prepContext))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Notes", systemImage: "note.text")
                .font(.headline)

            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 120)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if session.isRecording {
                Label("Another recording is in progress", systemImage: "record.circle")
                    .foregroundStyle(.secondary)
            } else {
                if event.meetingLink != nil {
                    Button {
                        onRecord(notes, true)
                    } label: {
                        Label("Join & Record", systemImage: "video.fill")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.glassProminent)
                    .help("Open the call and start recording")
                }

                Button {
                    onRecord(notes, false)
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.glass)
                .help("Start recording this meeting")
            }
        }
    }
}
