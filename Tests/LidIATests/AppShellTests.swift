import Foundation
import Testing
@testable import LidIA

// MARK: - Fixtures

private let gregorian: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return calendar
}()

private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
    gregorian.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func appleEvent(
    _ id: String,
    _ title: String,
    start: Date,
    minutes: Int = 30,
    link: String? = nil,
    attendees: [String] = []
) -> EventKitManager.CalendarEvent {
    EventKitManager.CalendarEvent(
        id: id,
        title: title,
        start: start,
        end: start.addingTimeInterval(TimeInterval(minutes * 60)),
        attendees: attendees,
        calendarName: "Work",
        meetingLink: link.flatMap(URL.init(string:))
    )
}

private func googleEvent(
    _ id: String,
    _ title: String,
    start: Date,
    minutes: Int = 30,
    link: String? = nil,
    attendees: [String] = []
) -> GoogleCalendarClient.CalendarEvent {
    GoogleCalendarClient.CalendarEvent(
        id: id,
        title: title,
        start: start,
        end: start.addingTimeInterval(TimeInterval(minutes * 60)),
        attendees: attendees,
        meetingLink: link.flatMap(URL.init(string:)),
        colorHex: "#4285F4"
    )
}

private struct FakeMeeting: MeetingListItem {
    let name: String
    let status: MeetingStatus
    let date: Date
    var folder: String? = nil
}

// MARK: - Unified calendar

/// EventKit gives every occurrence of a recurring event the same identifier.
/// Each day's occurrence must still show up.
@Test func calendarMergeKeepsEveryOccurrenceOfARecurringEvent() {
    let merged = UnifiedCalendar.merge(
        apple: [
            appleEvent("daily", "Close-down routine", start: date(3, 11)),
            appleEvent("daily", "Close-down routine", start: date(4, 11)),
            appleEvent("daily", "Close-down routine", start: date(5, 11)),
        ],
        google: []
    )
    #expect(merged.count == 3)
    #expect(Set(merged.map(\.id)).count == 3)
    #expect(merged.allSatisfy { $0.appleEventID == "daily" })
}

@Test func calendarMergeDedupesSameMeetingFromBothCalendars() {
    let start = date(2, 10)
    let merged = UnifiedCalendar.merge(
        apple: [appleEvent("a1", "Weekly Sync", start: start.addingTimeInterval(30), attendees: ["Ana"])],
        google: [googleEvent("g1", "weekly sync", start: start, link: "https://meet.google.com/abc-defg-hij")]
    )

    #expect(merged.count == 1)
    let event = merged[0]
    #expect(event.id.hasPrefix("google:g1@"))
    #expect(event.sources == [.apple, .google])
    #expect(event.appleEventID == "a1")
    #expect(event.googleEventID == "g1")
    #expect(event.calendarEventID == "g1")
    #expect(event.meetingLink?.host() == "meet.google.com")
    #expect(event.attendees == ["Ana"])
}

@Test func calendarMergeMatchesOnSameCallLinkEvenWithDifferentTitles() {
    let start = date(2, 10)
    let merged = UnifiedCalendar.merge(
        apple: [appleEvent("a1", "Sync w/ Ana", start: start, link: "https://zoom.us/j/12345?pwd=x")],
        google: [googleEvent("g1", "Ana / Alex", start: start, link: "https://zoom.us/j/12345")]
    )
    #expect(merged.count == 1)
}

@Test func calendarMergeKeepsDistinctMeetings() {
    let start = date(2, 10)
    let merged = UnifiedCalendar.merge(
        apple: [
            appleEvent("a1", "Standup", start: start),
            appleEvent("a2", "Standup", start: start.addingTimeInterval(24 * 60 * 60)),
        ],
        google: [googleEvent("g1", "Design review", start: start)]
    )
    #expect(merged.count == 3)
    #expect(merged.map(\.title) == ["Design review", "Standup", "Standup"])
}

@Test func calendarNowCandidatePrefersMeetingInProgress() {
    let now = date(2, 10, 15)
    let events = UnifiedCalendar.merge(
        apple: [
            appleEvent("a1", "In progress", start: date(2, 10), minutes: 60),
            appleEvent("a2", "Next", start: date(2, 11)),
            appleEvent("a3", "Holiday", start: date(2, 0), minutes: 24 * 60),
        ],
        google: []
    )
    #expect(UnifiedCalendar.nowCandidate(events, now: now)?.title == "In progress")
    #expect(UnifiedCalendar.nowCandidate(events, now: date(2, 11, 5))?.title == "Next")
    #expect(UnifiedCalendar.nowCandidate(events, now: date(2, 23, 59)) == nil)
}

