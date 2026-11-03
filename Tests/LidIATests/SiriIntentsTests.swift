import AppIntents
import Foundation
import LidIAAppIntents
import LidIAKit
import SwiftData
import Testing
@testable import LidIA

// Siri and Shortcuts: the lookup rules (pure, over value copies), the
// privacy policy, the recap, and the intents run against an in-memory library.
// Intent tests flip Local-only mode, so they live in the serialized
// Local-only suite (see the extension at the bottom).

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ d: Int, _ hour: Int = 10) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
}

private func meeting(
    _ title: String, _ date: Date, people: [SiriPerson] = [], project: String? = nil, text: String = ""
) -> SiriMeetingRecord {
    SiriMeetingRecord(id: UUID(), title: title, date: date, people: people, project: project, searchableText: text)
}

@Suite("Siri: finding meetings")
struct SiriMeetingSearchTests {
    let mateo = SiriPerson(name: "Mateo Keller", email: "mateo.k@northwind.example")
    let daniel = SiriPerson(name: "Daniel", email: nil)
    let me = SiriPerson(name: "Alex Moreno", email: "alex@harborcloud.example", isCurrentUser: true)

    var records: [SiriMeetingRecord] {
        [
            meeting("Northwind weekly", day(5), people: [me, mateo, daniel], project: "Northwind", text: "Pricing for the pilot. Contract next."),
            meeting("Northwind weekly", day(12), people: [me, mateo], project: "Northwind", text: "Signed the contract."),
            meeting("Hiring sync", day(13), people: [me, daniel], text: "Backend role, pricing of recruiters."),
            meeting("1:1 with Ana", day(20), people: [me], project: "Team"),
        ]
    }

    @Test("By person: name, part of a name or email, newest first")
    func byPerson() {
        let found = SiriLibrary.findMeetings(records, SiriMeetingSearch(person: "mateo"), calendar: calendar)
        #expect(found.map(\.date) == [day(12), day(5)])
        let byEmail = SiriLibrary.findMeetings(records, SiriMeetingSearch(person: "northwind.example"), calendar: calendar)
        #expect(byEmail.count == 2)
        // A name only in the title still counts ("1:1 with Ana").
        #expect(SiriLibrary.findMeetings(records, SiriMeetingSearch(person: "Ana"), calendar: calendar).map(\.title) == ["1:1 with Ana"])
    }

