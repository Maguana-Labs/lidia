import Foundation

/// An event as the intents see it, from Apple Calendar (EventKit) or Google.
struct IntentCalendarEvent: Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String] = []
    var isAllDay = false
    /// "apple" (LidIA can edit it through EventKit) or "google" (read-only).
    var source: String
    /// The user can change it (EventKit `allowsContentModifications`).
    var editable: Bool
    var calendarName: String = ""
}

/// Where intents read busy times and move events. Main actor: EventKit.
@MainActor
protocol IntentCalendarSource: AnyObject {
    var isAvailable: Bool { get }
    func events(from start: Date, to end: Date) -> [IntentCalendarEvent]
    /// Moves an event. Only the confirmation UI calls this.
    func move(eventID: String, to start: Date, end: Date) throws
}

/// Fixed events, for tests and design snapshots.
@MainActor
final class FixtureCalendarSource: IntentCalendarSource {
    var fixture: [IntentCalendarEvent]
    private(set) var moves: [(String, Date, Date)] = []
    var isAvailable: Bool { true }

    init(_ events: [IntentCalendarEvent]) { fixture = events }

    func events(from start: Date, to end: Date) -> [IntentCalendarEvent] {
        fixture.filter { $0.end > start && $0.start < end }
    }

    func move(eventID: String, to start: Date, end: Date) throws {
        guard let index = fixture.firstIndex(where: { $0.id == eventID }) else { throw CocoaError(.fileNoSuchFile) }
        fixture[index].start = start
        fixture[index].end = end
        moves.append((eventID, start, end))
    }
}

/// Free time in a calendar. Pure.
enum SlotFinder {
    struct Rules: Sendable {
        var dayStartHour = 9
        var dayEndHour = 18
        var weekdaysOnly = true
        var step: TimeInterval = 30 * 60
        /// Free time kept before and after other events.
        var buffer: TimeInterval = 0
        var maxSlots = 3
        /// At most this many slots on one day, so the choices differ.
        var perDay = 1
    }

    /// Free slots of `duration` between `from` and `to`, skipping `avoidDays`.
    /// When `preferTimeOfDay` is set (seconds after midnight), slots closest
    /// to that time come first on each day.
    static func freeSlots(
        busy: [DateInterval],
        duration: TimeInterval,
        from: Date,
        to: Date,
        avoidDays: [Date] = [],
        preferTimeOfDay: TimeInterval? = nil,
        rules: Rules = Rules(),
        calendar: Calendar = .current
    ) -> [ActionIntent.Slot] {
        guard duration > 0, from < to else { return [] }
        let avoided = Set(avoidDays.map { calendar.startOfDay(for: $0) })
        let sortedBusy = busy.sorted { $0.start < $1.start }
        var result: [ActionIntent.Slot] = []
        var day = calendar.startOfDay(for: from)
        while day < to, result.count < rules.maxSlots {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? to }
            if avoided.contains(day) { continue }
            if rules.weekdaysOnly, calendar.isDateInWeekend(day) { continue }
            guard let open = calendar.date(bySettingHour: rules.dayStartHour, minute: 0, second: 0, of: day),
                  let close = calendar.date(bySettingHour: rules.dayEndHour, minute: 0, second: 0, of: day) else { continue }
            var candidates: [ActionIntent.Slot] = []
            var start = max(open, roundUp(from, step: rules.step, calendar: calendar))
            while start.addingTimeInterval(duration) <= close {
                let end = start.addingTimeInterval(duration)
                let window = DateInterval(start: start.addingTimeInterval(-rules.buffer), end: end.addingTimeInterval(rules.buffer))
                if !sortedBusy.contains(where: { $0.start < window.end && $0.end > window.start }) {
                    candidates.append(ActionIntent.Slot(start: start, end: end))
                }
                start = start.addingTimeInterval(rules.step)
            }
            if let preferred = preferTimeOfDay {
                candidates.sort { abs($0.start.timeIntervalSince(day) - preferred) < abs($1.start.timeIntervalSince(day) - preferred) }
            }
            for slot in candidates.prefix(rules.perDay) where result.count < rules.maxSlots {
                result.append(slot)
            }
        }
        return result
    }

    /// The meeting an item means: "the Friday meeting" → the user's meeting
    /// with other people on the next Friday. Most attendees first, then the
    /// ones LidIA can edit.
    static func targetEvents(for title: String, among events: [IntentCalendarEvent], now: Date, calendar: Calendar = .current) -> [IntentCalendarEvent] {
        let words = IntentText.words(title)
        let weekday = weekdayNumber(in: words)
        let relative: Int? = words.contains("tomorrow") ? 1 : words.contains("today") ? 0 : nil
        let candidates = events.filter { event in
            guard !event.isAllDay, event.start > now else { return false }
            if let weekday { return calendar.component(.weekday, from: event.start) == weekday && event.start.timeIntervalSince(now) < 8 * 86_400 }
            if let relative, let target = calendar.date(byAdding: .day, value: relative, to: now) { return calendar.isDate(event.start, inSameDayAs: target) }
            // A named meeting: match its title words.
            let titleWords = Set(IntentText.keywords(event.title))
            return !titleWords.isDisjoint(with: IntentText.keywords(title))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.attendees.count != rhs.attendees.count { return lhs.attendees.count > rhs.attendees.count }
            if lhs.editable != rhs.editable { return lhs.editable }
            return lhs.start < rhs.start
        }
    }

    /// 1 = Sunday … 7 = Saturday, from English or Spanish day names.
    static func weekdayNumber(in words: [String]) -> Int? {
        let english = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let spanish = ["domingo", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado"]
        for (index, pair) in zip(english, spanish).enumerated() where words.contains(pair.0) || words.contains(pair.1) {
            return index + 1
        }
        return nil
    }

    private static func roundUp(_ date: Date, step: TimeInterval, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let seconds = date.timeIntervalSince(day)
        return day.addingTimeInterval((seconds / step).rounded(.up) * step)
    }
}
