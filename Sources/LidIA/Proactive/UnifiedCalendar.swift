import Foundation

/// One calendar event as the app shows it, regardless of whether it came from
/// Apple Calendar (EventKit), Google Calendar, or both.
///
/// Many people subscribe to the same Google calendar in Apple Calendar, so the
/// same meeting arrives twice. `UnifiedCalendar.merge` folds those duplicates
/// into one `AgendaEvent` so the agenda, menu bar and reminders each show or
/// prompt once per meeting.
struct AgendaEvent: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable, Hashable {
        case apple
        case google
    }

    /// Stable key: "google:<id>" when Google knows the event, else "apple:<id>".
    let id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String]
    var meetingLink: URL?
    var colorHex: String?
    var calendarName: String?
    var sources: Set<Source>
    var appleEventID: String?
    var googleEventID: String?

    /// The identifier stored on a `Meeting.calendarEventID` when recording this event.
    var calendarEventID: String { googleEventID ?? appleEventID ?? id }

    /// EventKit does not tell us about all-day events in our model, so treat
    /// anything lasting most of a day as all-day. These are never "meetings".
    var isAllDay: Bool { end.timeIntervalSince(start) >= 23 * 60 * 60 }

    func isHappening(at now: Date) -> Bool { start <= now && end > now }

    init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [String] = [],
        meetingLink: URL? = nil,
        colorHex: String? = nil,
        calendarName: String? = nil,
        sources: Set<Source>,
        appleEventID: String? = nil,
        googleEventID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.meetingLink = meetingLink
        self.colorHex = colorHex
        self.calendarName = calendarName
        self.sources = sources
        self.appleEventID = appleEventID
        self.googleEventID = googleEventID
    }

    init(apple event: EventKitManager.CalendarEvent) {
        self.init(
            // EventKit gives every occurrence of a recurring event the same
            // identifier, so the start time makes each occurrence its own row.
            id: "apple:\(event.id)@\(Int(event.start.timeIntervalSince1970))",
            title: event.title,
            start: event.start,
            end: event.end,
            attendees: event.attendees,
            meetingLink: event.meetingLink,
            calendarName: event.calendarName.isEmpty ? nil : event.calendarName,
            sources: [.apple],
            appleEventID: event.id
        )
    }

    init(google event: GoogleCalendarClient.CalendarEvent) {
        self.init(
            id: "google:\(event.id)@\(Int(event.start.timeIntervalSince1970))",
            title: event.title,
            start: event.start,
            end: event.end,
            attendees: event.attendees,
            meetingLink: event.meetingLink,
            colorHex: event.colorHex,
            calendarName: "Google",
            sources: [.google],
            googleEventID: event.id
        )
    }
}

enum UnifiedCalendar {
    /// Two events closer than this at their start are candidates for the same meeting.
    static let startTolerance: TimeInterval = 2 * 60

    /// Merges Apple and Google events into one sorted list without duplicates.
    /// Google entries win on identity (they carry colours and stable IDs);
    /// missing fields are filled in from the Apple copy.
    static func merge(
        apple: [EventKitManager.CalendarEvent],
        google: [GoogleCalendarClient.CalendarEvent]
    ) -> [AgendaEvent] {
        merge(google.map(AgendaEvent.init(google:)) + apple.map(AgendaEvent.init(apple:)))
    }

    /// Dedupe an already-converted list. Earlier entries take precedence.
    static func merge(_ events: [AgendaEvent]) -> [AgendaEvent] {
        var result: [AgendaEvent] = []
        for event in events {
            if let index = result.firstIndex(where: { isSameMeeting($0, event) }) {
                result[index] = combine(result[index], with: event)
            } else {
                result.append(event)
            }
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func isSameMeeting(_ a: AgendaEvent, _ b: AgendaEvent) -> Bool {
        if a.id == b.id { return true }
        guard abs(a.start.timeIntervalSince(b.start)) <= startTolerance else { return false }
        if let linkA = a.meetingLink, let linkB = b.meetingLink,
           normalizedLink(linkA) == normalizedLink(linkB) {
            return true
        }
        let titleA = normalizedTitle(a.title)
        return !titleA.isEmpty && titleA == normalizedTitle(b.title)
    }

    static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedLink(_ url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return "\(host)/\(path)"
    }

    private static func combine(_ primary: AgendaEvent, with other: AgendaEvent) -> AgendaEvent {
        var merged = primary
        merged.sources.formUnion(other.sources)
        merged.appleEventID = merged.appleEventID ?? other.appleEventID
        merged.googleEventID = merged.googleEventID ?? other.googleEventID
        merged.meetingLink = merged.meetingLink ?? other.meetingLink
        merged.colorHex = merged.colorHex ?? other.colorHex
        if merged.attendees.isEmpty { merged.attendees = other.attendees }
        if merged.calendarName == nil { merged.calendarName = other.calendarName }
        return merged
    }

    // MARK: - Views over the merged list

    /// Events on the given day that have not ended yet (plus those in progress),
    /// all-day events last.
    static func remainingToday(
        _ events: [AgendaEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> [AgendaEvent] {
        let timed = events.filter {
            !$0.isAllDay && $0.end > now
                && (calendar.isDate($0.start, inSameDayAs: now) || $0.start <= now)
        }
        let allDay = events.filter { $0.isAllDay && $0.isHappening(at: now) }
        return timed + allDay
    }

    /// The event the "Now" row should feature: one in progress, else the next
    /// one starting within `horizon`.
    static func nowCandidate(
        _ events: [AgendaEvent],
        now: Date,
        horizon: TimeInterval = 12 * 60 * 60
    ) -> AgendaEvent? {
        let timed = events.filter { !$0.isAllDay }
        if let current = timed.first(where: { $0.isHappening(at: now) }) {
            return current
        }
        return timed.first { $0.start > now && $0.start.timeIntervalSince(now) <= horizon }
    }
}