    @Test("By project, case- and accent-insensitive")
    func byProject() {
        let found = SiriLibrary.findMeetings(records, SiriMeetingSearch(project: "nórthwind"), calendar: calendar)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.project == "Northwind" })
    }

    @Test("Date range: the end day counts in full")
    func byDateRange() {
        let found = SiriLibrary.findMeetings(records, SiriMeetingSearch(from: day(12), to: day(13, 0)), calendar: calendar)
        #expect(found.map(\.title) == ["Hiring sync", "Northwind weekly"])
    }

    @Test("Keywords: title and people beat a mention in the notes")
    func keywordRanking() {
        let contract = SiriLibrary.findMeetings(records, SiriMeetingSearch(keyword: "the contract"), calendar: calendar)
        #expect(contract.count == 2)
        #expect(contract.allSatisfy { $0.title == "Northwind weekly" })

        // "pricing" is only in notes: both mentions count, newest first.
        let pricing = SiriLibrary.findMeetings(records, SiriMeetingSearch(keyword: "pricing"), calendar: calendar)
        #expect(pricing.map(\.title) == ["Hiring sync", "Northwind weekly"])

        // Strong matches only: "northwind" is in two titles, so a weak mention elsewhere is dropped.
        let strong = SiriLibrary.findMeetings(records + [meeting("Ops", day(21), text: "northwind invoice")], SiriMeetingSearch(keyword: "northwind"), calendar: calendar)
        #expect(strong.allSatisfy { $0.title == "Northwind weekly" })
    }

    @Test("Transcripts are read only when the rest finds too little")
    func transcriptFallback() {
        var read: [UUID] = []
        let records = records
        let found = SiriLibrary.findMeetings(records, SiriMeetingSearch(keyword: "kubernetes"), calendar: calendar) { id in
            read.append(id)
            return id == records[3].id ? "we talked about Kubernetes upgrades" : ""
        }
        #expect(found.map(\.title) == ["1:1 with Ana"])
        #expect(!read.isEmpty)

        read = []
        _ = SiriLibrary.findMeetings(records, SiriMeetingSearch(keyword: "northwind", limit: 2), calendar: calendar) { id in
            read.append(id)
            return ""
        }
        #expect(read.isEmpty)
    }

    @Test("Entity string query matches title, project and people words")
    func stringQuery() {
        #expect(SiriLibrary.meetings(matching: "weekly mateo", in: records).count == 2)
        #expect(SiriLibrary.meetings(matching: "team", in: records).map(\.title) == ["1:1 with Ana"])
        #expect(SiriLibrary.meetings(matching: "", in: records).first?.title == "1:1 with Ana")
    }

    @Test("People: everyone but the user, a bare name joins the same person's email")
    func people() {
        let danielWithEmail = SiriPerson(name: "Daniel", email: "daniel.r@northwind.example")
        let records = records + [meeting("Northwind kickoff", day(1), people: [me, danielWithEmail])]
        let people = SiriLibrary.people(from: records)
        #expect(!people.contains { $0.name == "Alex Moreno" })
        let daniel = people.filter { SiriText.fold($0.name) == "daniel" }
        #expect(daniel.count == 1)
        #expect(daniel.first?.email == "daniel.r@northwind.example")
        #expect(daniel.first?.meetingCount == 3)
        #expect(daniel.first?.lastMet == day(13))
        #expect(people.first?.lastMet == day(13))
    }

    @Test("Projects: one per folded name, newest activity first")
    func projects() {
        let projects = SiriLibrary.projects(from: records + [meeting("x", day(2), project: "northwind")])
        #expect(projects.map(\.name) == ["Team", "Northwind"])
        #expect(projects.last?.meetingCount == 3)
    }

    @Test("Default attendee parsing: name and email, bare email, bare name; the user is marked")
    func defaultPeople() {
        let people = SiriDefaults.parsePeople(["Mateo K <Mateo.K@northwind.example>", "daniel.r@northwind.example", "Alex Moreno", " "], userName: "Alex Moreno")
        #expect(people.count == 3)
        #expect(people[0].email == "mateo.k@northwind.example")
        #expect(people[1].displayName == "Daniel R")
        #expect(people[2].isCurrentUser)
        #expect(SiriDefaults.project(ofFolder: "  ") == nil)
    }
}

@Suite("Siri: action items")
struct SiriActionItemSearchTests {
    let meetingID = UUID()

    var items: [SiriActionItemRecord] {
        [
            SiriActionItemRecord(id: UUID(), title: "Send the proposal", owner: "Alex", dueDate: day(16), meetingID: meetingID, meetingTitle: "Northwind weekly", meetingDate: day(12), project: "Northwind"),
            SiriActionItemRecord(id: UUID(), title: "Share the recording", owner: "You", meetingTitle: "Hiring sync", meetingDate: day(13)),
            SiriActionItemRecord(id: UUID(), title: "Review the contract", owner: "Mateo", dueDate: day(14), meetingID: meetingID, meetingTitle: "Northwind weekly", meetingDate: day(12), project: "Northwind"),
            SiriActionItemRecord(id: UUID(), title: "Book the venue", owner: "Alex Moreno", status: .done, meetingDate: day(1)),
            SiriActionItemRecord(id: UUID(), title: "Update the board", owner: nil, status: .waiting, meetingDate: day(20)),
        ]
    }

    @Test("Mine: the user's name, first name, or you/me; done items left out")
    func mine() {
        let mine = SiriLibrary.findActionItems(items, SiriActionItemSearch(owner: .mine), userName: "Alex Moreno", calendar: calendar)
        #expect(mine.map(\.title) == ["Send the proposal", "Share the recording"])
        let withDone = SiriLibrary.findActionItems(items, SiriActionItemSearch(owner: .mine, includeDone: true), userName: "Alex Moreno", calendar: calendar)
        #expect(withDone.contains { $0.title == "Book the venue" })
    }

