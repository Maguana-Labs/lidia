import Foundation
import Testing
@testable import LidIA

/// Intents: kind, direction/owner, evidence, free slots, destinations.
/// Fixtures are a made-up Northwind call about stacked PRs (docs/fictional-cast.md).
@Suite("Intents")
struct IntentTests {
    static let user = "Alex Moreno"
    static let attendees = AttendeeParser.parse(
        ["mateo.k@northwind.example", "daniel.r@northwind.example", "felix.s@northwind.example", "alex@harborcloud.example", "nadia@harborcloud.example"],
        currentUserName: user
    )

    /// Speaker turns as the pipeline labels them (mic = "Me").
    static let turns: [TranscriptTurn] = [
        .init(speaker: "Them", isUser: false, start: 1, text: "this is my teammate, the one who rebuilt the prototype over the weekend"),
        .init(speaker: "Me", isUser: true, start: 33, text: "let me share my screen, probably would be good to share the git help so you could see the code which I had here. I'm creating stacked PRs"),
        .init(speaker: "Me", isUser: true, start: 109, text: "in the repository I have opened one PR per change and they are stacked so they are not overlapping"),
        .init(speaker: "Them", isUser: false, start: 200, text: "Nico, can you please uh explain a little bit more about uh stacking the PRs. I know GitHub very little"),
        .init(speaker: "Me", isUser: true, start: 230, text: "it's a fairly new workflow, you can split a change into smaller PRs and stack them"),
        .init(speaker: "Me", isUser: true, start: 1000, text: "I'm going to share this one with you. And I will also share a diagram for you to take a look at it"),
    ]

    // MARK: Classification

    @Test(arguments: [
        ("Explain the stacking process to the Northwind team", ActionIntent.Kind.message),
        ("Send recap to Mateo", .message),
        ("Attempt to reschedule Friday meeting", .schedule),
        ("Move the Monday demo to Tuesday", .schedule),
        ("Fix the HTTPS routing bug in ECS", .ticket),
        ("Open a ticket for the Terraform state lock", .ticket),
        ("Share Git history for Alex's visibility into code structure", .document),
        ("Write a doc on the landing zone", .document),
        ("Investigate Aurora pricing for the EU region", .research),
        ("Remember to take Friday off", .reminder),
        ("Bananas", .unclear),
    ])
    func classifiesKind(_ title: String, _ expected: ActionIntent.Kind) {
        #expect(IntentClassifier.kind(title: title) == expected)
    }

    // MARK: Direction and owner

    @Test func someoneAskingTheUserFlipsTheDirection() {
        let resolution = OwnerResolver.resolve(.init(
            title: "Explain the stacking process to Alex", assignee: "Alex",
            userName: Self.user, attendees: Self.attendees, evidence: Self.turns[3]
        ))
        #expect(resolution.direction == .userOwes)
        #expect(resolution.ownerIsUser)
        #expect(resolution.recipientLabel == "the Northwind team")
        #expect(resolution.suggestedTitle == "Explain the stacking process to the Northwind team")
        #expect(resolution.recipients.allSatisfy { $0.email?.hasSuffix("@northwind.example") == true })
    }

    @Test func aNamedAskerBecomesTheRecipient() {
        let turn = TranscriptTurn(speaker: "Mateo", isUser: false, start: 10, text: "Alex could you send me the deck")
        let resolution = OwnerResolver.resolve(.init(title: "Send the deck to Alex", assignee: nil, userName: Self.user, attendees: Self.attendees, evidence: turn))
        #expect(resolution.ownerIsUser)
        #expect(resolution.recipients.first?.email == "mateo.k@northwind.example")
        #expect(resolution.suggestedTitle == "Send the deck to Mateo")
    }

    @Test func theUsersOwnPromiseIsTheirs() {
        let resolution = OwnerResolver.resolve(.init(title: "Share a diagram", assignee: nil, userName: Self.user, attendees: Self.attendees, evidence: Self.turns[5]))
        #expect(resolution.direction == .userOwes)
        #expect(resolution.cue == "You said you'd do it")
        #expect(resolution.suggestedTitle == nil)
    }

