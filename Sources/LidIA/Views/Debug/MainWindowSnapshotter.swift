import AppKit
import SwiftData
import SwiftUI

/// Whether this launch is a DEBUG design-snapshot run. Always false in release.
enum SnapshotRun {
    static var isActive: Bool {
        #if DEBUG
        // Main-window and Settings snapshot runs alike: no background
        // services, and never the real library.
        let env = ProcessInfo.processInfo.environment
        return !(env["LIDIA_SNAPSHOT_MAIN"] ?? "").isEmpty || !(env["LIDIA_SNAPSHOT_SETTINGS"] ?? "").isEmpty
            || !(env["LIDIA_SNAPSHOT_MENUBAR"] ?? "").isEmpty
        #else
        return false
        #endif
    }

    #if DEBUG
    /// A snapshot run, or any build whose bundle ID isn't the app's own (a
    /// renamed copy used for design runs), must never open the real library.
    static var requiresIsolatedStore: Bool {
        isActive || (Bundle.main.bundleIdentifier.map { $0 != "io.lidia.app" && $0.hasPrefix("io.lidia.app.") } ?? false)
    }

    /// `LIDIA_STORE_URL`: a COPY of a library to open instead of the real one.
    /// Refuses the real library file.
    static var storeOverrideURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["LIDIA_STORE_URL"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let real = LibraryLocation.storeURL.resolvingSymlinksInPath().standardizedFileURL
        precondition(url.path != real.path, "LIDIA_STORE_URL must point at a copy of the library, not the library itself")
        return url
    }
    #endif
}

#if DEBUG
/// The names the main-window shots look for in the library copy. The defaults
/// match the fictional cast (docs/fictional-cast.md); point them at your own
/// library's meetings with `LIDIA_SNAPSHOT_SERIES` (a recurring meeting's
/// title), `LIDIA_SNAPSHOT_PROJECT` (the project to create from it),
/// `LIDIA_SNAPSHOT_COMPANY` (the library filter) and
/// `LIDIA_SNAPSHOT_OTHER_CALL` (another meeting's title).
enum SnapshotCast {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var series: String { env["LIDIA_SNAPSHOT_SERIES"] ?? "Northwind x Harborcloud - SaaS Platform on AWS" }
    /// The series title up to " - ", for the Action Items search.
    static var seriesPrefix: String { series.components(separatedBy: " - ").first ?? series }
    static var project: String { env["LIDIA_SNAPSHOT_PROJECT"] ?? "Northwind" }
    static var company: String { env["LIDIA_SNAPSHOT_COMPANY"] ?? "Harborcloud" }
    static var otherCall: String { env["LIDIA_SNAPSHOT_OTHER_CALL"] ?? "TAPR call" }
}

/// A recorded agent run turned into an Ask answer, for snapshots.
@MainActor
enum AgentSnapshotFixture {
    static func answer() -> (String, ChatBarMessage)? {
        guard let path = ProcessInfo.processInfo.environment["LIDIA_SNAPSHOT_AGENT_TRANSCRIPT"],
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let transcript = try? decoder.decode(AgentTranscript.self, from: data),
              let question = transcript.messages.last(where: { $0.role == .user })?.text,
              let answerText = transcript.messages.last(where: { $0.role == .assistant && $0.toolCalls.isEmpty })?.text else { return nil }
        let titles = transcript.toolRuns
            .filter { $0.call.name == "get_meeting" }
            .compactMap { $0.result.split(separator: "\n").first.map { String($0.drop { $0 != "]" }.dropFirst()).trimmingCharacters(in: .whitespaces) } }
        var message = ChatBarMessage(role: .assistant, text: answerText, sourceMeetings: titles, groundingConfidence: .high, modelLabel: transcript.model)
        message.agentTranscript = transcript
        return (question, message)
    }
}
#endif

/// Hooks the main window registers so the snapshotter can drive it.
@MainActor
final class MainWindowSnapshotDriver {
    static var shared: MainWindowSnapshotDriver?

    let nav: NavigationState
    let openAskPalette: (String) -> Void
    let closeAskPalette: () -> Void
    var libraryFilter: ((MeetingLibraryFilter) -> Void)?
    /// For the live-page shots (DEBUG snapshot recording, no capture).
    var session: RecordingSession?
    /// Opens the comment-to-AI confirmation for the first open card.
    var boardComment: ((String) -> Void)?
    /// Opens the intent confirmation for the first open card whose title contains this.
    var boardIntent: ((String) -> Void)?
    /// Sets the Action Items search text.
    var actionItemsFilter: ((String) -> Void)?
    /// Shows a recorded agent answer in the Ask palette.
    var showAskAnswer: ((String, ChatBarMessage) -> Void)?
    /// The window's chat engine (Chats and the ⌘K palette), for chat shots.
    var chatViewModel: ChatBarViewModel?

    init(nav: NavigationState, openAskPalette: @escaping (String) -> Void, closeAskPalette: @escaping () -> Void) {
        self.nav = nav
        self.openAskPalette = openAskPalette
        self.closeAskPalette = closeAskPalette
    }
}

