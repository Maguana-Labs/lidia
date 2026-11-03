import EventKit
import Foundation
import Observation

/// A calendar event LidIA can record or join.
struct UpcomingEvent: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String]
    var joinURL: URL?
    var location: String?

    var isNow: Bool { start <= .now && end > .now }
}

/// Reads the next meetings from the user's calendars (Apple, Google and
/// Exchange accounts added to iOS). Asks for access only when the user taps
/// "Connect calendar", never at launch.
@MainActor
@Observable
final class CalendarService {
    private let store = EKEventStore()
    private(set) var authorized = false
    private(set) var canAsk = true
    private(set) var upcoming: [UpcomingEvent] = []
    /// DEBUG demo builds inject events here.
    var demoEvents: [UpcomingEvent]?

    init() {
        updateStatus()
    }

    var next: UpcomingEvent? {
        upcoming.first { $0.end > .now }
    }

    func updateStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        canAsk = status == .notDetermined
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {}
        updateStatus()
        refresh()
    }

    func refresh() {
        if let demoEvents {
            upcoming = demoEvents.sorted { $0.start < $1.start }
            return
        }
        guard authorized else { upcoming = []; return }
        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3 * 3600),
            end: now.addingTimeInterval(36 * 3600),
            calendars: nil
        )
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { event in
                UpcomingEvent(
                    id: event.calendarItemIdentifier,
                    title: event.title ?? "Meeting",
                    start: event.startDate,
                    end: event.endDate,
                    attendees: (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                    joinURL: Self.joinURL(for: event),
                    location: event.location
                )
            }
    }

    /// The video-call link in the event's URL, location or notes.
    static func joinURL(for event: EKEvent) -> URL? {
        if let url = event.url, isMeetingLink(url.absoluteString) { return url }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let url = firstMeetingLink(in: text) { return url }
        }
        return nil
    }

    static func firstMeetingLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap(\.url).first { isMeetingLink($0.absoluteString) }
    }

    static func isMeetingLink(_ string: String) -> Bool {
        let lowered = string.lowercased()
        return ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com"]
            .contains { lowered.contains($0) }
    }
}
