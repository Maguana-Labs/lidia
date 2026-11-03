import Foundation
import SwiftData
import Testing
@testable import LidIA

// MARK: - Fixtures

private let now = ISO8601DateFormatter().date(from: "2026-11-03T15:00:00Z")!

private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func people(_ raw: [String]) -> [MeetingAttendee] {
    AttendeeParser.parse(raw, currentUserName: "Alex Moreno")
}

private func meeting(
    _ title: String,
    _ attendees: [String] = [],
    daysAgo days: Double = 1,
    project: String? = nil,
    summary: String = "",
    items: [ActionItemSignal] = [],
    complete: Bool = true
) -> MeetingSignals {
    MeetingSignals(
        id: UUID(), title: title, date: daysAgo(days), project: project,
        attendees: people(attendees), summary: summary, isComplete: complete, actionItems: items
    )
}

private let northwind = ["Alex Moreno <alex@harborcloud.example>", "mateo.k@northwind.example", "daniel.r@northwind.example"]
private let internalTeam = ["Alex Moreno <alex@harborcloud.example>", "leo@harborcloud.test", "selin@harborcloud.example"]

// MARK: - Projects

@Suite struct ProjectSuggesterTests {
    @Test func homeCompanyIsTheUsersOwn() {
        let context = ProjectSuggester.Context.build([meeting("A", northwind), meeting("B", internalTeam)])
        #expect(context.homeCompanies == ["harborcloud"])
        #expect(context.homeDomains.contains("harborcloud.example"))
        #expect(context.homeDomains.contains("harborcloud.test"))
    }

    @Test func titleEntitiesSkipGenericWordsPeopleAndOwnCompany() {
        let context = ProjectSuggester.Context.build([meeting("x", internalTeam)])
        let entities = ProjectSuggester.titleEntities("Northwind x Harborcloud - SaaS Platform on AWS", context: context)
        #expect(entities.keys.contains("northwind"))
        #expect(entities.keys.contains("aws"))
        #expect(!entities.keys.contains("harborcloud"))
        #expect(!entities.keys.contains("platform"))
        #expect(ProjectSuggester.titleEntities("Alex / Leo", context: context).isEmpty)
    }

    @Test func seriesDomainAndTitleSuggestTheProject() {
        let assigned = (0..<3).map { meeting("Northwind x Harborcloud - SaaS Platform on AWS", northwind, daysAgo: Double(7 * ($0 + 1)), project: "Northwind") }
        let newest = meeting("Northwind x Harborcloud - SaaS Platform on AWS", northwind, daysAgo: 0.2)
        let suggestions = ProjectSuggester.suggestions(for: assigned + [newest])
        let suggestion = try! #require(suggestions[newest.id])
        #expect(suggestion.project == "Northwind")
        #expect(suggestion.confidence > 0.99)
        #expect(suggestion.isAutoAssignable)
        #expect(suggestion.reasons.contains { $0.contains("series") })
        #expect(suggestion.reasons.contains { $0.contains("northwind.example") })
    }

    @Test func domainAloneSuggestsButDoesNotAutoAssign() {
        let assigned = (0..<3).map { meeting("Weekly sync \($0)", northwind, daysAgo: Double($0 + 3), project: "Beacon") }
        let other = meeting("Invoice OCR deep dive", northwind)
        let suggestion = try! #require(ProjectSuggester.suggestions(for: assigned + [other])[other.id])
        #expect(suggestion.project == "Beacon")
        #expect(suggestion.confidence >= ProjectSuggester.suggestThreshold)
        #expect(!suggestion.isAutoAssignable)
    }

    @Test func unrelatedMeetingGetsNothing() {
        let assigned = [meeting("Northwind kickoff", northwind, project: "Northwind")]
        let other = meeting("Alex / Leo", internalTeam)
        #expect(ProjectSuggester.suggestions(for: assigned + [other])[other.id] == nil)
    }

    @Test func rejectedProjectIsNotSuggestedAgain() {
        let assigned = [meeting("Northwind x Harborcloud - SaaS", northwind, daysAgo: 8, project: "Northwind")]
        let other = meeting("Northwind x Harborcloud - SaaS", northwind)
        let rejected = [other.id: Set(["northwind"])]
        #expect(ProjectSuggester.suggestions(for: assigned + [other], rejected: rejected)[other.id] == nil)
    }

