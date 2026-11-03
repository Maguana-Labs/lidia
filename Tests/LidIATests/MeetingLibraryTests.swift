import Foundation
import Testing
@testable import LidIA

// MARK: - Attendee parsing

@Suite struct AttendeeParserTests {
    @Test func plainEmailBecomesName() {
        let parsed = AttendeeParser.parseEntry("daniel.r@northwind.example")
        #expect(parsed.map(\.name) == ["Daniel R"])
        #expect(parsed.first?.email == "daniel.r@northwind.example")
        #expect(parsed.first?.company == "Northwind")
    }

    @Test func nameWithMatchingEmail() {
        let parsed = AttendeeParser.parseEntry("Alex Moreno <alex@harborcloud.example>")
        #expect(parsed.count == 1)
        #expect(parsed.first?.name == "Alex Moreno")
        #expect(parsed.first?.email == "alex@harborcloud.example")
        #expect(parsed.first?.company == "Harborcloud")
    }

    /// Older Granola imports paired the note creator's name with another person's email.
    @Test func mismatchedNameAndEmailAreTwoPeople() {
        let parsed = AttendeeParser.parseEntry("Alex Moreno <daniel.r@northwind.example>")
        #expect(parsed.map(\.name) == ["Alex Moreno", "Daniel R"])
        #expect(parsed.first?.email == nil)
        #expect(parsed.last?.email == "daniel.r@northwind.example")
    }

    @Test func granolaListWithCompaniesAndEmoji() {
        let parsed = AttendeeParser.parseEntry(
            "Alex Moreno from Harborcloud, Nadia Petrenko 🇺🇦 from Harborcloud, Ivo, Oliver Grant <mila.horvat@harborcloud.example>"
        )
        #expect(parsed.map(\.name) == ["Alex Moreno", "Nadia Petrenko", "Ivo", "Oliver Grant", "Mila Horvat"])
        #expect(parsed[0].company == "Harborcloud")
        #expect(parsed[1].company == "Harborcloud")
        #expect(parsed[2].company == nil)
        #expect(parsed[4].email == "mila.horvat@harborcloud.example")
    }

    @Test func noteCreatorParentheticalIsDropped() {
        let parsed = AttendeeParser.parseEntry("Alex Moreno (note creator) from Harborcloud (alex@harborcloud.example)")
        #expect(parsed.count == 1)
        #expect(parsed.first?.name == "Alex Moreno")
        #expect(parsed.first?.company == "Harborcloud")
        #expect(parsed.first?.email == "alex@harborcloud.example")
    }

    @Test func personalDomainsHaveNoCompany() {
        #expect(AttendeeParser.parseEntry("someone@gmail.com").first?.company == nil)
    }

    @Test func currentUserIsYouAndFirst() {
        let attendees = AttendeeParser.parse(
            ["felix.s@northwind.example", "alex@harborcloud.example", "Alex Moreno <leo@harborcloud.test>"],
            currentUserName: "Alex"
        )
        #expect(attendees.first?.isCurrentUser == true)
        #expect(attendees.first?.displayName == "You")
        // The bare email and the full name are the same person: one "You".
        #expect(attendees.filter(\.isCurrentUser).count == 1)
        #expect(attendees.first?.name == "Alex Moreno")
        #expect(attendees.first?.email == "alex@harborcloud.example")
        #expect(attendees.map(\.name).contains("Leo"))
    }

    @Test func duplicatesMerge() {
        let attendees = AttendeeParser.parse(["Leo", "leo@harborcloud.test", "leo@harborcloud.test"])
        #expect(attendees.count == 1)
        #expect(attendees.first?.email == "leo@harborcloud.test")
    }

    @Test func groupingPutsOutsideCompaniesFirst() {
        let attendees = AttendeeParser.parse(
            ["alex@harborcloud.example", "nadia@harborcloud.example", "felix.s@northwind.example", "daniel.r@northwind.example", "hugo.s@northwind.example", "Ivo"],
            currentUserName: "Alex"
        )
        let groups = AttendeeGrouping.byCompany(attendees)
        #expect(groups.map(\.title) == ["Northwind", "Harborcloud", "Others"])
        #expect(groups[0].attendees.count == 3)
        #expect(AttendeeGrouping.externalCompanies(attendees) == ["Northwind"])
    }
}

// MARK: - Library: series, filters, sections

private struct Item: MeetingLibraryItem {
    var libraryID = UUID()
    var title: String
    var date: Date
    var status: MeetingStatus = .complete
    var librarySource: MeetingSource = .recorded
    var libraryAttendees: [MeetingAttendee] = []
    var librarySearchText: String = ""
}