@Test func calendarRemainingTodayExcludesEndedAndTomorrow() {
    let now = date(2, 12)
    let events = UnifiedCalendar.merge(
        apple: [
            appleEvent("a1", "Morning", start: date(2, 9)),
            appleEvent("a2", "Afternoon", start: date(2, 15)),
            appleEvent("a3", "Tomorrow", start: date(3, 9)),
        ],
        google: []
    )
    let today = UnifiedCalendar.remainingToday(events, now: now, calendar: gregorian)
    #expect(today.map(\.title) == ["Afternoon"])
}

// MARK: - Meeting list grouping

@Test func meetingListPutsFailedQueuedProcessingInNeedsAttention() {
    let now = date(2, 18)
    let meetings = [
        FakeMeeting(name: "done", status: .complete, date: date(2, 9)),
        FakeMeeting(name: "processing", status: .processing, date: date(2, 17)),
        FakeMeeting(name: "failed-old", status: .failed, date: date(1, 9)),
        FakeMeeting(name: "queued", status: .queued, date: date(2, 16)),
        FakeMeeting(name: "failed-new", status: .failed, date: date(2, 11)),
        FakeMeeting(name: "live", status: .recording, date: date(2, 17, 30)),
    ]

    let attention = MeetingListModel.attentionItems(meetings)
    #expect(attention.map(\.name) == ["failed-new", "failed-old", "queued", "processing"])

    let groups = MeetingListModel.dateGroups(meetings, now: now, calendar: gregorian)
    #expect(groups.map(\.label) == ["Today"])
    #expect(groups[0].items.map(\.name) == ["live", "done"])
}

@Test func meetingListShowsEveryStatusSomewhere() {
    let statuses: [MeetingStatus] = [.recording, .processing, .queued, .complete, .failed]
    let meetings = statuses.enumerated().map {
        FakeMeeting(name: $0.element.rawValue, status: $0.element, date: date(2, 9 + $0.offset))
    }
    let attention = MeetingListModel.attentionItems(meetings).map(\.name)
    let grouped = MeetingListModel.dateGroups(meetings, now: date(2, 20), calendar: gregorian)
        .flatMap(\.items).map(\.name)
    #expect(Set(attention + grouped) == Set(statuses.map(\.rawValue)))
    #expect(attention.count + grouped.count == statuses.count)
}

@Test func meetingListBadgesEveryNonCompleteStatus() {
    #expect(MeetingListModel.badge(for: .complete) == nil)
    #expect(MeetingListModel.badge(for: .failed)?.tone == .failure)
    #expect(MeetingListModel.badge(for: .queued)?.label == "Queued")
    #expect(MeetingListModel.badge(for: .processing) != nil)
    #expect(MeetingListModel.badge(for: .recording)?.tone == .live)
}

@Test func meetingListFolderFilterAppliesToBothGroups() {
    let meetings = [
        FakeMeeting(name: "a", status: .complete, date: date(2, 9), folder: "Work"),
        FakeMeeting(name: "b", status: .failed, date: date(2, 9), folder: "Home"),
        FakeMeeting(name: "c", status: .failed, date: date(2, 9), folder: "Work"),
    ]
    #expect(MeetingListModel.attentionItems(meetings, folder: "Work").map(\.name) == ["c"])
    #expect(MeetingListModel.dateGroups(meetings, folder: "Home", now: date(2, 20), calendar: gregorian).isEmpty)
}

@Test func meetingListDayLabels() {
    let now = date(5, 12)
    #expect(MeetingListModel.dayLabel(for: date(5, 8), now: now, calendar: gregorian) == "Today")
    #expect(MeetingListModel.dayLabel(for: date(4, 8), now: now, calendar: gregorian) == "Yesterday")
}

// MARK: - Pre-meeting prompts

private let defaultPromptConfig = PreMeetingPromptPlanner.Config(
    notifyUpcoming: true,
    notifyMinutes: 10,
    recordPromptEnabled: true,
    prepEnabled: false,
    prepMinutes: 15
)

@Test func promptHonoursReminderMinutesSetting() {
    let start = date(2, 10)
    let events = [AgendaEvent(google: googleEvent("g1", "Sync", start: start))]

    let early = PreMeetingPromptPlanner.due(
        events: events, now: start.addingTimeInterval(-11 * 60),
        config: defaultPromptConfig, alreadyPrompted: [], isRecording: false
    )
    #expect(early.isEmpty)

    let onTime = PreMeetingPromptPlanner.due(
        events: events, now: start.addingTimeInterval(-10 * 60),
        config: defaultPromptConfig, alreadyPrompted: [], isRecording: false
    )
    #expect(onTime.count == 1)
    #expect(onTime.first?.leadMinutes == 10)
}