    @Test("Soonest due first, then the newest meeting")
    func ordering() {
        let all = SiriLibrary.findActionItems(items, SiriActionItemSearch(), userName: "Alex Moreno", calendar: calendar)
        #expect(all.map(\.title) == ["Review the contract", "Send the proposal", "Update the board", "Share the recording"])
    }

    @Test("By person, project, meeting and due date")
    func filters() {
        let byPerson = SiriLibrary.findActionItems(items, SiriActionItemSearch(owner: .person("mateo")), userName: "Alex", calendar: calendar)
        #expect(byPerson.map(\.title) == ["Review the contract"])
        let byProject = SiriLibrary.findActionItems(items, SiriActionItemSearch(project: "NORTHWIND"), userName: "Alex", calendar: calendar)
        #expect(byProject.count == 2)
        let byMeeting = SiriLibrary.findActionItems(items, SiriActionItemSearch(meetingID: meetingID), userName: "Alex", calendar: calendar)
        #expect(byMeeting.count == 2)
        let dueBy = SiriLibrary.findActionItems(items, SiriActionItemSearch(dueBy: day(14, 0)), userName: "Alex", calendar: calendar)
        #expect(dueBy.map(\.title) == ["Review the contract"])
    }

    @Test("Who counts as the user")
    func isUser() {
        #expect(SiriText.isUser("Me", userName: ""))
        #expect(SiriText.isUser("yo", userName: ""))
        #expect(SiriText.isUser("alex", userName: "Alex Moreno"))
        #expect(SiriText.isUser("Alex P.", userName: "Alex Moreno"))
        #expect(!SiriText.isUser("Mateo", userName: "Alex Moreno"))
        #expect(!SiriText.isUser(nil, userName: "Alex"))
    }

    @Test("String query: open items first")
    func stringQuery() {
        let found = SiriLibrary.actionItems(matching: "the", in: items)
        #expect(found.last?.title == "Book the venue")
        let open = SiriLibrary.actionItems(matching: "", in: items)
        #expect(open.allSatisfy { $0.isOpen })
    }
}

@MainActor
@Suite("Siri: privacy policy and recap")
struct SiriPolicyAndRecapTests {
    @Test("Content goes to Siri only with Local-only off and the setting on")
    func policy() throws {
        let suite = "lidia.siri.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Missing setting means on.
        #expect(SiriContentPolicy.current(defaults).allowsMeetingContent)
        #expect(SiriContentPolicy.current(defaults).blockedMessage == nil)

        defaults.set(true, forKey: SiriContentPolicy.localOnlyKey)
        let localOnly = SiriContentPolicy.current(defaults)
        #expect(!localOnly.allowsMeetingContent)
        #expect(localOnly.blockedMessage?.contains("Local-only") == true)

        defaults.set(false, forKey: SiriContentPolicy.localOnlyKey)
        defaults.set(false, forKey: SiriContentPolicy.readsContentKey)
        let off = SiriContentPolicy.current(defaults)
        #expect(!off.allowsMeetingContent)
        #expect(off.blockedMessage?.contains("Settings") == true)
    }

    @Test("The app's setting and the policy share a key")
    func sameKey() {
        #expect(SiriContentPolicy.localOnlyKey == PrivacyGate.localOnlyModeKey)
    }