    @Test func someoneElsesPromiseIsOwedToTheUser() {
        let turn = TranscriptTurn(speaker: "Daniel", isUser: false, start: 5, text: "I'll send the IAM policy tomorrow")
        let resolution = OwnerResolver.resolve(.init(title: "Send the IAM policy", assignee: nil, userName: Self.user, attendees: Self.attendees, evidence: turn))
        #expect(resolution.direction == .othersOweUser)
        #expect(!resolution.ownerIsUser)
        #expect(resolution.owner == "daniel.r@northwind.example" || resolution.owner?.lowercased().hasPrefix("daniel") == true)
    }

    @Test func selfWordsAndAssigneesResolve() {
        #expect(OwnerResolver.isUser("Me", userName: Self.user))
        #expect(OwnerResolver.isUser("User", userName: Self.user))
        #expect(OwnerResolver.isUser("Alex", userName: Self.user))
        #expect(!OwnerResolver.isUser("Mateo", userName: Self.user))
        let other = OwnerResolver.resolve(.init(title: "Review the IAM policy", assignee: "Mateo", userName: Self.user, attendees: Self.attendees, evidence: nil))
        #expect(other.direction == .othersOweUser)
        #expect(other.recipientLabel == "Mateo")
    }

    // MARK: Evidence

    @Test func findsTheRequestForTheStackedPRItem() throws {
        let match = try #require(EvidenceMatcher.matches(for: "Explain the stacking process to Alex", in: Self.turns, exclude: [Self.user, "Alex"]).first)
        #expect(match.turn.start == 200)
        #expect(match.quote.contains("explain"))
        #expect(!match.quote.contains(" uh "), "fillers are dropped")
        #expect(EvidenceMatcher.verdict(for: match.score) == .supported)
    }

    @Test func anInventedItemIsNotSupported() {
        let best = EvidenceMatcher.matches(for: "Prepare the quarterly budget forecast", in: Self.turns).first
        #expect(EvidenceMatcher.verdict(for: best?.score) == .notFound)
    }

    @Test func aLooseMatchIsOnlyWeak() {
        // "share the git help so you could see the code" is near, but not the item.
        let best = EvidenceMatcher.matches(for: "Share Git history for Alex's visibility into code structure", in: Self.turns, exclude: [Self.user, "Alex"]).first
        #expect(EvidenceMatcher.verdict(for: best?.score) != .supported)
    }

    @Test func crosstalkFragmentsAreFoldedIntoWholeTurns() {
        let words: [TranscriptWord] = [
            ("Nico,", false, 200.0), ("here.", true, 201.0), ("can", false, 201.5), ("you", false, 201.6), ("please", false, 201.7),
            ("explain", false, 202.0), ("stacking", false, 202.5), ("Yeah,", true, 203.0), ("this", true, 203.1), ("is", true, 203.2),
            ("new", true, 203.3), ("stuff", true, 203.4), ("from", true, 203.5), ("GitHub", true, 203.6),
        ].map { TranscriptWord(word: $0.0, start: $0.2, end: $0.2 + 0.3, confidence: 1, isLocalSpeaker: $0.1) }
        let turns = TranscriptTimeline.turns(from: words, userName: Self.user)
        #expect(turns.contains { $0.speaker == "Them" && $0.text.hasPrefix("Nico, can you please explain") })
    }

    @Test func importedTranscriptsKeepSpeakersAndTimes() {
        let text = """
            [3:41] System audio (Mateo Kovačević): Alex, how are you?

            [3:47] Microphone: I'm good, I'll send the diagram later today.
            [1:02:05] Daniel: Plain label line
            """
        let turns = TranscriptTimeline.turns(fromText: text, userName: Self.user)
        #expect(turns[0].speaker == "Mateo Kovačević")
        #expect(turns[0].isUser == false)
        #expect(turns[0].start == 221)
        #expect(turns[1].isUser == true)
        #expect(turns[1].start == 227)
        #expect(turns.count == 3 && turns[2].start == 3725)
        #expect(turns.count == 3 && turns[2].speaker == "Daniel")
    }

    @MainActor
    @Test func importedItemsAreNotFlaggedForReview() {
        let input = IntentInput(
            itemID: UUID(), meetingID: UUID(), title: "Prepare the quarterly budget forecast", assignee: nil,
            meetingTitle: "Imported", meetingDate: .now, attendees: Self.attendees, turns: Self.turns, userName: Self.user,
            summary: "", verification: nil, hasTimedTranscript: false
        )
        let intent = IntentBuilder.build(input, connections: IntentConnections())
        let store = IntentStore(url: nil)
        store.setIntent(intent)
        #expect(intent.verdict == .notFound)
        #expect(store.needsReview(intent.itemID) == nil)
        #expect(intent.primaryLabel != "Review")
    }

