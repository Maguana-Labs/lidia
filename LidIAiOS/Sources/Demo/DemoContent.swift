#if DEBUG
import Foundation
import LidIAIntelligence
import LidIAKit
import SwiftData

/// A sample library for the simulator and screenshots (`-demo`, DEBUG only).
/// Lives in an in-memory store: never touches a real library.
@MainActor
enum DemoContent {
    static func install(services: AppServices) {
        let context = services.container.mainContext
        let seeded = seed(into: context)
        services.settings.displayName = "Alex Moreno"
        services.intelligence.demoGenerator = DemoGenerator()
        services.recorder.demoScript = liveScript
        services.calendar.demoEvents = events
        services.calendar.refresh()
        route(services.options.screen, services: services, seeded: seeded)
    }

    // MARK: - Routing for screenshots

    private static func route(_ screen: String?, services: AppServices, seeded: Seeded) {
        let router = services.router
        let recorder = services.recorder
        switch screen {
        case "home-free":
            // Home with nothing left on the calendar ("Nothing else today" once
            // calendar access is granted, e.g. `simctl privacy … grant calendar`).
            services.calendar.demoEvents = []
            services.calendar.refresh()
        case "meetings":
            router.tab = .meetings
        case "detail":
            router.homePath.append(MeetingRoute(id: seeded.designReview))
        case "detail-northwind":
            router.homePath.append(MeetingRoute(id: seeded.northwindSync))
        case "actions":
            router.tab = .actions
        case "action":
            router.tab = .actions
            router.actionItemDetail = .init(id: seeded.staleItem)
        case "ask":
            router.tab = .ask
            router.pendingAskQuestion = "What did I promise Northwind?"
        case "settings", "settings-about":
            router.showSettings = true
        case "record":
            recorder.draft = .init(title: "Northwind weekly sync", attendees: ["Ana Ruiz", "Marco Bianchi"], calendarEventID: "demo-northwind")
            router.showRecorder = true
        case "record-live", "home-live":
            recorder.draft = .init(title: "Launch plan: iPhone beta", attendees: ["Priya Shah", "Tom Okafor"])
            Task {
                await recorder.start()
                recorder.seedDemo(elapsed: 754, segments: Array(liveScript.prefix(5)), volatile: "and I’ll write the release notes over the")
                if screen == "record-live" { router.showRecorder = true }
            }
        case "processing":
            recorder.draft = .init(title: "Launch plan: iPhone beta", attendees: ["Priya Shah", "Tom Okafor"])
            Task {
                await recorder.start()
                recorder.seedDemo(elapsed: 1_386, segments: liveScript, volatile: "")
                router.showRecorder = true
                try? await Task.sleep(for: .milliseconds(400))
                recorder.stop()
            }
        default:
            break
        }
    }

    // MARK: - Library

    struct Seeded {
        var designReview: UUID
        var northwindSync: UUID
        var staleItem: UUID
    }

    private static func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private static func due(_ days: Int, hour: Int = 17) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: .now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    @discardableResult
    private static func meeting(
        _ title: String, _ date: Date, minutes: Double, people: [String], folder: String?,
        summary: String, transcript: String = "", recordedHere: Bool = false,
        items: [(String, String?, Date?, Bool, String?)] = [], in context: ModelContext
    ) -> Meeting {
        let meeting = Meeting(
            title: title, date: date, duration: minutes * 60,
            refinedTranscript: transcript, summary: summary, status: .complete,
            audioFilePath: recordedHere ? "Recordings/demo.caf" : nil,
            calendarAttendees: people.isEmpty ? nil : people, folder: folder
        )
        context.insert(meeting)
        for (title, assignee, deadline, done, quote) in items {
            let item = ActionItem(title: title, assignee: assignee, isCompleted: done)
            item.setPreciseDeadline(deadline)
            item.sourceQuote = quote
            item.meeting = meeting
            context.insert(item)
            meeting.actionItems.append(item)
        }
        return meeting
    }