    @Test("Decisions: from the structured summary, else under a Decisions heading")
    func decisions() {
        #expect(SiriRecap.decisions(fromStructuredSummary: Data(#"{"title":"x"}"#.utf8)).isEmpty)
        #expect(SiriRecap.decisions(fromStructuredSummary: nil).isEmpty)
        let structured = Data(#"{"title":"t","sections":[],"decisions":["Go with the pilot"," "],"actionItems":[]}"#.utf8)
        #expect(SiriRecap.decisions(fromStructuredSummary: structured) == ["Go with the pilot"])

        let markdown = """
        ## Discussion
        - Pricing came up
        ## Key decisions
        - **Ship** the pilot in May
        - Use [Linear](https://linear.app) for tickets
          - nested detail
        ## Next steps
        - Send the contract
        """
        #expect(SiriRecap.decisions(fromMarkdown: markdown) == ["Ship the pilot in May", "Use Linear for tickets"])
        #expect(SiriRecap.decisions(fromMarkdown: "**Acuerdos**\n- Firmar el contrato") == ["Firmar el contrato"])
    }

    @Test("Recap without content says why and never includes the summary")
    func recapBlocked() {
        let record = meeting("Northwind weekly", day(12), people: [SiriPerson(name: "Mateo"), SiriPerson(name: "Me", isCurrentUser: true)], project: "Northwind")
        let item = SiriActionItemRecord(id: UUID(), title: "Send <the> proposal", owner: "Alex", dueDate: day(16))
        let content = SiriMeetingContent(summary: "## Pricing\n- Secret number is 42", decisions: ["Go"])

        let open = SiriRecap.plainText(meeting: record, content: content, items: [item])
        #expect(open.contains("Secret number is 42"))
        #expect(open.contains("Decisions"))
        #expect(open.contains("With Mateo"))
        #expect(!open.contains("Me,"))

        let blocked = SiriRecap.plainText(meeting: record, content: nil, items: [item], blockedMessage: "Kept on device.")
        #expect(!blocked.contains("42"))
        #expect(blocked.contains("Kept on device."))
        #expect(blocked.contains("Send <the> proposal"))

        let html = SiriRecap.html(meeting: record, content: nil, items: [item], blockedMessage: "Kept on device.")
        #expect(html.contains("Send &lt;the&gt; proposal"))
        #expect(!html.contains("42"))
        #expect(SiriRecap.html(meeting: record, content: content, items: []).contains("<li>Secret number is 42</li>"))
    }

    @Test("What Siri says")
    func speech() {
        #expect(SiriSpeech.foundMeetings([]).contains("didn't find"))
        let found = SiriSpeech.foundMeetings([meeting("Northwind weekly", day(12))], now: day(12, 18))
        #expect(found == "I found one meeting. The latest is \u{201C}Northwind weekly\u{201D} today.")
        #expect(SiriSpeech.actionItems([], mine: true) == "You have no open action items in LidIA.")
        let record = meeting("Sync", day(1))
        #expect(SiriSpeech.summary(record: record, content: nil, items: [], blockedMessage: "Blocked.") == "Blocked.")
        let spoken = SiriSpeech.summary(record: record, content: SiriMeetingContent(summary: "- One\n- Two", decisions: ["Ship it"]), items: [], blockedMessage: nil)
        #expect(spoken.contains("One; Two"))
        #expect(spoken.contains("Decided: Ship it."))
    }

    @Test("Mac Ask answer for Siri: no markdown or citation ids, sources named")
    func spokenAnswer() {
        let answer = MacSiriHost.spokenAnswer("**Yes** [a1b2c3d4], they agreed.\n- Pilot in May [1]", sources: ["Northwind weekly", "Northwind weekly", "Sync"], hasPendingChanges: true)
        #expect(!answer.contains("**"))
        #expect(!answer.contains("[a1b2c3d4]"))
        #expect(answer.contains("From: Northwind weekly; Sync"))
        #expect(answer.contains("confirm"))
        #expect(MacSiriHost.clock(65) == "1:05")
        #expect(MacSiriHost.clock(3_725) == "1:02:05")
        #expect(MacSiriHost.appending("- b", to: "- a\n\n") == "- a\n- b")
        #expect(MacSiriHost.appending("- b", to: "") == "- b")
    }

    @Test("Settings search finds the Siri setting")
    func settingsSearch() {
        #expect(SettingsSearchIndex.search("siri").first?.anchor == .siriContent)
        #expect(SettingsSearchIndex.search("apple intelligence").contains { $0.anchor == .siriContent })
    }
}

// MARK: - Intents against an in-memory library

@MainActor
private final class TestHost: LidIASiriHost {
    var userName = "Alex Moreno"
    var asked: [String] = []
    var opened: [UUID] = []
    func openMeeting(id: UUID) async throws { opened.append(id) }
    func ask(_ question: String) async throws -> String {
        asked.append(question)
        return "Answer"
    }
}

@MainActor
private func makeLibrary() throws -> (ModelContainer, Meeting, ActionItem, TestHost) {
    let container = try ModelContainer(
        for: LidIASchema.schema,
        configurations: [ModelConfiguration(schema: LidIASchema.schema, isStoredInMemoryOnly: true)]
    )
    let context = container.mainContext
    let meeting = Meeting(
        title: "Northwind weekly", date: day(12), summary: "## Pricing\n- Pilot price agreed at 42k\n## Decisions\n- Start in May",
        status: .complete, calendarAttendees: ["Mateo K <mateo.k@northwind.example>", "Alex Moreno <alex@harborcloud.example>"],
        notes: "Private note", folder: "Northwind"
    )
    let item = ActionItem(title: "Send the proposal", assignee: "Alex")
    context.insert(meeting)
    context.insert(item)
    item.meeting = meeting
    meeting.actionItems.append(item)
    try context.save()
    let host = TestHost()
    LidIASiri.configure(container: container, host: host)
    LidIASiri.parsePeople = SiriDefaults.parsePeople
    LidIASiri.projectOfFolder = SiriDefaults.project(ofFolder:)
    SiriDonations.isEnabled = false
    return (container, meeting, item, host)
}

/// Both Siri settings, restored afterwards.
@MainActor
private func withSiriPolicy(localOnly: Bool, readsContent: Bool, _ body: () async throws -> Void) async rethrows {
    let restore = saveDefaults([SiriContentPolicy.readsContentKey])
    defer { restore() }
    UserDefaults.standard.set(readsContent, forKey: SiriContentPolicy.readsContentKey)
    try await withLocalOnly(localOnly) { try await body() }
}

// Part of the serialized Local-only suite: it flips the same global settings.
extension LocalOnlyModeTests {
    @Test("Siri: summary intent reads content only when allowed, and asks to authenticate")
    func siriSummaryGate() async throws {
        let (_, meeting, _, _) = try makeLibrary()
        let entity = MeetingEntity(record: SiriStore.record(meeting))
        #expect(GetMeetingSummaryIntent.authenticationPolicy == .requiresAuthentication)
        #expect(AskLidIAIntent.authenticationPolicy == .requiresAuthentication)

        try await withSiriPolicy(localOnly: false, readsContent: true) {
            let result = try await GetMeetingSummaryIntent(meeting: entity).perform()
            #expect(result.value?.contains("42k") == true)
            #expect(result.value?.contains("Start in May") == true)
        }
        try await withSiriPolicy(localOnly: true, readsContent: true) {
            let value = try await GetMeetingSummaryIntent(meeting: entity).perform().value ?? ""
            #expect(!value.contains("42k"))
            #expect(!value.contains("Private note"))
            #expect(value.contains("Northwind weekly"))
            #expect(value.contains("Send the proposal"))
            #expect(value.contains("Local-only"))
        }
        try await withSiriPolicy(localOnly: false, readsContent: false) {
            let value = try await GetMeetingSummaryIntent(meeting: entity).perform().value ?? ""
            #expect(!value.contains("42k"))
        }
    }