    @Test func ambiguousMeetingsScoreLower() {
        let a = meeting("Northwind roadmap", northwind, daysAgo: 4, project: "Northwind")
        let b = meeting("Beacon roadmap", northwind, daysAgo: 5, project: "Beacon")
        let other = meeting("Roadmap", northwind)
        let context = ProjectSuggester.Context.build([a, b, other])
        let profiles = ProjectSuggester.profiles([a, b, other], context: context)
        let suggestion = ProjectSuggester.best(for: other, profiles: profiles, context: context)
        // Both projects share the domain equally: below the auto-assign bar.
        #expect(suggestion.map { !$0.isAutoAssignable } ?? true)
    }

    @Test func clusterProposesANewProjectFromCompanyAndTitles() {
        let meetings = (0..<6).map { meeting("Northwind x Harborcloud - SaaS Platform on AWS", northwind, daysAgo: Double(7 * $0 + 1)) }
            + [meeting("Northwind x Harborcloud: Project pre kick-off", northwind, daysAgo: 40)]
            + [meeting("Alex / Leo", internalTeam), meeting("Engineering - WBR", internalTeam), meeting("Engineering - WBR", internalTeam, daysAgo: 8)]
        let clusters = ProjectSuggester.clusters(meetings)
        #expect(clusters.count == 1)
        let cluster = try! #require(clusters.first)
        #expect(cluster.name == "Northwind")
        #expect(cluster.meetingIDs.count == 7)
        #expect(cluster.confidence >= 0.9)
        #expect(cluster.reasons.contains { $0.contains("northwind.example") })
        #expect(cluster.reasons.contains { $0.hasPrefix("Recurring") })
    }

    @Test func twoMeetingsNeedCompanyAndTitleTogether() {
        let pinecrest = ["Alex Moreno from Harborcloud, Omar Haddad <victor@pinecrest.example>"]
        let pair = [meeting("TAPR call [Pinecrest]", pinecrest, daysAgo: 14), meeting("Pre-TAPR call [Pinecrest]", pinecrest, daysAgo: 33)]
        let clusters = ProjectSuggester.clusters(pair + [meeting("Alex / Leo", internalTeam)])
        #expect(clusters.map(\.name) == ["Pinecrest"])

        // A title word alone in two meetings is not a project.
        let loose = [meeting("Agentic workflows", internalTeam), meeting("Agentic strategy", internalTeam)]
        #expect(ProjectSuggester.clusters(loose).isEmpty)
    }

    @Test func clustersSkipExistingAndDismissedProjects() {
        let meetings = (0..<4).map { meeting("Northwind sync \($0)", northwind, daysAgo: Double($0 + 1)) }
        #expect(ProjectSuggester.clusters(meetings, existingProjects: ["Northwind"]).isEmpty)
        #expect(ProjectSuggester.clusters(meetings, dismissed: ["northwind"]).isEmpty)
        #expect(ProjectSuggester.clusters(meetings).map(\.name) == ["Northwind"])
    }

    @Test func importFolderIsNotAProject() {
        #expect(ProjectCatalog.project(ofFolder: "Granola") == nil)
        #expect(ProjectCatalog.project(ofFolder: "  ") == nil)
        #expect(ProjectCatalog.project(ofFolder: "Northwind") == "Northwind")
    }
}

// MARK: - Vocabulary

@Suite struct VocabularyMinerTests {
    private func doc(written: String, heard: String, title: String = "") -> VocabularyMiner.Document {
        VocabularyMiner.Document(id: UUID(), written: written, heard: heard, title: title)
    }

    @Test func spelledRightNamesInTitlesBecomeGlossaryTerms() {
        let docs = [
            doc(written: "TAPR call [Pinecrest]. Pinecrest runs on AWS.", heard: "pinecrest is here", title: "TAPR call [Pinecrest]"),
            doc(written: "Pre-TAPR call [Pinecrest]. Scoped it.", heard: "pinecrest again", title: "Pre-TAPR call [Pinecrest]"),
        ]
        let pinecrest = try! #require(VocabularyMiner.mine(docs).first { $0.term == "Pinecrest" })
        #expect(pinecrest.heardAs == nil)
        #expect(pinecrest.reason == "Spelled this way in 2 meetings")
    }