    private static func seed(into context: ModelContext) -> Seeded {
        let design = meeting(
            "Design review: iPhone app", at(daysAgo: 0, hour: 9, minute: 30), minutes: 48,
            people: ["Priya Shah", "Tom Okafor"], folder: "LidIA",
            summary: """
            ### Home and the hero card
            - Hero shows the next meeting with **Record** and **Join & record**; live timer while recording
              - Priya wants the countdown as the big number, title underneath
            - "For you" cards stay swipeable, each says why it's there
            - Decided: one red record button in the top bar, nowhere else competes with it

            ### Live Activity and Dynamic Island
            - Compact: red dot + timer. Expanded: title, last transcript line, Pause / Stop
            - Lock Screen view mirrors the expanded layout
            - Decided: Pause and Stop run as App Intents, no need to open the app
              - Tom checked: recording survives screen lock with the audio background mode

            ### On-device notes
            - Apple Intelligence writes notes, titles and action items; nothing leaves the phone
            - Long meetings are condensed in parts so they fit the 4K context
            - Open question: how to show progress for 60-minute meetings

            ### Next Steps
            - Tom: ship the Live Activity build to TestFlight (Friday)
            - Alex Moreno: write the empty-state copy (today)
            - Priya: share the Figma link
            """,
            transcript: """
            Okay, let's start with Home. The hero card is the thing people see first, so it has to answer one question: what's next, and can I record it in one tap.

            Priya: I'd make the countdown the big number. "In 22 minutes" is what you glance at. The title goes right under it, and the two pills, Record and Join and record.

            Tom: And when you're recording it flips to the timer. Same card, same place.

            Agreed. Then the Live Activity. Compact is just the red dot and the timer. Expanded shows the title, the last line of the transcript, and Pause and Stop.

            Tom: Pause and Stop are App Intents, so they work from the Lock Screen without opening the app. I tested it with the screen locked for twenty minutes and the recording kept going.

            Great. Tom, can you get that build to TestFlight by Friday? Tom: Yes, Friday works. And I'll write the empty-state copy today.
            """,
            items: [
                ("Ship the Live Activity build to TestFlight", "Tom", due(2), false, "Yes, Friday works."),
                ("Write the empty-state copy", "Alex Moreno", due(0, hour: 18), false, "I'll write the empty-state copy today."),
                ("Share the Figma link", "Priya", nil, true, nil),
            ],
            in: context
        )

        meeting(
            "Standup", at(daysAgo: 0, hour: 8, minute: 45), minutes: 12,
            people: ["Priya Shah", "Tom Okafor", "Marco Bianchi"], folder: "LidIA",
            summary: """
            ### Status
            - **Priya**: Home and Meetings screens done, starting Ask
            - **Tom**: Live Activity working on device; App Group pending
            - **Marco**: Northwind security review in progress
            ### Blockers
            - App Group needs the team account (Alex)
            """,
            in: context
        )

        meeting(
            "1:1 with Inés", at(daysAgo: 1, hour: 16), minutes: 28,
            people: ["Inés Navarro"], folder: nil,
            summary: """
            ### Hiring
            - Two backend roles for Q1; Inés prefers one senior over two mid-level
            - Decided: open the senior role first, revisit in February
            ### Growth
            - Inés wants to own the sync server end to end
            ### Next Steps
            - Alex Moreno: draft the Q1 hiring plan (yesterday)
            - Alex Moreno: intro Inés to Ana at Northwind
            """,
            items: [
                ("Draft the Q1 hiring plan", "Alex Moreno", due(-1), false, "I'll have a draft of the hiring plan by tomorrow."),
                ("Intro Inés to Ana at Northwind", "Alex Moreno", nil, false, nil),
            ],
            in: context
        )

        meeting(
            "Coffee with Sam", at(daysAgo: 2, hour: 13, minute: 10), minutes: 22,
            people: [], folder: nil,
            summary: """
            ### Sam's team
            - Moving from Granola; wants on-device notes for legal reasons
            - Interested in the MCP server for their internal agents
            ### Next Steps
            - Alex Moreno: send Sam the deck (this week)
            """,
            recordedHere: true,
            items: [("Send Sam the deck", "Alex Moreno", due(3), false, nil)],
            in: context
        )

        let northwind = meeting(
            "Northwind weekly sync", at(daysAgo: 7, hour: 11), minutes: 41,
            people: ["Ana Ruiz", "Marco Bianchi"], folder: "Northwind",
            summary: """
            ### TAPR scope
            - Ana needs the scope before procurement signs; target is the 14th
            - Six workloads in scope; two are on-prem and need a separate review
            - Decided: start with the four cloud workloads

            ### Budget and timeline
            - Budget owner confirmed: Ana's VP, cap €40k for phase one
            - On-site workshop in Madrid, two days, first week of December

            ### Next Steps
            - Alex Moreno: send the TAPR scope to Ana (Thursday)
            - Ana: book the on-site workshop
            - Marco: confirm the budget owner
            """,
            transcript: """
            Ana: The main thing for us is the TAPR scope. Procurement won't sign without it, and we want to sign by the 14th.

            Okay. We have six workloads, but two are on-prem, so those need a separate review. I'd start with the four cloud ones.

            Ana: That works. Marco, can you confirm who owns the budget? Marco: It's your VP, and the cap is forty thousand euros for phase one.

            Then I'll send you the scope by Thursday, Ana. And you'll book the workshop in Madrid? Ana: Yes, two days, first week of December.
            """,
            items: [
                ("Send the TAPR scope to Ana", "Alex Moreno", due(1), false, "I'll send you the scope by Thursday."),
                ("Book the on-site workshop in Madrid", "Ana", nil, false, "Yes, two days, first week of December."),
                ("Confirm the budget owner", "Marco", nil, true, nil),
            ],
            in: context
        )

        let kickoff = meeting(
            "Northwind kickoff", at(daysAgo: 9, hour: 10), minutes: 55,
            people: ["Ana Ruiz", "Marco Bianchi", "Priya Shah"], folder: "Northwind",
            summary: """
            ### Goals
            - Well-Architected review for six workloads, then a remediation plan
            - Success = a signed plan before the end of the quarter
            ### Security
            - Northwind needs our security questionnaire before any data access
            ### Next Steps
            - Marco: send the security questionnaire
            """,
            items: [("Send the security questionnaire", "Marco", nil, false, "I'll get you our questionnaire this week.")],
            in: context
        )

        meeting(
            "Investor update prep", at(daysAgo: 6, hour: 15), minutes: 37,
            people: ["Tom Okafor"], folder: "Maguana",
            summary: """
            ### Story
            - Lead with privacy: on-device notes, no cloud by default
            - Show iPhone + Mac together
            ### Next Steps
            - Alex Moreno: update the metrics slide (Monday)
            """,
            items: [("Update the metrics slide", "Alex Moreno", due(-2), false, nil)],
            in: context
        )

        for (days, minutes) in [(14, 33.0), (21, 38.0)] {
            meeting(
                "Northwind weekly sync", at(daysAgo: days, hour: 11), minutes: minutes,
                people: ["Ana Ruiz", "Marco Bianchi"], folder: "Northwind",
                summary: """
                ### Progress
                - Discovery calls done for four of six workloads
                - Decided: weekly cadence stays on Tuesdays
                """,
                in: context
            )
        }

        meeting(
            "Partner call: Acme", at(daysAgo: 18, hour: 17), minutes: 44,
            people: ["Inés Navarro", "Ana Ruiz"], folder: "Maguana",
            summary: """
            ### Partnership
            - Acme resells LidIA to legal teams; pilot with 20 seats
            - Decided: pilot starts in January
            """,
            in: context
        )

        try? context.save()
        let stale = kickoff.actionItems.first!.id
        return Seeded(designReview: design.id, northwindSync: northwind.id, staleItem: stale)
    }

