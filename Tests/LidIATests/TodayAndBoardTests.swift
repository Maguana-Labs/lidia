import Foundation
import Testing
@testable import LidIA

@Suite struct ComingUpModelTests {
    private let calendar = Calendar.current

    private func at(_ day: Int, _ hour: Int, from now: Date) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .hour, value: day * 24 + hour, to: start)!
    }

    /// A daily recurring meeting shows on every day, alongside the rest.
    @Test func everyOccurrenceOfARecurringMeetingIsListed() {
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        let apple = (0..<5).map { day in
            EventKitManager.CalendarEvent(
                id: "standup-series", title: "Daily standup",
                start: at(day, 9, from: now), end: at(day, 9, from: now).addingTimeInterval(900),
                attendees: [], calendarName: "Work", meetingLink: nil
            )
        }
        let google = [
            GoogleCalendarClient.CalendarEvent(id: "g1", title: "Northwind sync", start: at(1, 13, from: now), end: at(1, 14, from: now), attendees: [], meetingLink: nil, colorHex: nil),
        ]
        let days = ComingUpModel.days(UnifiedCalendar.merge(apple: apple, google: google), now: now)
        #expect(days.count == 5)
        #expect(days.allSatisfy { day in day.events.contains { $0.title == "Daily standup" } })
        #expect(days[1].events.map(\.title) == ["Daily standup", "Northwind sync"])
        #expect(days[0].isToday)
    }

    @Test func todayIsAlwaysFirstEvenWhenFree() {
        let now = Date.now
        let event = AgendaEvent(id: "x", title: "Later", start: at(2, 10, from: now), end: at(2, 11, from: now), sources: [.google])
        let days = ComingUpModel.days([event], now: now)
        #expect(days.count == 2)
        #expect(days[0].isToday && days[0].events.isEmpty)
    }

    @Test func nextEventSkipsFinishedOnes() {
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        let past = AgendaEvent(id: "p", title: "Past", start: at(0, 9, from: now), end: at(0, 10, from: now), sources: [.google])
        let next = AgendaEvent(id: "n", title: "Next", start: at(0, 15, from: now), end: at(0, 16, from: now), sources: [.google])
        #expect(ComingUpModel.nextEventID([past, next], now: now) == "n")
    }
}

@Suite struct ActionItemBoardModelTests {
    @Test func waitingColumnIsOptional() {
        #expect(ActionItemBoardModel.columns(showWaiting: true) == [.todo, .inProgress, .waiting, .done])
        #expect(ActionItemBoardModel.columns(showWaiting: false) == [.todo, .inProgress, .done])
    }

    @Test func groupsPutTheCatchAllLast() {
        let items = [("a", "Northwind"), ("b", nil), ("c", "Northwind"), ("d", "Pinecrest")]
        let groups = ActionItemBoardModel.groups(items, title: { $0.1 }, fallback: "No project")
        #expect(groups.map(\.title) == ["Northwind", "Pinecrest", "No project"])
        #expect(groups.first?.items.count == 2)
    }
}
