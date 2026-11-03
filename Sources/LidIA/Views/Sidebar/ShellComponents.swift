import SwiftUI
import SwiftData

// MARK: - Agenda source

/// Builds the merged Apple + Google agenda from the two calendar managers.
@MainActor
enum AgendaSource {
    static func events(
        eventKitManager: EventKitManager,
        googleCalendarMonitor: GoogleCalendarMonitor
    ) -> [AgendaEvent] {
        let google = googleCalendarMonitor.isSignedIn
            ? googleCalendarMonitor.upcomingEvents + googleCalendarMonitor.weekEvents
            : []
        return UnifiedCalendar.merge(apple: eventKitManager.upcomingEvents, google: google)
    }
}

// MARK: - Starting things

extension RecordingSession {
    /// Starts recording a calendar event from either calendar. Opens the call
    /// link first when `join` is true.
    @discardableResult
    func startRecording(
        from event: AgendaEvent,
        join: Bool = false,
        notes: String = "",
        modelContext: ModelContext,
        settings: AppSettings,
        modelManager: ModelManager? = nil,
        meetingDetector: MeetingDetector? = nil
    ) -> Meeting {
        if join, let link = event.meetingLink {
            NSWorkspace.shared.open(link)
        }
        let calendarEvent = GoogleCalendarClient.CalendarEvent(
            id: event.calendarEventID,
            title: event.title,
            start: event.start,
            end: event.end,
            attendees: event.attendees,
            meetingLink: event.meetingLink,
            colorHex: event.colorHex
        )
        return startRecordingFromGoogleEvent(
            calendarEvent,
            notes: notes,
            modelContext: modelContext,
            settings: settings,
            modelManager: modelManager,
            meetingDetector: meetingDetector
        )
    }
}

/// Creates text-only notes. A note never touches the microphone; recording
/// is a separate action.
@MainActor
enum NoteFactory {
    static let defaultTitle = "New Note"

    @discardableResult
    static func makeNote(in context: ModelContext, title: String = defaultTitle) -> Meeting {
        let meeting = Meeting(title: title, date: .now, status: .complete)
        context.insert(meeting)
        try? context.save()
        return meeting
    }
}

extension Notification.Name {
    /// Posted (e.g. from the menu bar) to create a text note in the main window.
    static let lidiaCreateNote = Notification.Name("lidia.createNote")
}

// MARK: - Status badge

struct MeetingStatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        if let badge = MeetingListModel.badge(for: status) {
            Label(badge.label, systemImage: badge.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: badge.tone))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(for: badge.tone).opacity(0.14), in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status: \(badge.label)")
        }
    }

    private func color(for tone: MeetingListModel.Badge.Tone) -> Color {
        switch tone {
        case .live: Brand.red
        case .progress: .secondary
        case .waiting: .orange
        case .failure: .red
        }
    }
}

// MARK: - Agenda event row

/// One calendar event with its Record (or Join & Record) action always visible.
struct AgendaEventRow: View {
    let event: AgendaEvent
    var isRecording: Bool = false
    var compact: Bool = false
    var onOpen: (() -> Void)?
    var onRecord: (_ join: Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.fromHex(event.colorHex) ?? .accentColor)
                .frame(width: 4)
                .frame(maxHeight: compact ? 28 : 34)
                .accessibilityHidden(true)

            Button {
                onOpen?()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(compact ? .subheadline : .body)
                        .lineLimit(1)
                    Text(timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .accessibilityLabel("\(event.title), \(timeText)")
            .accessibilityHint(onOpen == nil ? "" : "Opens the event")

            if !isRecording && !event.isAllDay {
                if event.meetingLink != nil {
                    Button {
                        onRecord(true)
                    } label: {
                        Label(compact ? "Join" : "Join & Record", systemImage: "video.fill")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Open the call and start recording")
                    .accessibilityLabel("Join and record \(event.title)")
                }
                Button {
                    onRecord(false)
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Record this meeting")
                .accessibilityLabel("Record \(event.title)")
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(event.start)
            ? ""
            : event.start.formatted(.dateTime.weekday(.abbreviated)) + " "
        return "\(day)\(start) – \(end)"
    }
}

// MARK: - Elapsed time

enum ElapsedFormat {
    static func string(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