    // MARK: - Calendar

    static var events: [UpcomingEvent] {
        let start = Date.now.addingTimeInterval(22 * 60)
        return [
            UpcomingEvent(
                id: "demo-northwind", title: "Northwind weekly sync",
                start: start, end: start.addingTimeInterval(30 * 60),
                attendees: ["Ana Ruiz", "Marco Bianchi"],
                joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), location: nil
            ),
            UpcomingEvent(
                id: "demo-board", title: "Board prep",
                start: start.addingTimeInterval(3 * 3600), end: start.addingTimeInterval(4 * 3600),
                attendees: ["Tom Okafor"], joinURL: nil, location: "Office"
            ),
        ]
    }

    // MARK: - Live transcript

    static let liveScript = [
        "Okay, the main thing today is the date for the iPhone beta.",
        "Priya, where did we land on the Live Activity?",
        "Compact shows the red dot and the timer. Expanded adds the last line of the transcript, with Pause and Stop.",
        "And Stop works from the Lock Screen without opening the app, right?",
        "Right, it's an App Intent. Tom tested it with the phone locked for twenty minutes.",
        "Tom, can you get a TestFlight build out by Friday?",
        "Friday works if the App Group is set up by Wednesday.",
        "Then let's decide on the eighteenth for the public beta.",
        "Agreed. Priya, can you finish the empty states before then?",
        "Yes, I'll have them by Monday.",
    ]
}