    @Test func ordinaryWordsAndTheUsersNameAreSkipped() {
        let docs = [
            doc(written: "Manual steps remain. The manual review by Alex Moreno.", heard: "manually manually"),
            doc(written: "Manual QA. Alex Moreno owns the manual check.", heard: "manually"),
            doc(written: "Alex Moreno, Moreno notes", heard: "peres"),
        ]
        let terms = VocabularyMiner.mine(docs, exclude: ["Alex", "Moreno"]).map(\.term)
        #expect(!terms.contains("Manual"))
        #expect(!terms.contains("Moreno"))
    }

    @Test func shortAcronymsAreSpelledOutNotMisheard() {
        let docs = [
            doc(written: "Use the CLI for deploys", heard: "use the cell for deploys"),
            doc(written: "CLI auth flow", heard: "the cell login"),
        ]
        #expect(VocabularyMiner.mine(docs).first { $0.term == "CLI" }?.heardAs == nil)
    }

    @Test func learnsAMisheardAcronym() {
        let docs = [
            doc(written: "TAPR call [Pinecrest]. Reviewed the TAPR findings with Pinecrest.",
                heard: "so for the taper review the taper is about pillars and the tapper report"),
            doc(written: "Pre-TAPR call [Pinecrest]. Scoped the TAPR.", heard: "before the taper we need access"),
            doc(written: "Weekly sync about invoices", heard: "the invoices are late"),
        ]
        let suggestions = VocabularyMiner.mine(docs)
        let tapr = try! #require(suggestions.first { $0.term == "TAPR" })
        #expect(tapr.heardAs == "taper")
        #expect(tapr.variants.contains("tapper"))
        #expect(tapr.heardCount == 4)
        #expect(tapr.meetingCount == 2)
        #expect(tapr.reason.contains("“taper”"))
    }

    @Test func splitWordsAreAMishearing() {
        let docs = [
            doc(written: "Northwind x Harborcloud kickoff", heard: "welcome everyone from north wind today"),
            doc(written: "Northwind x Harborcloud sync", heard: "the north wind team will push images"),
        ]
        let northwind = try! #require(VocabularyMiner.mine(docs).first { $0.term == "Northwind" })
        #expect(northwind.heardAs == "north wind")
    }

    @Test func realWordsUsedEverywhereAreNotMishearings() {
        // "taper" shows up just as much where TAPR isn't discussed.
        let docs = [
            doc(written: "TAPR review", heard: "the taper report"),
            doc(written: "TAPR follow-up", heard: "nothing"),
            doc(written: "Chip fab visit", heard: "taper taper taper yield"),
        ]
        let tapr = VocabularyMiner.mine(docs).first { $0.term == "TAPR" }
        #expect(tapr?.heardAs == nil)
    }

    @Test func skipsCommonWordsAndExistingEntries() {
        let docs = [
            doc(written: "Dashboard review. TAPR prep.", heard: "dashbord taper"),
            doc(written: "Dashboard update. TAPR notes.", heard: "dashbord taper"),
        ]
        let terms = VocabularyMiner.mine(docs, existing: ["TAPR"]).map(\.term)
        #expect(!terms.contains("TAPR"))
        #expect(!terms.contains("Dashboard"))
    }

    @Test func soundsAlikeUsesConsonantSkeleton() {
        #expect(VocabularyMiner.skeleton("taper") == "tpr")
        #expect(VocabularyMiner.soundsAlike("taper", "tapr", kind: .acronym))
        #expect(!VocabularyMiner.soundsAlike("water", "tapr", kind: .acronym))
        #expect(!VocabularyMiner.soundsAlike("tapr", "tapr", kind: .acronym))
    }
}

// MARK: - Action item status

@Suite struct ActionItemStatusTests {
    @Test func completedIsAlwaysDone() {
        #expect(ActionItemStatus.resolve(stored: "inProgress", isCompleted: true) == .done)
        #expect(ActionItemStatus.resolve(stored: "todo", isCompleted: true) == .done)
    }

    @Test func reopenedGoesBackToItsColumn() {
        #expect(ActionItemStatus.resolve(stored: "waiting", isCompleted: false) == .waiting)
        #expect(ActionItemStatus.resolve(stored: "done", isCompleted: false) == .todo)
        #expect(ActionItemStatus.resolve(stored: "garbage", isCompleted: false) == .todo)
    }