#if DEBUG
/// DEBUG-only: with `LIDIA_SNAPSHOT_MAIN=<dir>` set, sizes the main window,
/// visits every surface in light and dark mode, writes PNGs with
/// `cacheDisplay`, then quits. Pair with `LIDIA_STORE_URL=<copy>` for real
/// data. Background services (sync, AI insights, notifications, meeting
/// detection, queued processing) don't start in a snapshot run. Optional:
/// `LIDIA_SNAPSHOT_ONLY=<substring>`, `LIDIA_SNAPSHOT_APPEARANCE=light|dark`.
@MainActor
enum MainWindowSnapshotter {
    private static var installed = false

    private static var calendar: GoogleCalendarMonitor?
    private static var settings: AppSettings?

    static func installIfRequested(settings: AppSettings, calendar: GoogleCalendarMonitor) {
        self.calendar = calendar
        self.settings = settings
        guard !installed, let dir = ProcessInfo.processInfo.environment["LIDIA_SNAPSHOT_MAIN"], !dir.isEmpty else { return }
        installed = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await run(directory: URL(fileURLWithPath: dir), settings: settings)
        }
    }

    private struct Shot {
        let name: String
        var size = NSSize(width: 1280, height: 820)
        var settle: Double = 1.0
        var popover = false
        /// Also capture the window's sheet.
        var sheet = false
        /// Scroll the detail column down by this many points before capturing.
        var scroll: CGFloat = 0
        let action: @MainActor (MainWindowSnapshotDriver, ModelContext) -> Void
    }

    /// Fixed agenda for the shots: `nil` means no calendar connected.
    private static func setCalendar(events: [GoogleCalendarClient.CalendarEvent]?) {
        guard let calendar, let settings else { return }
        settings.calendarEnabled = false
        calendar.isSignedIn = events != nil
        calendar.upcomingEvents = []
        calendar.weekEvents = events ?? []
    }

    /// A week shaped like the owner's: a daily standup (one per day, all
    /// shown), the Northwind series tomorrow, internal 1:1s and the WBR.
    private static func realisticWeek(now: Date = .now) -> [GoogleCalendarClient.CalendarEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let northwind = ["alex@harborcloud.example", "mateo.k@northwind.example", "daniel.r@northwind.example", "felix.s@northwind.example"]
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: calendar.date(byAdding: .day, value: day, to: today)!)!
        }
        var events: [GoogleCalendarClient.CalendarEvent] = []
        func add(_ id: String, _ title: String, _ day: Int, _ hour: Int, _ minute: Int, minutes: Int, attendees: [String] = [], link: URL? = nil, color: String) {
            events.append(GoogleCalendarClient.CalendarEvent(
                id: "\(id)-\(day)", title: title, start: at(day, hour, minute), end: at(day, hour, minute + minutes),
                attendees: attendees, meetingLink: link, colorHex: color
            ))
        }
        for day in 0..<5 {
            add("standup", "Harborcloud daily standup", day, 9, 0, minutes: 15, attendees: ["alex@harborcloud.example", "leo@harborcloud.test"], link: meet, color: "#33B679")
        }
        add("wbr", "Engineering - WBR", 0, 11, 45, minutes: 45, attendees: ["alex@harborcloud.example", "selin@harborcloud.example"], color: "#7986CB")
        add("leo", "Alex / Leo", 0, 15, 0, minutes: 30, attendees: ["alex@harborcloud.example", "leo@harborcloud.test"], link: meet, color: "#8E24AA")
        add("focus", "Focus: AWS landing zone", 0, 17, 0, minutes: 60, color: "#616161")
        add("northwind", "Northwind x Harborcloud - SaaS Platform on AWS", 1, 13, 0, minutes: 60, attendees: northwind, link: meet, color: "#039BE5")
        add("pinecrest", "TAPR call [Pinecrest]", 1, 15, 30, minutes: 60, attendees: ["alex@harborcloud.example", "victor@pinecrest.example"], link: meet, color: "#F4511E")
        add("greta", "Greta / Alex", 2, 13, 30, minutes: 30, attendees: ["alex@harborcloud.example", "greta@harborcloud.example"], link: meet, color: "#8E24AA")
        add("wbr", "Engineering - WBR", 3, 11, 45, minutes: 45, attendees: ["alex@harborcloud.example", "selin@harborcloud.example"], color: "#7986CB")
        return events
    }

    /// The Granola imports carry next steps only in their summaries: turn
    /// them into action items in the COPY so the board has real content.
    private static func seedActionItems(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let statuses: [ActionItemStatus] = [.inProgress, .todo, .waiting, .todo, .todo]
        var index = 0
        for meeting in all where meeting.status == .complete && meeting.externalSourceID != nil && meeting.actionItems.isEmpty {
            let steps = SummaryOutline.nextSteps(meeting.summary).filter { !$0.text.lowercased().hasPrefix("next ") }.prefix(3)
            for step in steps {
                let item = ActionItem(title: step.text, assignee: step.owner ?? "Alex Moreno")
                item.meeting = meeting
                meeting.actionItems.append(item)
                // Older meetings' items are mostly done; recent ones are in flight.
                let age = Date.now.timeIntervalSince(meeting.date) / 86_400
                item.boardStatus = age > 25 && index % 3 != 0 ? .done : statuses[index % statuses.count]
                if index % 4 == 1 { item.priority = "high" }
                index += 1
            }
        }
        try? context.save()
    }

    private static func meeting(_ title: String, in context: ModelContext, offset: Int = 0) -> Meeting? {
        let all = (try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let matches = all.filter { $0.title.localizedCaseInsensitiveContains(title) }
        return matches.count > offset ? matches[offset] : matches.first
    }

    /// The newest meeting with this title that has AI notes.
    private static func summarized(_ title: String, in context: ModelContext) -> Meeting? {
        let all = (try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        return all.first { $0.title.localizedCaseInsensitiveContains(title) && !$0.summary.isEmpty && $0.summary.count > 500 }
    }

    private static func richestMeeting(in context: ModelContext) -> Meeting? {
        let all = (try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        return all.first { $0.status == .complete && !$0.summary.isEmpty && ($0.calendarAttendees?.count ?? 0) > 0 && !$0.refinedTranscript.isEmpty }
    }

    private static var shots: [Shot] {
        [
            Shot(name: "01-today", settle: 1.5) { d, _ in
                setCalendar(events: realisticWeek())
                d.nav.showToday()
            },
            Shot(name: "01b-today-no-calendar") { d, _ in
                setCalendar(events: nil)
                d.nav.showToday()
            },
            Shot(name: "01c-today-nothing-left") { d, _ in
                setCalendar(events: DemoDataSeeder.fakeUpcomingEvents().filter { !Calendar.current.isDateInToday($0.start) })
                d.nav.showToday()
            },
            Shot(name: "02-library") { d, _ in
                setCalendar(events: DemoDataSeeder.fakeUpcomingEvents())
                d.nav.librarySeriesKey = nil
                d.nav.show(.library)
            },
            Shot(name: "03-library-filtered") { d, _ in
                d.nav.librarySeriesKey = nil
                d.nav.show(.library)
                var filter = MeetingLibraryFilter()
                filter.query = SnapshotCast.company
                filter.sources = [.imported]
                d.libraryFilter?(filter)
            },
            Shot(name: "04-series") { d, _ in
                d.libraryFilter?(MeetingLibraryFilter())
                d.nav.show(.library)
                d.nav.librarySeriesKey = MeetingLibraryModel.seriesKey(for: SnapshotCast.series)
            },
            Shot(name: "05-meeting-ai-notes") { d, ctx in
                if let m = summarized(SnapshotCast.series, in: ctx) ?? richestMeeting(in: ctx) {
                    d.nav.inspectorRequest = .hide
                    d.nav.show(m)
                }
            },
            Shot(name: "06-meeting-attendees", settle: 1.2, popover: true) { d, _ in
                d.nav.meetingPageRequest = .showAttendees
            },
            Shot(name: "07-meeting-my-notes") { d, _ in
                d.nav.meetingPageRequest = .myNotes
            },
            Shot(name: "08-meeting-transcript", settle: 1.5) { d, _ in
                d.nav.meetingPageRequest = .aiNotes
                d.nav.inspectorRequest = .transcript
            },
            Shot(name: "09-meeting-ask") { d, _ in d.nav.inspectorRequest = .ask },
            Shot(name: "10-meeting-more-menu-items") { d, ctx in
                // A different meeting with many participants and no inspector.
                if let m = meeting(SnapshotCast.otherCall, in: ctx) ?? richestMeeting(in: ctx) {
                    d.nav.inspectorRequest = .hide
                    d.nav.show(m)
                }
            },
            Shot(name: "11-meeting-streaming", settle: 1.5) { d, ctx in
                let all = (try? ctx.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
                guard let m = all.first(where: { $0.summary.isEmpty && $0.status != .recording }) ?? all.first else { return }
                let center = ProcessingProgressCenter.shared
                let progress = center.start(meetingID: m.id)
                progress.begin(.transcribing)
                progress.complete(.transcribing)
                progress.begin(.speakers)
                progress.complete(.speakers)
                progress.begin(.summarizing, detail: "Summarizing")
                center.resetSummaryText(meetingID: m.id)
                center.appendSummaryText(
                    "# Context\n\n- Kick-off of the SaaS platform build on AWS with Northwind\n- Agreed to start from the landing zone and a shared account structure\n\n# Decisions\n\n- Use AWS Organizations with separate prod and staging accounts\n- Weekly check-in on Mondays",
                    meetingID: m.id
                )
                d.nav.inspectorRequest = .hide
                d.nav.show(m)
            },
            Shot(name: "12-action-items") { d, _ in d.nav.show(.actionItems) },
            Shot(name: "13-people") { d, _ in d.nav.show(.people) },
            Shot(name: "14-chats") { d, _ in d.nav.show(.chat) },
            Shot(name: "15-ask-palette") { d, _ in
                d.nav.showToday()
                d.openAskPalette("")
            },
            Shot(name: "16-small-meeting", size: NSSize(width: 900, height: 600)) { d, ctx in
                d.closeAskPalette()
                if let m = summarized(SnapshotCast.series, in: ctx) ?? richestMeeting(in: ctx) {
                    d.nav.inspectorRequest = .transcript
                    d.nav.show(m)
                }
            },
            Shot(name: "17-small-library", size: NSSize(width: 900, height: 600)) { d, _ in
                d.nav.librarySeriesKey = nil
                d.nav.show(.library)
            },
            Shot(name: "26-live-recording", settle: 1.5) { d, ctx in
                LiveSnapshotFixture.begin(in: ctx, session: session)
                d.nav.inspectorRequest = .hide
                if let m = LiveSnapshotFixture.meeting { d.nav.show(m) }
            },
            Shot(name: "27-live-paused", settle: 1.2) { d, ctx in
                LiveSnapshotFixture.begin(in: ctx, session: session, paused: true)
                if let m = LiveSnapshotFixture.meeting { d.nav.show(m) }
            },
            Shot(name: "28-live-warning", settle: 1.2) { d, ctx in
                LiveSnapshotFixture.begin(in: ctx, session: session, systemAudioMissing: true)
                if let m = LiveSnapshotFixture.meeting { d.nav.show(m) }
            },
            Shot(name: "29-live-narrow", size: NSSize(width: 900, height: 640), settle: 1.5) { d, ctx in
                LiveSnapshotFixture.begin(in: ctx, session: session)
                if let m = LiveSnapshotFixture.meeting { d.nav.show(m) }
            },
            Shot(name: "30-post-stop-writing-notes", settle: 2.0) { d, ctx in
                LiveSnapshotFixture.stop(in: ctx, session: session, failed: false)
                d.nav.inspectorRequest = .transcript
                if let m = LiveSnapshotFixture.meeting { d.nav.show(m) }
            },
            Shot(name: "31-post-stop-generate-notes", settle: 1.5) { d, ctx in
                LiveSnapshotFixture.stop(in: ctx, session: session, failed: true)
                d.nav.inspectorRequest = .transcript
                if let m = LiveSnapshotFixture.meeting { d.nav.show(m) }
            },
            Shot(name: "18-small-today", size: NSSize(width: 900, height: 600), settle: 2.5) { d, _ in d.nav.showToday() },
            Shot(name: "01s-today-for-you", settle: 2.5, scroll: 640) { d, _ in
                setCalendar(events: realisticWeek())
                d.nav.showToday()
            },
            Shot(name: "01u-today-for-you-more", settle: 2.5, scroll: 1400) { d, _ in
                d.nav.showToday()
            },

            // Projects, suggestions and the board (on the library copy).
            Shot(name: "19-library-suggestions", settle: 1.5) { d, _ in
                setCalendar(events: realisticWeek())
                d.libraryFilter?(MeetingLibraryFilter())
                d.nav.librarySeriesKey = nil
                d.nav.show(.library)
            },
            Shot(name: "20-meeting-project-chip", settle: 1.5) { d, ctx in
                // A recording from today, next to its Granola history.
                let all = (try? ctx.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
                if let m = all.first(where: { $0.title.contains(SnapshotCast.project) && $0.status == .complete && $0.externalSourceID == nil })
                    ?? all.first(where: { $0.title.contains(SnapshotCast.project) }) {
                    d.nav.inspectorRequest = .hide
                    d.nav.show(m)
                }
            },
            Shot(name: "21-project-northwind", settle: 2.0) { d, ctx in
                // Accept the "Create project Northwind?" suggestion, as the user would.
                let all = (try? ctx.fetch(FetchDescriptor<Meeting>())) ?? []
                let results = IntelligenceEngine.compute(meetings: all, events: [], settings: AppDelegate.settings ?? AppSettings(), store: .shared)
                if let cluster = results.clusters.first(where: { $0.name == SnapshotCast.project }) {
                    // Leave two for the "Suggested for Northwind" list.
                    let ids = Array(cluster.meetingIDs.dropLast(2))
                    IntelligenceEngine.assign(ids, to: cluster.name, in: all, store: .shared, context: ctx)
                }
                d.nav.showProject(SnapshotCast.project)
            },
            Shot(name: "21s-project-northwind-scrolled", settle: 1.5, scroll: 700) { d, _ in
                d.nav.showProject(SnapshotCast.project)
            },
            Shot(name: "22-today-with-project", settle: 1.5) { d, _ in
                setCalendar(events: realisticWeek())
                d.nav.showToday()
            },
            Shot(name: "22s-today-with-project-for-you", settle: 2.5, scroll: 640) { d, _ in
                d.nav.showToday()
            },
            Shot(name: "23-library-projects", settle: 1.5) { d, _ in
                d.nav.librarySeriesKey = nil
                d.nav.show(.library)
            },
            Shot(name: "24-action-board", settle: 1.5) { d, _ in
                UserDefaults.standard.set("board", forKey: "actionItems.layout")
                UserDefaults.standard.set(false, forKey: "actionItems.showMyItemsOnly")
                UserDefaults.standard.set("none", forKey: "actionItems.boardGrouping")
                d.nav.show(.actionItems)
            },
            Shot(name: "25-action-board-by-project", settle: 1.5) { d, _ in
                UserDefaults.standard.set("project", forKey: "actionItems.boardGrouping")
                d.nav.show(.actionItems)
            },
            Shot(name: "25b-comment-to-ai-sheet", settle: 1.5, sheet: true) { d, _ in
                UserDefaults.standard.set("none", forKey: "actionItems.boardGrouping")
                d.boardComment?("open a ticket for this in ClickUp")
            },
            Shot(name: "26-action-list", settle: 1.0) { d, _ in
                UserDefaults.standard.set("list", forKey: "actionItems.layout")
                d.nav.show(.actionItems)
            },
            // An agent answer recorded on the library copy
            // (`LIDIA_SNAPSHOT_AGENT_TRANSCRIPT`), with "View what was sent" open.
            Shot(name: "32-ask-palette-agent-inspector", size: NSSize(width: 1280, height: 980), settle: 1.5) { d, _ in
                guard let (question, answer) = AgentSnapshotFixture.answer() else { return }
                AgentTranscriptDisclosure.snapshotExpanded = true
                d.nav.showToday()
                d.showAskAnswer?(question, answer)
            },
        ] + chatShots + intentShots
    }

    /// Intents on the library copy, with `Intents.json` from the live check
    /// next to it (`LIDIA_SNAPSHOT_ONLY=-intents-` or `-note-`).
    private static var intentShots: [Shot] {
        func board() {
            UserDefaults.standard.set("board", forKey: "actionItems.layout")
            UserDefaults.standard.set(false, forKey: "actionItems.showMyItemsOnly")
            UserDefaults.standard.set("none", forKey: "actionItems.boardGrouping")
            UserDefaults.standard.set(false, forKey: "actionItems.showCompleted")
        }
        return [
            Shot(name: "60-intents-board", size: NSSize(width: 1440, height: 1180), settle: 2.5) { d, _ in
                board()
                d.nav.show(.actionItems)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    d.actionItemsFilter?(SnapshotCast.seriesPrefix)
                }
            },
            Shot(name: "60b-intents-board-all", size: NSSize(width: 1440, height: 900), settle: 2.5) { d, _ in
                board()
                d.actionItemsFilter?("")
                d.nav.show(.actionItems)
            },
            Shot(name: "61-intents-confirm-message", size: NSSize(width: 1440, height: 900), settle: 2.0, sheet: true) { d, _ in
                board()
                d.nav.show(.actionItems)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    d.boardIntent?("stacking")
                }
            },
            Shot(name: "62-intents-reschedule", size: NSSize(width: 1440, height: 900), settle: 2.0, sheet: true) { d, _ in
                d.nav.show(.actionItems)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    d.boardIntent?("reschedule")
                }
            },
            Shot(name: "63-intents-list-unsupported", size: NSSize(width: 1280, height: 820), settle: 2.0) { d, _ in
                UserDefaults.standard.set("list", forKey: "actionItems.layout")
                UserDefaults.standard.set(false, forKey: "actionItems.showMyItemsOnly")
                d.nav.show(.actionItems)
                d.actionItemsFilter?(SnapshotCast.seriesPrefix)
            },
            Shot(name: "64-intents-today-for-you", settle: 2.5, scroll: 640) { d, _ in
                d.actionItemsFilter?("")
                setCalendar(events: realisticWeek())
                d.nav.showToday()
            },
            Shot(name: "65-note-ai-title", settle: 1.5) { d, ctx in
                // The note the live check titled with the local model.
                let all = (try? ctx.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
                if let note = all.first(where: { IntentStore.shared.aiTitle(for: $0.id)?.title == $0.title && !$0.notes.isEmpty }) {
                    d.nav.inspectorRequest = .hide
                    d.nav.show(note)
                    d.nav.meetingPageRequest = .myNotes
                }
            },
            Shot(name: "66-note-transcribing-chip", settle: 1.5) { d, ctx in
                LiveSnapshotFixture.begin(in: ctx, session: session)
                if let m = LiveSnapshotFixture.meeting {
                    m.notes = "Pricing: keep current tiers\nBeta: 40 accounts from October"
                    NoteTranscriptionState.shared.startedFromNote.insert(m.id)
                    d.nav.inspectorRequest = .hide
                    d.nav.show(m)
                }
            },
            Shot(name: "67-note-start-transcribing-chip", settle: 1.5) { d, ctx in
                LiveSnapshotFixture.stop(in: ctx, session: session, failed: false)
                let note = NoteFactory.makeNote(in: ctx)
                note.notes = "Call with the bank about the transfer"
                NoteTranscriptionState.shared.offered.insert(note.id)
                d.nav.inspectorRequest = .hide
                d.nav.show(note)
                d.nav.meetingPageRequest = .myNotes
            },
        ]
    }

    /// The chat and Ask surfaces on fixture runs (`LIDIA_SNAPSHOT_ONLY=-chat-`).
    private static var chatShots: [Shot] {
        func reset() {
            ChatAssistantMessage.snapshotExpandsThinking = false
            ChatSnapshotState.sourcesExpanded = false
            ChatSnapshotState.previewSource = nil
        }
        func thread(_ d: MainWindowSnapshotDriver, _ messages: [ChatBarMessage]) {
            d.nav.show(.chat)
            d.chatViewModel?.showSnapshotMessages(messages)
        }
        let q = ChatSnapshotFixtures.question
        return [
            Shot(name: "40-chat-empty", settle: 1.5) { d, _ in
                reset()
                setCalendar(events: realisticWeek())
                d.chatViewModel?.startNewThread(scope: .allMeetings)
                d.nav.show(.chat)
            },
            Shot(name: "41-chat-loading", settle: 1.2) { d, ctx in
                reset()
                let r = ChatSnapshotFixtures.refs(in: ctx)
                d.nav.show(.chat)
                d.chatViewModel?.showSnapshotRun(question: q, run: ChatSnapshotFixtures.loading(r))
            },
            Shot(name: "42-chat-thinking-expanded", size: NSSize(width: 1280, height: 980), settle: 1.5) { d, ctx in
                reset()
                ChatAssistantMessage.snapshotExpandsThinking = true
                let r = ChatSnapshotFixtures.refs(in: ctx)
                thread(d, [ChatBarMessage(role: .user, text: q), ChatSnapshotFixtures.finishedAgreement(r)])
            },
            Shot(name: "43-chat-streaming-citations", settle: 1.0) { d, ctx in
                reset()
                let r = ChatSnapshotFixtures.refs(in: ctx)
                d.nav.show(.chat)
                d.chatViewModel?.showSnapshotRun(question: q, run: ChatSnapshotFixtures.streaming(r))
            },
            Shot(name: "44-chat-answer-sources", settle: 1.5, popover: true) { d, ctx in
                reset()
                ChatSnapshotState.sourcesExpanded = true
                ChatSnapshotState.previewSource = 1
                let r = ChatSnapshotFixtures.refs(in: ctx)
                thread(d, [ChatBarMessage(role: .user, text: q), ChatSnapshotFixtures.finishedAgreement(r)])
            },
            Shot(name: "45-chat-approval", settle: 1.5) { d, ctx in
                reset()
                let r = ChatSnapshotFixtures.refs(in: ctx)
                thread(d, [ChatBarMessage(role: .user, text: "Send Northwind the account plan and set up the follow-ups"), ChatSnapshotFixtures.approvals(r)])
            },
            Shot(name: "46-chat-action-items", settle: 1.5) { d, ctx in
                reset()
                let r = ChatSnapshotFixtures.refs(in: ctx)
                thread(d, [ChatBarMessage(role: .user, text: "What's still open from the last Northwind meeting?"), ChatSnapshotFixtures.actionItems(r)])
            },
            Shot(name: "47-chat-table", settle: 1.5) { d, ctx in
                reset()
                let r = ChatSnapshotFixtures.refs(in: ctx)
                thread(d, [ChatBarMessage(role: .user, text: "Compare the last two Northwind meetings"), ChatSnapshotFixtures.table(r)])
            },
            Shot(name: "48-chat-palette-idle", settle: 1.5) { d, _ in
                reset()
                setCalendar(events: realisticWeek())
                d.chatViewModel?.startNewThread(scope: .allMeetings)
                d.nav.showToday()
                d.openAskPalette("")
            },
            Shot(name: "49-chat-palette-answer", size: NSSize(width: 1280, height: 980), settle: 1.5) { d, ctx in
                reset()
                let r = ChatSnapshotFixtures.refs(in: ctx)
                d.chatViewModel?.showSnapshotMessages([ChatBarMessage(role: .user, text: q), ChatSnapshotFixtures.finishedAgreement(r, local: true)])
                d.openAskPalette("")
            },
            Shot(name: "47b-chat-mention", settle: 1.5) { d, _ in
                reset()
                d.closeAskPalette()
                d.chatViewModel?.startNewThread(scope: .allMeetings)
                d.nav.show(.chat)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    d.chatViewModel?.inputText = "What did we agree in @North"
                }
            },
            Shot(name: "47c-chat-commands", settle: 1.5) { d, _ in
                reset()
                d.chatViewModel?.startNewThread(scope: .allMeetings)
                d.nav.show(.chat)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    d.chatViewModel?.inputText = "/"
                }
            },
            Shot(name: "50-chat-meeting-ask", settle: 2.0) { d, ctx in
                reset()
                d.closeAskPalette()
                guard let m = summarized(SnapshotCast.series, in: ctx) ?? richestMeeting(in: ctx) else { return }
                ChatSnapshotFixtures.pendingMeetingAskMessages = ChatSnapshotFixtures.meetingAsk(meeting: m)
                d.nav.inspectorRequest = .ask
                d.nav.show(m)
            },
        ]
    }

    private static var session: RecordingSession? { MainWindowSnapshotDriver.shared?.session }

    private static func run(directory: URL, settings: AppSettings) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let only = env["LIDIA_SNAPSHOT_ONLY"]
        var appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        if let mode = env["LIDIA_SNAPSHOT_APPEARANCE"] { appearances = appearances.filter { $0.0 == mode } }

        guard let driver = MainWindowSnapshotDriver.shared,
              let context = AppDelegate.modelContainer?.mainContext else {
            print("MainWindowSnapshotter: main window not ready")
            NSApp.terminate(nil)
            return
        }

        // Read (never write) the owner's name so "You" and the greeting match
        // the real app. Writes go to this run's own defaults domain.
        if settings.displayName.isEmpty,
           let name = UserDefaults(suiteName: "io.lidia.app")?.string(forKey: "displayName") {
            settings.displayName = name
        }
        MeetingAttendeeContext.currentUserName = settings.displayName

        // A follow-up draft so Today shows both kinds of suggestion (copy only).
        let draft = InboxNotification(
            type: "follow_up",
            title: "Send the AWS account plan to Daniel",
            body: "Follow up on the landing zone decision.",
            actionPayload: #"{"draft":"Hi Daniel, thanks for today. As agreed, we'll set up separate prod and staging accounts under AWS Organizations this week and review the guardrails together on Monday. I'll share the account plan by Thursday.","recipient":"daniel.r@northwind.example","channel":"email"}"#
        )
        context.insert(draft)
        IntelligenceStore.shared.resetForSnapshot()
        seedActionItems(in: context)

        for (mode, appearanceName) in appearances {
            NSApp.appearance = NSAppearance(named: appearanceName)
            for shot in shots {
                if let only, !shot.name.contains(only) { continue }
                guard let window = mainWindow() else { continue }
                window.appearance = NSAppearance(named: appearanceName)
                if window.frame.size != shot.size {
                    window.setContentSize(shot.size)
                    window.center()
                }
                window.makeKeyAndOrderFront(nil)
                if driver.nav.isAskPalettePresented && !shot.name.contains("palette") {
                    driver.closeAskPalette()
                    try? await Task.sleep(for: .seconds(0.4))
                }
                shot.action(driver, context)
                try? await Task.sleep(for: .seconds(shot.settle))
                // Scrolled shots move the clip view behind SwiftUI's back, so
                // they come after the window-size changes (see `shots`).
                if shot.scroll > 0, let contentView = window.contentView {
                    _ = scrollDetail(in: contentView, by: shot.scroll)
                    try? await Task.sleep(for: .seconds(0.8))
                }
                if env["LIDIA_SNAPSHOT_DEBUG"] != nil {
                    print("SNAPDEBUG \(shot.name) frame=\(window.frame.size) min=\(window.minSize) contentMin=\(window.contentMinSize) fitting=\(window.contentView?.fittingSize ?? .zero)")
                }
                capture(window, to: directory.appendingPathComponent("\(mode)-\(shot.name).png"))
                if shot.sheet, let sheet = window.attachedSheet {
                    capturePlain(sheet, to: directory.appendingPathComponent("\(mode)-\(shot.name)-sheet.png"))
                    window.endSheet(sheet)
                    try? await Task.sleep(for: .seconds(0.4))
                }
                if shot.popover {
                    for popover in NSApp.windows where popover.isVisible && String(describing: type(of: popover)).contains("Popover") {
                        capturePlain(popover, to: directory.appendingPathComponent("\(mode)-\(shot.name)-popover.png"))
                    }
                    driver.nav.meetingPageRequest = .closePopovers
                    try? await Task.sleep(for: .seconds(0.4))
                }
            }

            if only == nil || (only ?? "").contains("vocab") {
                UserDefaults.standard.set("board", forKey: "actionItems.layout")
                SettingsRouter.shared.show(.recording, subpage: .vocabulary)
                SettingsRouter.bringWindowForward()
                try? await Task.sleep(for: .seconds(2.5))
                if let settingsWindow = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("com_apple_SwiftUI_Settings") && $0.isVisible }) {
                    settingsWindow.appearance = NSAppearance(named: appearanceName)
                    settingsWindow.setContentSize(NSSize(width: 860, height: 760))
                    try? await Task.sleep(for: .seconds(1.0))
                    capture(settingsWindow, to: directory.appendingPathComponent("\(mode)-27-settings-vocabulary.png"))
                    settingsWindow.orderOut(nil)
                }
            }

            if only == nil || "pill".contains(only ?? "") || (only ?? "").contains("pill") {
                for (name, view) in RecordingPillSnapshots.views() {
                    render(view, appearance: appearanceName, to: directory.appendingPathComponent("\(mode)-\(name).png"))
                }
            }
            if only == nil || (only ?? "").contains("banner") {
                let banner = MeetingDetectionBannerView(
                    appName: "Zoom",
                    appIcon: NSWorkspace.shared.icon(for: .applicationBundle),
                    neverTitle: "Never for Zoom"
                )
                render(AnyView(banner), appearance: appearanceName, keepsAppearance: true,
                       to: directory.appendingPathComponent("\(mode)-32-detection-banner.png"))
            }
        }

        print("MainWindowSnapshotter: wrote snapshots to \(directory.path)")
        exit(0)
    }

    /// Scrolls the widest scroll view (the detail column) down by `offset`
    /// from where it rests. Returns it and its resting origin.
    private static func scrollDetail(in view: NSView, by offset: CGFloat) -> (NSScrollView, NSPoint)? {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let scrollView = scrollViews(view)
            .filter({ ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 10 })
            .max(by: { $0.frame.width < $1.frame.width }) else { return nil }
        let origin = scrollView.contentView.bounds.origin
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        let y = scrollView.contentView.isFlipped ? min(origin.y + offset, maxY) : max(0, origin.y - offset)
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return (scrollView, origin)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && !(window is NSPanel)
                && !(window.identifier?.rawValue ?? "").hasPrefix("com_apple_SwiftUI_Settings")
                && window.contentView != nil && window.frame.width > 400
        }
    }

    /// Renders an off-screen SwiftUI view (the recording pill) on a neutral
    /// desktop-like backdrop.
    private static func render(_ view: AnyView, appearance: NSAppearance.Name, keepsAppearance: Bool = false, to url: URL) {
        let isDark = appearance == .darkAqua
        let hosting = NSHostingView(rootView: view
            .padding(28)
            .background(isDark ? Color(white: 0.18) : Color(white: 0.86))
            .environment(\.colorScheme, isDark ? .dark : .light))
        // The pill is a dark HUD in both modes (its panel is always darkAqua).
        let drawn = keepsAppearance ? appearance : .darkAqua
        hosting.appearance = NSAppearance(named: drawn)
        let size = hosting.fittingSize
        // Materials only draw inside a window.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: drawn)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    private static func capturePlain(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    /// Same approach as `SettingsSnapshotter`: the sidebar's vibrant material
    /// doesn't come through `cacheDisplay`, so it's painted flat and each
    /// sidebar list is drawn on its own in the window's appearance.
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let canvas = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.955, alpha: 1)).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for table in allTables(in: view) {
            guard let tableRep = table.bitmapImageRepForCachingDisplay(in: table.visibleRect) else { continue }
            let saved = table.appearance
            table.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            table.cacheDisplay(in: table.visibleRect, to: tableRep)
            table.appearance = saved
            var rect = table.convert(table.visibleRect, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            tableRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = canvas.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    private static func allTables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { allTables(in: $0) }
    }

    /// Lists inside a vibrant (sidebar) material only.
    private static func sidebarTables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView {
            var ancestor = table.superview
            while let current = ancestor {
                if let effect = current as? NSVisualEffectView, effect.material == .sidebar { return [table] }
                ancestor = current.superview
            }
            return []
        }
        return view.subviews.flatMap { sidebarTables(in: $0) }
    }
}
/// A made-up meeting shown live (and then stopped) in the snapshot run. It lives only in
/// the snapshot's library copy.
@MainActor
enum LiveSnapshotFixture {
    static var meeting: Meeting?