// MARK: - Scripted generator

/// Streams canned notes and answers so screenshots don't depend on a model.
struct DemoGenerator: TextGenerator {
    var displayName: String { "Apple Intelligence" }
    var isOnDevice: Bool { true }
    var contextTokens: Int { 4096 }

    func countTokens(_ text: String) async throws -> Int { TokenEstimate.estimate(text) }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        var text = ""
        for try await delta in stream(instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature) {
            text += delta
        }
        return text
    }

    func stream(instructions: String, prompt: String, maxTokens: Int, temperature: Double) -> AsyncThrowingStream<String, Error> {
        let text = instructions.hasPrefix(MeetingPrompts.markdownSummaryMarker) ? Self.notes : Self.answer(for: prompt)
        let delay = instructions.hasPrefix(MeetingPrompts.markdownSummaryMarker) ? 110 : 45
        return AsyncThrowingStream { continuation in
            let task = Task {
                var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                if !words.isEmpty { words[0] = words[0] }
                for (index, word) in words.enumerated() {
                    try? await Task.sleep(for: .milliseconds(delay))
                    if Task.isCancelled { break }
                    continuation.yield(index == 0 ? word : " " + word)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func extractFacts(notes: String) async throws -> MeetingFacts {
        MeetingFacts(
            title: "Launch plan: iPhone beta",
            decisions: ["Public beta on the 18th"],
            actionItems: [
                ExtractedActionItem(title: "Get a TestFlight build out", assignee: "Tom", deadline: "Friday"),
                ExtractedActionItem(title: "Finish the empty states", assignee: "Priya", deadline: "Monday"),
                ExtractedActionItem(title: "Set up the App Group", assignee: "Alex Moreno", deadline: "Wednesday"),
            ]
        )
    }

    static let notes = """
    ### Beta date
    - Public beta set for the 18th, after the TestFlight round
    - Decided: ship the beta on the 18th

    ### Live Activity
    - Compact: red dot + timer; expanded adds the last transcript line with Pause / Stop
    - Stop runs as an App Intent from the Lock Screen
      - Tom tested 20 minutes with the phone locked

    ### Next Steps
    - Tom: get a TestFlight build out (Friday)
    - Alex Moreno: set up the App Group (Wednesday)
    - Priya: finish the empty states (Monday)
    """

    /// Answers the demo question, citing the labels the prompt actually used.
    static func answer(for prompt: String) -> String {
        func label(containing title: String) -> String {
            for line in prompt.split(separator: "\n") where line.hasPrefix("[") && line.contains(title) {
                if let close = line.firstIndex(of: "]") { return String(line[...close]) }
            }
            return "[1]"
        }
        let sync = label(containing: "Northwind weekly sync")
        let kickoff = label(containing: "Northwind kickoff")
        return """
        You owe Northwind one thing: **send the TAPR scope to Ana by Thursday** \(sync). Procurement won’t sign without it, and they want to sign by the 14th.

        - **Ana** is booking the two-day workshop in Madrid, first week of December \(sync).
        - **Marco** still owes them the security questionnaire from the kickoff, now 9 days open \(kickoff).
        """
    }
}
#endif