    @MainActor
    @Test func boardStatusKeepsIsCompletedInStep() throws {
        let container = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = ActionItem(title: "Push images to ECR")
        context.insert(item)
        #expect(item.workflowStatus == "todo")
        #expect(item.boardStatus == .todo)

        item.boardStatus = .inProgress
        #expect(item.isCompleted == false)
        #expect(item.workflowStatus == "inProgress")

        item.boardStatus = .done
        #expect(item.isCompleted == true)

        // Existing code (checkbox, Reminders sync) only flips isCompleted.
        item.isCompleted = false
        #expect(item.boardStatus == .todo)

        item.boardStatus = .waiting
        item.isCompleted = true
        #expect(item.boardStatus == .done)
        item.isCompleted = false
        #expect(item.boardStatus == .waiting)
    }
}

// MARK: - Follow-ups

@Suite struct FollowUpPlannerTests {
    private let summary = """
    # Data pipeline

    - Textract slots in between S3 upload and Glue
    - Raw PDFs stay in the bronze bucket

    # Next Steps

    - Next session topic: ECS and Fargate
    - **Share meeting recording and session summary with Mateo**
    - **Build and push Docker images to ECR** (Mateo)
    """

    private func northwindMeeting(daysAgo days: Double = 2, title: String = "Northwind x Harborcloud - SaaS Platform on AWS", summary: String? = nil) -> MeetingSignals {
        meeting(title, northwind, daysAgo: days, summary: summary ?? self.summary)
    }

    @Test func externalMeetingWithNextStepsIsEligible() {
        let m = northwindMeeting()
        let context = ProjectSuggester.Context.build([m])
        #expect(FollowUpPlanner.ineligibility(m, among: [m], context: context, handled: [], now: now) == nil)
    }

    @Test func ineligibleReasons() {
        let internalMeeting = meeting("Alex / Leo", internalTeam, summary: summary)
        let old = northwindMeeting(daysAgo: 30)
        let thin = northwindMeeting(summary: "# Notes\n\n- Short call")
        let notDone = meeting("Northwind", northwind, summary: summary, complete: false)
        let handled = northwindMeeting()
        let all = [internalMeeting, old, thin, notDone, handled]
        let context = ProjectSuggester.Context.build(all)
        #expect(FollowUpPlanner.ineligibility(internalMeeting, among: all, context: context, handled: [], now: now) == .noExternalAttendees)
        #expect(FollowUpPlanner.ineligibility(old, among: [old], context: context, handled: [], now: now) == .tooOld)
        #expect(FollowUpPlanner.ineligibility(thin, among: [thin], context: context, handled: [], now: now) == .nothingToRecap)
        #expect(FollowUpPlanner.ineligibility(notDone, among: all, context: context, handled: [], now: now) == .notComplete)
        #expect(FollowUpPlanner.ineligibility(handled, among: [handled], context: context, handled: [handled.id], now: now) == .alreadyHandled)
    }

    @Test func onlyTheLatestMeetingOfASeries() {
        let older = northwindMeeting(daysAgo: 6)
        let newer = northwindMeeting(daysAgo: 1)
        let context = ProjectSuggester.Context.build([older, newer])
        #expect(FollowUpPlanner.ineligibility(older, among: [older, newer], context: context, handled: [], now: now) == .newerMeetingInSeries)
        #expect(FollowUpPlanner.ineligibility(newer, among: [older, newer], context: context, handled: [], now: now) == nil)
    }

    @Test func draftRecapsAndListsNextSteps() {
        let m = northwindMeeting()
        let drafts = FollowUpPlanner.drafts([m], handled: [], senderName: "Alex Moreno", transcriptMentions: [m.id: "System audio (Mateo K): hi"], now: now)
        let draft = try! #require(drafts.first)
        #expect(draft.primary?.email == "mateo.k@northwind.example")
        #expect(draft.subject == "Northwind x Harborcloud – Session recap & next steps")
        #expect(draft.body.hasPrefix("Hi Mateo,"))
        #expect(draft.body.contains("- Build and push Docker images to ECR (Mateo)"))
        #expect(draft.body.contains("- Textract slots in between S3 upload and Glue"))
        #expect(draft.body.hasSuffix("Best,\nAlex"))
        #expect(draft.reasons.contains { $0.contains("Northwind") })
        #expect(draft.reasons.contains { $0.hasPrefix("You said you'd") })
    }

