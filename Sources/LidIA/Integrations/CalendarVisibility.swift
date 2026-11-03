import Foundation

/// Which calendars the user switched off in Settings › Calendars.
///
/// Apple calendars are keyed by their EventKit `calendarIdentifier`. The
/// Google account connected through Sign in with Google only reads its
/// primary calendar, keyed by `googlePrimaryID`.
enum CalendarVisibility {
    /// Key for the Google account's primary calendar (Sign in with Google).
    static let googlePrimaryID = "google:primary"

    static func isVisible(_ calendarID: String, hidden: some Collection<String>) -> Bool {
        !hidden.contains(calendarID)
    }

    /// Keeps the items whose calendar is not hidden. Items without a calendar
    /// ID (nil or empty) are always kept.
    static func visible<Item>(
        _ items: [Item],
        hidden: [String],
        calendarID: (Item) -> String?
    ) -> [Item] {
        guard !hidden.isEmpty else { return items }
        let hiddenSet = Set(hidden)
        return items.filter { item in
            guard let id = calendarID(item), !id.isEmpty else { return true }
            return !hiddenSet.contains(id)
        }
    }

    /// Google events to show: none when the primary calendar is hidden.
    static func visibleGoogleEvents<Event>(_ events: [Event], hidden: [String]) -> [Event] {
        hidden.contains(googlePrimaryID) ? [] : events
    }

    /// Returns `hidden` with `calendarID` added or removed. Keeps order and
    /// never adds a duplicate.
    static func setting(_ calendarID: String, visible: Bool, in hidden: [String]) -> [String] {
        if visible {
            return hidden.filter { $0 != calendarID }
        }
        return hidden.contains(calendarID) ? hidden : hidden + [calendarID]
    }
}