    @Test func evidenceSaysWhenItWasSaid() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let match = EvidenceMatcher.matches(for: "explain stacking", in: Self.turns)[0]
        let evidence = IntentBuilder.evidence(match, meetingDate: start)
        #expect(evidence.offsetLabel == "3:20")
        #expect(evidence.spokenAt == start.addingTimeInterval(200))
        #expect(evidence.saidLabel().contains("by Them"))
    }

    // MARK: Free slots

    @MainActor
    @Test func findsFreeSlotsAroundBusyTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        // Tue 3 Nov, now 14:00. Friday 6 Nov holds the meeting to move.
        let now = at(3, 14)
        let events = [
            IntentCalendarEvent(id: "fri", title: "Partner sync", start: at(6, 11), end: at(6, 12), attendees: ["a@x.com", "b@y.com"], source: "apple", editable: true),
            IntentCalendarEvent(id: "wed-busy", title: "Focus", start: at(4, 9), end: at(4, 13), source: "apple", editable: true),
            IntentCalendarEvent(id: "thu-busy", title: "Standup", start: at(5, 11), end: at(5, 11, 30), source: "apple", editable: true),
            IntentCalendarEvent(id: "holiday", title: "Holiday", start: at(9, 0), end: at(10, 0), isAllDay: true, source: "apple", editable: false),
        ]
        let proposal = IntentBuilder.calendarProposal(title: "Attempt to reschedule Friday meeting", quote: nil, events: events, now: now, calendar: calendar)
        #expect(proposal.eventID == "fri")
        #expect(proposal.editable)
        #expect(proposal.slots.count == 3)
        for slot in proposal.slots {
            #expect(slot.end.timeIntervalSince(slot.start) == 3600)
            #expect(!calendar.isDate(slot.start, inSameDayAs: at(6, 0)), "never the day being freed")
            #expect(!calendar.isDateInWeekend(slot.start))
            for event in events where !event.isAllDay && event.id != "fri" {
                #expect(!(slot.start < event.end && slot.end > event.start), "overlaps \(event.title)")
            }
        }
        // Closest to the original 11:00 first: Wednesday's morning is busy, so 13:00.
        #expect(proposal.slots[0].start == at(4, 13))
        #expect(proposal.slots[1].start == at(5, 11, 30))
    }

    @Test func noFreeTimeMeansNoSlots() {
        let day = Date(timeIntervalSince1970: 1_793_000_000)
        let busy = [DateInterval(start: day.addingTimeInterval(-86_400 * 3), end: day.addingTimeInterval(86_400 * 10))]
        #expect(SlotFinder.freeSlots(busy: busy, duration: 1800, from: day, to: day.addingTimeInterval(86_400 * 7)).isEmpty)
    }

    @MainActor
    @Test func googleOnlyEventsAreReadOnly() {
        let now = Date()
        let friday = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 11, weekday: 6), matchingPolicy: .nextTime)!
        let events = [IntentCalendarEvent(id: "g1", title: "Partner sync", start: friday, end: friday.addingTimeInterval(1800), attendees: ["a@x.com"], source: "google", editable: false)]
        let proposal = IntentBuilder.calendarProposal(title: "Reschedule Friday meeting", quote: nil, events: events, now: now, calendar: .current)
        #expect(!proposal.editable)
        #expect(proposal.note?.contains("Google Calendar") == true)
    }

    // MARK: Destinations

    @Test func ticketsGoToTheConnectedTrackerNeverToYourself() {
        var connections = IntentConnections(linear: true, mail: .gmail)
        var ranked = IntentDestinationRanker.rank(kind: .ticket, title: "Fix the HTTPS routing bug", recipientsAreExternal: false, connections: connections)
        #expect(ranked.first?.id == "linear")
        connections = IntentConnections(clickUp: true, linear: true, mail: .gmail, history: ["clickup": 6])
        ranked = IntentDestinationRanker.rank(kind: .ticket, title: "Order new laptops", recipientsAreExternal: false, connections: connections)
        #expect(ranked.first?.id == "clickup")
        #expect(ranked.first?.reason == "ClickUp · you've sent 6 items there")
    }

    @Test func anUnconnectedBestDestinationAsksToConnect() {
        let ranked = IntentDestinationRanker.rank(kind: .ticket, title: "Fix the deploy pipeline", recipientsAreExternal: false, connections: IntentConnections(mail: .appleMail))
        #expect(ranked.first?.id == "linear")
        #expect(ranked.first?.configured == false)
        #expect(IntentDestinationRanker.primaryLabel(kind: .ticket, direction: .userOwes, destination: ranked.first, recipientLabel: nil) == "Connect Linear…")
    }

    @Test func messagesUseTheUsersMailAndSlackForColleagues() {
        let gmail = IntentDestinationRanker.rank(kind: .message, title: "Explain stacked PRs", recipientsAreExternal: true, connections: IntentConnections(slack: true, mail: .gmail))
        #expect(gmail.map(\.id) == ["gmail", "slack"])
        let internalTeam = IntentDestinationRanker.rank(kind: .message, title: "Tell Nadia", recipientsAreExternal: false, connections: IntentConnections(slack: true, mail: .gmail))
        #expect(internalTeam.first?.id == "slack")
        let docs = IntentDestinationRanker.rank(kind: .document, title: "Write a doc on the landing zone", recipientsAreExternal: true, connections: IntentConnections(notionPages: true))
        #expect(docs.first?.id == "notion")
    }

    // MARK: The whole intent

    @MainActor
    @Test func buildsTheStackedPRIntent() {
        let input = IntentInput(
            itemID: UUID(), meetingID: UUID(), title: "Explain the stacking process to Alex", assignee: "Alex",
            meetingTitle: "Northwind x Harborcloud - SaaS Platform on AWS", meetingDate: Date(timeIntervalSince1970: 1_793_000_000),
            attendees: Self.attendees, turns: Self.turns, userName: Self.user,
            summary: "### GitHub\n- **Stacked PRs created**: PRs for every call are stacked in a single visual block to prevent Git conflicts\n- Terraform state in S3",
            verification: nil
        )
        let intent = IntentBuilder.build(input, connections: IntentConnections(mail: .gmail))
        #expect(intent.kind == .message)
        #expect(intent.ownerIsUser)
        #expect(intent.recipientLabel == "the Northwind team")
        #expect(intent.primaryLabel == "Email the Northwind team")
        #expect(intent.verdict == .supported)
        #expect(intent.bestEvidence?.offset == 200)
        #expect(intent.linkNote != nil, "no web search: the draft asks for a link")
        guard case .message(_, let body) = intent.artifact else { Issue.record("expected a message"); return }
        #expect(body.contains("Stacked PRs created"))
        #expect(body.contains("[add a link]"))
        #expect(!body.contains("http"), "never an invented URL")
    }

    @Test func onlySearchedLinksSurvive() {
        let results = [AgentWebResult(title: "GitHub Docs: stacked PRs", url: URL(string: "https://docs.github.com/en/pull-requests/stacked")!)]
        let (body, links) = IntentEngine.keepRealLinks(
            "See https://docs.github.com/en/pull-requests/stacked and https://made-up.example.com/guide.",
            results: results
        )
        #expect(body.contains("https://docs.github.com/en/pull-requests/stacked"))
        #expect(!body.contains("made-up"))
        #expect(body.contains("[add a link]"))
        #expect(links.map(\.url.host) == ["docs.github.com"])
    }

    // MARK: Pipeline check

    @Test func verifierCorrectsDirectionAndFlagsUnsupported() {
        let items: [MeetingSummaryResponse.ActionItemResponse] = [
            .init(title: "Explain the stacking process to Alex", assignee: "Alex", deadline: nil, sourceQuote: nil),
            .init(title: "Prepare the quarterly budget forecast", assignee: "User", deadline: nil, sourceQuote: nil),
        ]
        let result = ActionItemVerifier.verifyDeterministic(
            items, turns: Self.turns,
            attendees: ["mateo.k@northwind.example", "alex@harborcloud.example"], userName: Self.user
        )
        #expect(result.items[0].title == "Explain the stacking process to Mateo" || result.items[0].title.hasSuffix("the Northwind team"))
        #expect(result.items[0].assignee == Self.user)
        #expect(result.checks[0]?.verdict == .supported)
        #expect(result.checks[0]?.originalTitle == "Explain the stacking process to Alex")
        #expect(result.items[1].assignee == Self.user, "\"User\" is the person recording")
        #expect(result.checks[1]?.verdict == .notFound, "kept, but flagged")
        #expect(result.items.count == 2)
    }

    @Test func modelCheckCannotConjureEvidence() {
        #expect(ActionItemVerifier.combine(lexical: 0.1, model: "said") == .notFound)
        #expect(ActionItemVerifier.combine(lexical: 0.55, model: "said") == .supported)
        #expect(ActionItemVerifier.combine(lexical: 0.45, model: "done_in_meeting") == .doneInMeeting)
        #expect(ActionItemVerifier.combine(lexical: 0.45, model: "not_said") == .notFound)
    }

    @Test func summaryPromptsNameTheUser() {
        let prompt = SummaryPrompts.markdownSystemPrompt(template: nil, attendees: nil, wordCount: 500, userName: Self.user) ?? ""
        #expect(prompt.contains("The user recording this is Alex Moreno"))
        #expect(SummaryPrompts.factsSystemPrompt(userName: Self.user).contains("The user is Alex Moreno"))
        #expect(SummaryPrompts.factsSystemPrompt(userName: "") == SummaryPrompts.factsSystemPrompt)
    }

    // MARK: For You

    @MainActor
    @Test func forYouMergesDuplicatesAndNeverAddressesTicketsToYou() {
        let meetingID = UUID()
        let input = IntentInput(
            itemID: UUID(), meetingID: meetingID, title: "Explain the stacking process to Alex", assignee: "Alex",
            meetingTitle: "Northwind", meetingDate: .now, attendees: Self.attendees, turns: Self.turns, userName: Self.user, summary: "", verification: nil
        )
        let intent = IntentBuilder.build(input, connections: IntentConnections(mail: .gmail))
        let flagged = IntentBuilder.build(IntentInput(
            itemID: UUID(), meetingID: meetingID, title: "Prepare the quarterly budget forecast", assignee: nil,
            meetingTitle: "Northwind", meetingDate: .now, attendees: Self.attendees, turns: Self.turns, userName: Self.user, summary: "", verification: nil
        ), connections: IntentConnections(mail: .gmail))
        let candidates = [
            IntentSuggestions.Candidate(intent: intent, itemTitle: input.title, meetingID: meetingID, meetingDate: .now),
            IntentSuggestions.Candidate(intent: flagged, itemTitle: "Prepare the quarterly budget forecast", meetingID: meetingID, meetingDate: .now),
        ]
        let picked = IntentSuggestions.pick(candidates, followUpMeetingIDs: [])
        #expect(picked.map(\.itemTitle) == [input.title], "unsupported items aren't suggested")
        #expect(IntentSuggestions.isCoveredByIntent(actionItemTitle: "Explain the stacking process to Alex", meetingID: meetingID, intents: candidates))
        #expect(!IntentSuggestions.isCoveredByIntent(actionItemTitle: "Something else", meetingID: meetingID, intents: candidates))
        #expect(IntentSuggestions.isSelfAddressed(recipient: "alex@harborcloud.example", userName: Self.user, userEmails: []))
        #expect(!IntentSuggestions.isSelfAddressed(recipient: "mateo.k@northwind.example", userName: Self.user, userEmails: []))
    }

    // MARK: Linear

    @Test func linearRequestAndResponse() throws {
        let body = LinearClient.createIssueBody(title: "Fix routing", description: "Details", teamID: "team-1")
        let input = (body["variables"] as? [String: Any])?["input"] as? [String: String]
        #expect(input == ["title": "Fix routing", "description": "Details", "teamId": "team-1"])
        #expect((body["query"] as? String)?.contains("issueCreate(input: $input)") == true)
        let created = try LinearClient.parseCreatedIssue(["data": ["issueCreate": ["success": true, "issue": ["id": "i1", "identifier": "ENG-12", "url": "https://linear.app/x/issue/ENG-12"]]]])
        #expect(created.identifier == "ENG-12")
        #expect(throws: LinearClient.LinearError.graphQL("Team not found")) {
            try LinearClient.parseCreatedIssue(["errors": [["message": "Team not found"]]])
        }
    }

    @Test func localOnlyBlocksCloudDestinations() {
        #expect(IntentActions.isBlockedByLocalOnly("linear", localOnly: true))
        #expect(IntentActions.isBlockedByLocalOnly("gmail", localOnly: true))
        #expect(!IntentActions.isBlockedByLocalOnly("mail", localOnly: true))
        #expect(!IntentActions.isBlockedByLocalOnly("calendar", localOnly: true))
        #expect(!IntentActions.isBlockedByLocalOnly("linear", localOnly: false))
    }
}