    @Test("Siri: Ask is never called when content is blocked")
    func siriAskGate() async throws {
        let (_, _, _, host) = try makeLibrary()
        try await withSiriPolicy(localOnly: true, readsContent: true) {
            let value = try await AskLidIAIntent(question: "What did we agree?").perform().value
            #expect(value?.contains("Local-only") == true)
        }
        #expect(host.asked.isEmpty)
        try await withSiriPolicy(localOnly: false, readsContent: true) {
            let value = try await AskLidIAIntent(question: " What did we agree? ").perform().value
            #expect(value == "Answer")
        }
        #expect(host.asked == ["What did we agree?"])
    }

    @Test("Siri: the recap handed to Mail follows the policy")
    func siriRecapTransfer() async throws {
        let (_, meeting, _, _) = try makeLibrary()
        try await withSiriPolicy(localOnly: true, readsContent: true) {
            let text = try await SiriContentAccess.recap(meetingID: meeting.id, html: false)
            #expect(!text.contains("42k"))
            #expect(text.contains("Mateo K"))
            #expect(try await SiriContentAccess.summaryText(meetingID: meeting.id)?.contains("Local-only") == true)
        }
        try await withSiriPolicy(localOnly: false, readsContent: true) {
            let html = try await SiriContentAccess.recap(meetingID: meeting.id, html: true)
            #expect(html.contains("Pilot price agreed at 42k"))
            #expect(html.contains("<h3>Decisions</h3>"))
        }
    }

