import Foundation
import SwiftData
import Testing
@testable import LidIA

@MainActor
@Suite("Prep history matching")
struct PrepHistoryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @discardableResult
    private func meeting(
        _ title: String,
        daysAgo: Double,
        attendees: [String]? = nil,
        summary: String = "",
        eventID: String? = nil,
        in context: ModelContext
    ) -> Meeting {
        let meeting = Meeting(
            title: title,
            date: now.addingTimeInterval(-daysAgo * day),
            summary: summary,
            status: .complete,
            calendarEventID: eventID,
            calendarAttendees: attendees
        )
        context.insert(meeting)
        return meeting
    }

    private func library(_ context: ModelContext) throws -> [Meeting] {
        try context.fetch(FetchDescriptor<Meeting>())
    }

    /// The owner's case: a weekly client call imported from Granola with
    /// attendees joined into one string, plus unrelated internal meetings.
    private func seedOwnerLibrary(_ context: ModelContext) throws {
        let client = "Northwind x Harborcloud - SaaS Platform on AWS"
        meeting(client, daysAgo: 29, attendees: ["Alex Moreno <daniel.r@northwind.example>"], summary: "# AWS Account Access\n- IAM user created", in: context)
        meeting(client, daysAgo: 15, attendees: ["Alex Moreno <daniel.r@northwind.example>"], summary: "# Invoices\n- Invoice extraction scoped", in: context)
        let latest = meeting(client, daysAgo: 6, attendees: ["Alex Moreno <daniel.r@northwind.example>"], summary: "# Northwind App Mockup\n- Dashboard demoed", in: context)
        let item = ActionItem(title: "Send the CloudFormation template", assignee: "Alex")
        latest.actionItems.append(item)
        meeting("Northwind x Harborcloud: Project pre kick-off", daysAgo: 33,
                attendees: ["Alex Moreno from Harborcloud, Nadia Petrenko <daniel.r@northwind.example>"], in: context)
        // Internal meetings that share only the user's own address.
        for (index, title) in ["Engineering - WBR", "Selin / Alex", "Bakery pop-up and supplier plan", "QA automation approach"].enumerated() {
            meeting(title, daysAgo: Double(2 + index), attendees: ["Alex Moreno <alex@harborcloud.example>"], in: context)
        }
        try context.save()
    }

    private var upcomingNorthwind: MeetingHistoryMatcher.Upcoming {
        MeetingHistoryMatcher.Upcoming(
            title: "Northwind x Harborcloud - SaaS Platform on AWS",
            attendees: ["felix.s@northwind.example", "daniel.r@northwind.example", "alex@harborcloud.example", "nadia@harborcloud.example"],
            start: now
        )
    }

    @Test func recurringClientMeetingFindsItsHistoryDespiteBrokenImports() throws {
        let context = try makeInMemoryContext()
        try seedOwnerLibrary(context)

        let matches = MeetingHistoryMatcher.matches(for: upcomingNorthwind, in: try library(context))
        #expect(matches.count == 4)
        #expect(matches.allSatisfy { $0.meeting.title.hasPrefix("Northwind") })
        #expect(matches.first?.meeting.summary.contains("Dashboard demoed") == true) // most recent first
        #expect(matches.first?.reasons.contains(.sameTitle) == true)

        let brief = PrepBrief.context(for: upcomingNorthwind, library: try library(context))
        #expect(brief.hasHistory)
        #expect(brief.prompt.contains("NOT a first meeting"))
        #expect(!brief.prompt.contains("say this looks like a first meeting"))
        #expect(brief.prompt.contains("4 earlier meetings"))
        #expect(brief.prompt.contains("Dashboard demoed"))
        #expect(brief.prompt.contains("Invoice extraction scoped"))
        #expect(brief.prompt.contains("Send the CloudFormation template"))
        // Only the most recent summaries are included.
        #expect(!brief.prompt.contains("IAM user created") || PrepBrief.summaryCount >= 3)
    }

    @Test func titleSeriesMatchesWithoutAnyAttendees() throws {
        let context = try makeInMemoryContext()
        meeting("Weekly sync — 2026-10-05", daysAgo: 14, summary: "- Roadmap reviewed", in: context)
        meeting("Weekly Sync 2026-10-12", daysAgo: 7, summary: "- Hiring plan", in: context)
        try context.save()

        let upcoming = MeetingHistoryMatcher.Upcoming(title: "Weekly sync 2026-10-19", attendees: [], start: now)
        let matches = MeetingHistoryMatcher.matches(for: upcoming, in: try library(context))
        #expect(matches.map(\.meeting.summary) == ["- Hiring plan", "- Roadmap reviewed"])
        #expect(PrepBrief.context(for: upcoming, library: try library(context)).hasHistory)
    }

    @Test func theUsersOwnAddressDoesNotMakeEverythingHistory() throws {
        let context = try makeInMemoryContext()
        try seedOwnerLibrary(context)
        let upcoming = MeetingHistoryMatcher.Upcoming(
            title: "Intro with Contoso",
            attendees: ["alex@harborcloud.example", "ceo@contoso.example"],
            start: now
        )
        let brief = PrepBrief.context(for: upcoming, library: try library(context))
        #expect(!brief.hasHistory)
        #expect(brief.prompt.contains("first meeting"))
    }

    @Test func sharedExternalAttendeeMatchesADifferentTitle() throws {
        let context = try makeInMemoryContext()
        meeting("Kickoff", daysAgo: 10, attendees: ["Ana Ruiz <ana@acme.example>", "alex@harborcloud.example"], in: context)
        try context.save()
        let upcoming = MeetingHistoryMatcher.Upcoming(title: "Contract review", attendees: ["ana@acme.example"], start: now)
        let matches = MeetingHistoryMatcher.matches(for: upcoming, in: try library(context))
        #expect(matches.map(\.meeting.title) == ["Kickoff"])
        #expect(matches.first?.reasons == [.sharedAttendees])
    }

    @Test func recurringGoogleEventInstancesShareASeries() throws {
        let context = try makeInMemoryContext()
        meeting("Renamed by the organiser", daysAgo: 7, eventID: "abc123def_20261027T090000Z", in: context)
        try context.save()
        let upcoming = MeetingHistoryMatcher.Upcoming(
            title: "Something else", attendees: [], calendarEventIDs: ["abc123def_20261103T090000Z"], start: now
        )
        #expect(MeetingHistoryMatcher.matches(for: upcoming, in: try library(context)).count == 1)
        #expect(MeetingHistoryMatcher.seriesID(of: "google:abc_20261103T090000Z") == "abc")
    }

    @Test func meetingsAfterTheEventAreNotHistory() throws {
        let context = try makeInMemoryContext()
        meeting("Board meeting", daysAgo: -1, in: context)
        try context.save()
        let upcoming = MeetingHistoryMatcher.Upcoming(title: "Board meeting", attendees: [], start: now)
        #expect(MeetingHistoryMatcher.matches(for: upcoming, in: try library(context)).isEmpty)
    }

    @Test func identitiesParseJoinedParticipantLists() {
        let ids = MeetingHistoryMatcher.identities(from: ["Alex Moreno from Harborcloud, Leo, Nadia Petrenko 🇺🇦 <mila@harborcloud.test>"])
        #expect(ids.emails == ["mila@harborcloud.test"])
        #expect(ids.names == ["alex moreno", "leo", "nadia petrenko"])
    }

    @Test func oldFirstEncounterBriefsAreRecognised() {
        #expect(ProactiveInsightsService.claimsFirstEncounter("This appears to be a first-encounter meeting with Northwind."))
        #expect(!ProactiveInsightsService.claimsFirstEncounter("Last time you agreed to send the template."))
    }
}