@Test func promptFiresOncePerMeetingAcrossCalendars() {
    let start = date(2, 10)
    let link = "https://meet.google.com/abc-defg-hij"
    let events = [
        AgendaEvent(google: googleEvent("g1", "Sync", start: start, link: link)),
        AgendaEvent(apple: appleEvent("a1", "Sync", start: start, link: link)),
    ]
    let now = start.addingTimeInterval(-5 * 60)

    let first = PreMeetingPromptPlanner.due(
        events: events, now: now, config: defaultPromptConfig, alreadyPrompted: [], isRecording: false
    )
    #expect(first.count == 1)
    #expect(first[0].kind == .banner)

    let second = PreMeetingPromptPlanner.due(
        events: events, now: now.addingTimeInterval(60), config: defaultPromptConfig,
        alreadyPrompted: Set(first.map(\.event.id)), isRecording: false
    )
    #expect(second.isEmpty)
}

@Test func promptUsesNotificationWithoutCallLinkAndSkipsWhileRecording() {
    let start = date(2, 10)
    let events = [AgendaEvent(apple: appleEvent("a1", "1:1 in office", start: start))]
    let now = start.addingTimeInterval(-60)

    let decisions = PreMeetingPromptPlanner.due(
        events: events, now: now, config: defaultPromptConfig, alreadyPrompted: [], isRecording: false
    )
    #expect(decisions.map(\.kind) == [.notification])

    let whileRecording = PreMeetingPromptPlanner.due(
        events: events, now: now, config: defaultPromptConfig, alreadyPrompted: [], isRecording: true
    )
    #expect(whileRecording.isEmpty)
}

@Test func promptDisabledWhenEveryReminderIsOff() {
    var config = defaultPromptConfig
    config.notifyUpcoming = false
    config.recordPromptEnabled = false
    config.prepEnabled = false
    #expect(config.leadMinutes == nil)

    config.prepEnabled = true
    #expect(config.leadMinutes == 15)
}

@Test func promptSkipsAllDayAndLongPastEvents() {
    let now = date(2, 10)
    let events = [
        AgendaEvent(apple: appleEvent("a1", "Holiday", start: date(2, 0), minutes: 24 * 60)),
        AgendaEvent(apple: appleEvent("a2", "Started 20 min ago", start: now.addingTimeInterval(-20 * 60), minutes: 60)),
    ]
    let decisions = PreMeetingPromptPlanner.due(
        events: events, now: now, config: defaultPromptConfig, alreadyPrompted: [], isRecording: false
    )
    #expect(decisions.isEmpty)
}

@Test func promptNotificationBodyIncludesPrepOnlyWhenEnabled() {
    let start = date(2, 10)
    let event = AgendaEvent(apple: appleEvent("a1", "Review", start: start))
    let withPrep = PreMeetingPromptPlanner.Decision(event: event, kind: .notification, includePrep: true, leadMinutes: 10)
    let body = PreMeetingPromptPlanner.notificationBody(
        for: withPrep, now: start.addingTimeInterval(-10 * 60), prepSummary: "Open items: ship it"
    )
    #expect(body == "Review starts in 10 min. Open items: ship it")

    let noPrep = PreMeetingPromptPlanner.Decision(event: event, kind: .notification, includePrep: false, leadMinutes: 10)
    #expect(PreMeetingPromptPlanner.notificationBody(for: noPrep, now: start, prepSummary: "x") == "Review is starting now.")
}

// MARK: - Export

@Test func exportFilenameIsDatedAndSafe() {
    let name = ExportService.suggestedFilename(title: "Q4: plan / budget?\nfinal", date: date(2, 10), calendar: gregorian)
    #expect(name == "2026-11-02 Q4 plan budget final.md")
    #expect(ExportService.suggestedFilename(title: "  ", date: date(2, 10), calendar: gregorian) == "2026-11-02 Untitled meeting.md")
}

// MARK: - Search

@Test func searchMatchesAllWordsAndPrefersTitle() {
    let fields = ShellSearch.MeetingFields(
        title: "Budget review",
        notes: "Remember the budget for Q4 hiring",
        summary: "",
        transcript: "we talked about the hiring budget at length",
        attendees: ["Ana Moreno <ana@example.com>"]
    )
    #expect(ShellSearch.match(fields, query: "budget")?.field == .title)
    #expect(ShellSearch.match(fields, query: "hiring budget")?.field == .notes)
    #expect(ShellSearch.match(fields, query: "moreno")?.field == .attendees)
    #expect(ShellSearch.match(fields, query: "length")?.field == .transcript)
    #expect(ShellSearch.match(fields, query: "roadmap") == nil)
    #expect(ShellSearch.match(fields, query: "   ") == nil)
}

@Test func searchSnippetIsShortAndMarked() {
    let text = String(repeating: "a ", count: 60) + "needle" + String(repeating: " b", count: 60)
    let snippet = ShellSearch.snippet(in: text, around: "needle", radius: 10)
    #expect(snippet.hasPrefix("…"))
    #expect(snippet.hasSuffix("…"))
    #expect(snippet.contains("needle"))
    #expect(snippet.count < 40)
}