private let gregorian: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ month: Int, _ day: Int, hour: Int = 10) -> Date {
    gregorian.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

@Suite struct MeetingLibraryModelTests {
    @Test func seriesKeyNormalisesTitles() {
        let a = MeetingLibraryModel.seriesKey(for: "Northwind x Harborcloud - SaaS Platform on AWS")
        let b = MeetingLibraryModel.seriesKey(for: "northwind x harborcloud – SaaS Platform on AWS ")
        let c = MeetingLibraryModel.seriesKey(for: "Northwind x Harborcloud - SaaS Platform on AWS (Oct 28)")
        #expect(a != nil)
        #expect(a == b)
        #expect(a == c)
        #expect(MeetingLibraryModel.seriesKey(for: "Engineering - WBR") != a)
    }

    @Test func genericTitlesNeverFormASeries() {
        #expect(MeetingLibraryModel.seriesKey(for: "New Note") == nil)
        #expect(MeetingLibraryModel.seriesKey(for: "Untitled") == nil)
        #expect(MeetingLibraryModel.seriesKey(for: "") == nil)
    }

    @Test func recurringTitlesGroupIntoSeries() {
        let items = [
            Item(title: "Engineering - WBR", date: day(9, 22)),
            Item(title: "Northwind x Harborcloud - SaaS Platform on AWS", date: day(10, 5)),
            Item(title: "Engineering - WBR", date: day(9, 29)),
            Item(title: "Leo / Alex", date: day(10, 21)),
            Item(title: "Northwind x Harborcloud - SaaS Platform on AWS", date: day(10, 28)),
            Item(title: "New Note", date: day(10, 30)),
            Item(title: "New Note", date: day(10, 31)),
        ]
        let entries = MeetingLibraryModel.entries(items, groupSeries: true)
        // Newest first: New Note, New Note, Northwind series (latest Oct 28), Leo, WBR series.
        #expect(entries.count == 5)
        guard case .series(let northwind) = entries[2] else {
            Issue.record("Expected the Northwind series third")
            return
        }
        #expect(northwind.count == 2)
        #expect(northwind.latestDate == day(10, 28))
        #expect(northwind.items.map(\.date) == [day(10, 28), day(10, 5)])
        guard case .series(let wbr) = entries[4] else {
            Issue.record("Expected the WBR series last")
            return
        }
        #expect(wbr.count == 2)

        let flat = MeetingLibraryModel.entries(items, groupSeries: false)
        #expect(flat.count == items.count)
        #expect(MeetingLibraryModel.series(items).count == 2)
    }

    @Test func cadence() {
        let weekly = (0..<4).map { gregorian.date(byAdding: .day, value: 7 * $0, to: day(9, 1))! }
        #expect(MeetingLibraryModel.cadence(of: weekly) == "Weekly")
        let biweekly = (0..<4).map { gregorian.date(byAdding: .day, value: 14 * $0, to: day(9, 1))! }
        #expect(MeetingLibraryModel.cadence(of: biweekly) == "Every 2 weeks")
        #expect(MeetingLibraryModel.cadence(of: [day(9, 1), day(9, 3), day(10, 20)]) == nil)
        #expect(MeetingLibraryModel.cadence(of: [day(9, 1), day(9, 8)]) == nil)
    }

    @Test func sectionLabels() {
        let now = day(11, 3, hour: 12)
        #expect(MeetingLibraryModel.sectionLabel(for: day(11, 3), now: now, calendar: gregorian) == "Today")
        #expect(MeetingLibraryModel.sectionLabel(for: day(11, 2), now: now, calendar: gregorian) == "Yesterday")
        #expect(MeetingLibraryModel.sectionLabel(for: day(10, 30), now: now, calendar: gregorian) == "Previous 7 Days")
        #expect(MeetingLibraryModel.sectionLabel(for: day(11, 10), now: now, calendar: gregorian) == "Upcoming")
        let sections = MeetingLibraryModel.sections(
            [day(11, 3), day(11, 2), day(10, 1), day(10, 2)],
            date: { $0 }, now: now, calendar: gregorian
        )
        #expect(sections.count == 3)
        #expect(sections.last?.entries.count == 2)
    }
}

@Suite struct MeetingLibraryFilterTests {
    private let daniel = MeetingAttendee(name: "Daniel R", email: "daniel.r@northwind.example", company: "Northwind")
    private let victor = MeetingAttendee(name: "Victor", email: "victor@pinecrest.example", company: "Pinecrest")

    private var items: [Item] {
        [
            Item(title: "Northwind x Harborcloud", date: day(10, 28), librarySource: .imported, libraryAttendees: [daniel], librarySearchText: "Textract pricing"),
            Item(title: "TAPR call [Pinecrest]", date: day(10, 20), librarySource: .recorded, libraryAttendees: [victor]),
            Item(title: "Groceries", date: day(6, 1), librarySource: .note),
        ]
    }

    private func titles(_ filter: MeetingLibraryFilter) -> [String] {
        items.filter { filter.matches($0, now: day(11, 3)) }.map(\.title)
    }

    @Test func emptyFilterMatchesEverything() {
        #expect(titles(MeetingLibraryFilter()).count == 3)
        #expect(!MeetingLibraryFilter().isActive)
    }

    @Test func queryMatchesTitlePeopleAndText() {
        var filter = MeetingLibraryFilter()
        filter.query = "daniel"
        #expect(titles(filter) == ["Northwind x Harborcloud"])
        filter.query = "textract"
        #expect(titles(filter) == ["Northwind x Harborcloud"])
        filter.query = "pinecrest call"
        #expect(titles(filter) == ["TAPR call [Pinecrest]"])
        filter.query = "nothing like this"
        #expect(titles(filter).isEmpty)
    }

    @Test func peopleCompanySourceAndDate() {
        var filter = MeetingLibraryFilter()
        filter.people = [victor.id]
        #expect(titles(filter) == ["TAPR call [Pinecrest]"])

        filter = MeetingLibraryFilter()
        filter.companies = ["Northwind"]
        #expect(titles(filter) == ["Northwind x Harborcloud"])

        filter = MeetingLibraryFilter()
        filter.sources = [.note, .recorded]
        #expect(titles(filter) == ["TAPR call [Pinecrest]", "Groceries"])

        filter = MeetingLibraryFilter()
        filter.dateRange = .month
        #expect(titles(filter) == ["Northwind x Harborcloud", "TAPR call [Pinecrest]"])
        #expect(filter.hasFilters)
    }

    @Test func sourceOfAMeeting() {
        #expect(MeetingSource.of(externalSourceID: "granola:123", hasAudioOrTranscript: false) == .imported)
        #expect(MeetingSource.of(externalSourceID: nil, hasAudioOrTranscript: true) == .recorded)
        #expect(MeetingSource.of(externalSourceID: nil, hasAudioOrTranscript: false) == .note)
        #expect(MeetingSource.importerName("granola:62f3") == "Granola")
        #expect(MeetingSource.importerName(nil) == nil)
    }
}

// MARK: - Transcript chat

@Suite struct TranscriptChatModelTests {
    @Test func parsesImportedTranscriptLines() {
        let text = """
        [0:00] System audio (Leo Novak): Hello, Alex.

        [0:00] Microphone: Hi.

        [0:02] Microphone: How are you?

        [0:12] System audio (Leo Novak): Nice jumper.
        """
        let bubbles = TranscriptChatModel.bubbles(fromText: text, localNames: ["Alex"])
        #expect(bubbles.count == 3)
        #expect(bubbles[0].speaker == "Leo Novak")
        #expect(bubbles[0].isLocal == false)
        #expect(bubbles[1].speaker == "You")
        #expect(bubbles[1].isLocal)
        // Consecutive lines from the same speaker merge.
        #expect(bubbles[1].text == "Hi. How are you?")
        #expect(bubbles[2].start == 12)
    }

    @Test func plainTextBecomesParagraphs() {
        let bubbles = TranscriptChatModel.bubbles(fromText: "first paragraph\n\nsecond paragraph")
        #expect(bubbles.map(\.text) == ["first paragraph", "second paragraph"])
        #expect(bubbles.allSatisfy { $0.speaker == nil })
    }

    @Test func timestamps() {
        #expect(TranscriptChatModel.seconds("1:02") == 62)
        #expect(TranscriptChatModel.seconds("1:02:03") == 3723)
        #expect(TranscriptChatModel.parseLine("[10:05] Speaker 2: ok")?.speaker == "Speaker 2")
    }

    @Test func search() {
        let bubbles = TranscriptChatModel.bubbles(fromText: "[0:01] Me: Textract pricing\n[0:05] Them: OK")
        #expect(TranscriptChatModel.matchingIndices(in: bubbles, query: "textract") == [0])
        #expect(TranscriptChatModel.matchingIndices(in: bubbles, query: " ").isEmpty)
    }
}

// MARK: - Pill and summary preview

@Suite struct RecordingPillStateTests {
    @Test func warningsArePlainSentences() {
        #expect(RecordingPillState.warning(quality: .good, micOnly: false, fallbackReason: nil) == nil)
        #expect(RecordingPillState.warning(quality: .noInput, micOnly: true, fallbackReason: nil)?.contains("microphone") == true)
        #expect(RecordingPillState.warning(quality: .good, micOnly: true, fallbackReason: "Screen Recording is off")?.hasSuffix(".") == true)
        // Microphone only by choice: nothing to warn about.
        #expect(RecordingPillState.warning(quality: .good, micOnly: true, fallbackReason: nil) == nil)
    }

    @Test func linesGroupBySpeakerAndKeepTheLatest() {
        var words: [TranscriptWord] = []
        for index in 0..<10 {
            let start = Double(index) * 5
            words.append(TranscriptWord(word: "w\(index)", start: start, end: start + 0.4, confidence: 1, speaker: nil, speakerName: nil, isLocalSpeaker: index.isMultiple(of: 2)))
        }
        let lines = RecordingPillState.lines(from: words, limit: 3)
        #expect(lines.count == 3)
        #expect(lines.last?.text == "w9")
    }

    @Test func summaryPreviewStripsMarkdown() {
        let preview = SummaryPreview.lines(from: "# Context\n\n- **Demo** of Frame\n- \\~12 TAPRs/month\n---\n- third", limit: 2)
        #expect(preview == ["Demo of Frame", "~12 TAPRs/month"])
    }
}