    @Test func nextStepsReadGranolaTaskLines() {
        let steps = SummaryOutline.nextSteps(summary)
        #expect(steps.map(\.text).contains("Share meeting recording and session summary with Mateo"))
        #expect(steps.first { $0.text.hasPrefix("Build") }?.owner == "Mateo")
    }
}

// MARK: - Patterns

@Suite struct PatternDetectorTests {
    @Test func staleItemsGroupByProject() {
        let items = [
            PatternDetector.OpenItem(id: UUID(), title: "Push images", meetingTitle: "Northwind sync", meetingDate: daysAgo(20), project: "Northwind"),
            PatternDetector.OpenItem(id: UUID(), title: "Share costs", meetingTitle: "Northwind sync", meetingDate: daysAgo(16), project: "Northwind"),
            PatternDetector.OpenItem(id: UUID(), title: "Fresh one", meetingTitle: "Northwind sync", meetingDate: daysAgo(2), project: "Northwind"),
        ]
        let patterns = PatternDetector.staleItems(items, now: now)
        #expect(patterns.count == 1)
        #expect(patterns.first?.title == "2 Northwind items open for 2 weeks")
    }

    @Test func seriesMeetingTomorrowSuggestsReview() {
        let past = (1...4).map { meeting("Northwind x Harborcloud - SaaS Platform on AWS", northwind, daysAgo: Double($0 * 7)) }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let event = AgendaEvent(id: "g:1", title: "Northwind x Harborcloud - SaaS Platform on AWS", start: tomorrow, end: tomorrow.addingTimeInterval(3600), sources: [.google])
        let other = AgendaEvent(id: "g:2", title: "Dentist", start: tomorrow, end: tomorrow.addingTimeInterval(3600), sources: [.google])
        let reviews = PatternDetector.seriesReviews(events: [event, other], meetings: past, now: now)
        #expect(reviews.count == 1)
        #expect(reviews.first?.title.hasPrefix("Review the last 3") == true)
    }
}

// MARK: - Comment to AI

@Suite struct CommentToActionTests {
    @Test func readsDestinations() {
        let available = CommentToAction.Available(clickUp: true, notion: false, n8n: false)
        #expect(CommentToAction.interpret("open a ticket for this in ClickUp", itemTitle: "Fix SSO", available: available)?.kind == .dispatch(destination: "clickup"))
        #expect(CommentToAction.interpret("remind me friday", itemTitle: "Fix SSO", available: available)?.kind == .dispatch(destination: "reminder"))
        #expect(CommentToAction.interpret("make a ticket", itemTitle: "Fix SSO", available: available)?.kind == .dispatch(destination: "clickup"))
        #expect(CommentToAction.interpret("make a ticket", itemTitle: "Fix SSO", available: .init())?.kind == .dispatch(destination: "reminder"))
        #expect(CommentToAction.interpret("waiting on Mateo", itemTitle: "x", available: available)?.kind == .move(.waiting))
        #expect(CommentToAction.interpret("hmm", itemTitle: "x", available: available) == nil)
    }

    @Test func outboundIsMarked() {
        #expect(ActionProposal(kind: .dispatch(destination: "clickup"), title: "x").isOutbound)
        #expect(!ActionProposal(kind: .dispatch(destination: "reminder"), title: "x").isOutbound)
        #expect(!ActionProposal(kind: .email, title: "x").isOutbound)
    }

    @Test func aiAnswerIsValidated() {
        #expect(CommentToAction.parseAI(["action": "clickup", "title": "Fix SSO login"], itemTitle: "x")?.title == "Fix SSO login")
        #expect(CommentToAction.parseAI(["action": "rm -rf", "title": "x"], itemTitle: "x") == nil)
        #expect(CommentToAction.parseAI(["action": "notion", "title": ""], itemTitle: "Item")?.title == "Item")
    }

    @Test func quotedTextBecomesTheTitle() {
        #expect(CommentToAction.quotedText(in: "open a ticket “Fix SSO login” please") == "Fix SSO login")
    }
}