    private static let lines: [(local: Bool, start: TimeInterval, text: String)] = [
        (false, 4, "Thanks for joining. Today I'd like to settle the launch plan for the new onboarding flow."),
        (false, 11, "We have three open questions: pricing, the beta list, and who owns the help articles."),
        (true, 19, "Sounds good. On pricing, I'd keep the current tiers and add a team plan later."),
        (true, 26, "For the beta, let's invite the 40 accounts that asked for it in October."),
        (false, 35, "Agreed. I can send the invites on Thursday if the copy is ready by Wednesday."),
    ]

    static func words() -> [TranscriptWord] {
        lines.flatMap { line -> [TranscriptWord] in
            let parts = line.text.split(separator: " ").map(String.init)
            return parts.enumerated().map { index, text in
                var word = TranscriptWord(word: text, start: line.start + Double(index) * 0.35, end: line.start + Double(index) * 0.35 + 0.3, confidence: 0.95, speaker: nil)
                word.isLocalSpeaker = line.local
                return word
            }
        }
    }

    static func begin(in context: ModelContext, session: RecordingSession?, paused: Bool = false, systemAudioMissing: Bool = false) {
        let meeting = self.meeting ?? {
            let m = Meeting(date: .now)
            m.title = "Onboarding launch plan"
            context.insert(m)
            self.meeting = m
            return m
        }()
        meeting.status = .recording
        meeting.summary = ""
        meeting.notes = "- Pricing: keep tiers, team plan later\n- Beta: 40 accounts from October\n- "
        meeting.rawTranscript = words()
        session?.beginSnapshotRecording(
            meeting: meeting,
            words: words(),
            volatile: paused ? [:] : [.mic: LiveVolatileLine(text: "And I'll write the help articles", start: 44, isLocalSpeaker: true)],
            elapsed: 47,
            speaking: paused ? [] : [.system],
            paused: paused,
            systemAudioMissing: systemAudioMissing
        )
    }

    static func stop(in context: ModelContext, session: RecordingSession?, failed: Bool) {
        if meeting == nil { begin(in: context, session: session) }
        session?.endSnapshotRecording()
        guard let meeting else { return }
        meeting.rawTranscript = words()
        meeting.duration = 47
        let center = ProcessingProgressCenter.shared
        if failed {
            center.end(meetingID: meeting.id)
            meeting.status = .failed
            meeting.summary = ""
            meeting.processingError = "No model selected."
        } else {
            meeting.status = .processing
            let progress = center.start(meetingID: meeting.id)
            progress.begin(.transcribing)
            progress.complete(.transcribing)
            progress.begin(.speakers)
            progress.complete(.speakers)
            progress.begin(.summarizing, detail: "Writing notes")
            center.resetSummaryText(meetingID: meeting.id)
            center.appendSummaryText(
                "# Launch plan\n\n- Keep the current pricing tiers; a team plan comes later\n- Beta goes to the 40 accounts that asked in October",
                meetingID: meeting.id
            )
        }
    }
}
#else
@MainActor
enum MainWindowSnapshotter {
    static func installIfRequested(settings: AppSettings, calendar: GoogleCalendarMonitor) {}
}
#endif
