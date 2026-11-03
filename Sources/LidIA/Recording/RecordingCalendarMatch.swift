import Foundation

/// Which calendar event a recording started from Record (not from an event) belongs to.
///
/// Only a real meeting counts: an event with someone else invited or a call link, that is
/// on now or starts within 15 minutes. A personal block ("Close-down routine", "Focus") is
/// not a meeting, so the recording keeps no calendar title and the pipeline names it
/// from what was said.
enum RecordingCalendarMatch {
    struct Candidate: Equatable, Sendable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var attendees: [String]
        var hasMeetingLink: Bool
    }

    static let lookAhead: TimeInterval = 15 * 60

    /// Whether an event looks like a meeting rather than a block of time.
    static func isMeeting(_ event: Candidate, currentUserName: String = "") -> Bool {
        if event.hasMeetingLink { return true }
        let others = AttendeeParser.parse(event.attendees, currentUserName: currentUserName).filter { !$0.isCurrentUser }
        return !others.isEmpty
    }

    /// The meeting on now or starting soonest within `lookAhead`, or nil.
    static func pick(_ events: [Candidate], now: Date = .now, currentUserName: String = "") -> Candidate? {
        events
            .filter { $0.start <= now.addingTimeInterval(lookAhead) && $0.end > now.addingTimeInterval(60) }
            .filter { isMeeting($0, currentUserName: currentUserName) }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }
}