    @Test("Siri: find, list, add and complete work in Local-only mode (titles only)")
    func siriLibraryIntents() async throws {
        let (container, meeting, item, host) = try makeLibrary()
        try await withSiriPolicy(localOnly: true, readsContent: true) {
            let found = try await FindMeetingsIntent(keyword: "pilot").perform().value ?? []
            #expect(found.map(\.id) == [meeting.id])
            #expect(found.first?.attendees == ["Mateo K"])
            #expect(found.first?.project == "Northwind")

            let list = ListActionItemsIntent()
            list.owner = .mine
            list.person = nil
            list.project = nil
            list.meeting = MeetingEntity(record: SiriStore.record(meeting))
            list.dueBy = nil
            list.includeDone = false
            let mine = try await list.perform().value ?? []
            #expect(mine.map(\.title) == ["Send the proposal"])
            #expect(mine.first?.meeting?.id == meeting.id)

            let added = try await AddActionItemIntent(itemTitle: "Book the demo", meeting: found.first, owner: " ", dueDate: day(20)).perform().value
            #expect(added?.owner == nil)
            #expect(added?.meetingTitle == "Northwind weekly")
            #expect(meeting.actionItems.count == 2)

            let done = try await CompleteActionItemIntent(item: ActionItemEntity.make(item)).perform().value
            #expect(done?.status == .done)
            #expect(item.isCompleted)

            _ = try await OpenMeetingIntent(target: found[0]).perform()
            #expect(host.opened == [meeting.id])
        }
        _ = container
    }

    @Test("Siri: entity queries by id, words and suggestions")
    func siriQueries() async throws {
        let (_, meeting, item, _) = try makeLibrary()
        #expect(try await MeetingEntityQuery().entities(for: [meeting.id]).map(\.title) == ["Northwind weekly"])
        #expect(try await MeetingEntityQuery().entities(matching: "mateo").count == 1)
        #expect(try await ActionItemEntityQuery().entities(matching: "proposal").map(\.id) == [item.id])
        #expect(try await ActionItemEntityQuery().suggestedEntities().map(\.id) == [item.id])
        let people = try await PersonEntityQuery().allEntities()
        #expect(people.map(\.name) == ["Mateo K"])
        #expect(try await ProjectEntityQuery().entities(matching: "north").map(\.name) == ["Northwind"])
    }

    @Test("Siri: the privacy list names Siri and what it gets")
    func siriDisclosure() async {
        let restore = saveDefaults([SiriContentPolicy.readsContentKey])
        defer { restore() }
        await withLocalOnly(false) {
            let settings = AppSettings()
            settings.siriReadsMeetingContent = true
            #expect(PrivacyDisclosure(settings: settings).items.first { $0.id == "siri" }?.detail.contains("summaries") == true)
            settings.siriReadsMeetingContent = false
            #expect(PrivacyDisclosure(settings: settings).items.first { $0.id == "siri" }?.detail.contains("stay here") == true)
            settings.localOnlyMode = true
            #expect(PrivacyDisclosure(settings: settings).items.first { $0.id == "siri" }?.status == .blockedByLocalOnly)
        }
    }
}
