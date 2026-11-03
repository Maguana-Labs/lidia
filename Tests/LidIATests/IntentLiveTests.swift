import EventKit
import Foundation
import SwiftData
import Testing
@testable import LidIA

/// Intents on a COPY of a real library. Off unless
/// `LIDIA_INTENTS_LIVE_STORE=<path to a copied LidIA.store>` is set.
///
/// - `LIDIA_INTENTS_LIVE_TITLE`: meetings whose title contains this (default "Northwind").
/// - `LIDIA_INTENTS_LIVE_REPROCESS=1`: re-run the summary pipeline on the
///   longest of them with the local model, to show the extraction fix.
/// - `LIDIA_INTENTS_LIVE_MODEL`: MLX model ID (default Qwen 3.5 4B).
/// - `LIDIA_INTENTS_LIVE_CALENDAR=<json>`: calendar events to use when
///   EventKit isn't available to the test runner.
/// - `LIDIA_INTENTS_LIVE_CLAUDE=1`: draft the first message intent with
///   Claude (`ANTHROPIC_API_KEY`, claude-sonnet-5-5, effort low, web
///   search on, at most 4 calls). The key is never printed.
/// Intents are written to `Intents.json` next to the copy, for snapshots.
@Suite("Intents live", .serialized)
@MainActor
struct IntentLiveTests {
    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated static var storePath: String? { env["LIDIA_INTENTS_LIVE_STORE"] }
    /// `LIDIA_LIVE_USER`: the library owner's name.
    static var userName: String { env["LIDIA_LIVE_USER"] ?? "Alex Moreno" }

    struct FixtureEvent: Decodable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var attendees: [String]?
        var editable: Bool?
    }

    private func openCopy() throws -> ModelContainer {
        let url = URL(fileURLWithPath: try #require(Self.storePath))
        try #require(url.standardizedFileURL.path != LibraryLocation.storeURL.standardizedFileURL.path, "Never the real library")
        let schema = Schema(versionedSchema: AppSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    }

    private func calendarSource() -> (any IntentCalendarSource)? {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            print("LIVE calendar: EventKit (full access)")
            return LiveIntentCalendar(eventKit: EventKitManager(), google: nil, hidden: [])
        }
        guard let path = Self.env["LIDIA_INTENTS_LIVE_CALENDAR"], let data = FileManager.default.contents(atPath: path) else {
            print("LIVE calendar: none (EventKit status \(EKEventStore.authorizationStatus(for: .event).rawValue))")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = (try? decoder.decode([FixtureEvent].self, from: data)) ?? []
        print("LIVE calendar: \(events.count) events exported from the owner's calendar (EventKit isn't granted to the test runner)")
        return FixtureCalendarSource(events.map {
            IntentCalendarEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end, attendees: $0.attendees ?? [], source: "apple", editable: $0.editable ?? true)
        })
    }

    private func describe(_ intent: ActionIntent, title: String) {
        print("LIVE ── \(title)")
        print("LIVE    kind=\(intent.kind.rawValue) direction=\(intent.direction.rawValue) owner=\(intent.owner ?? "-") for=\(intent.recipientLabel ?? "-") verdict=\(intent.verdict.rawValue) confidence=\(Int(intent.confidence * 100))%")
        print("LIVE    button: \(intent.primaryLabel)   destinations: \(intent.destinations.map { "\($0.name)\($0.configured ? "" : " (not connected)")" }.joined(separator: ", "))")
        if let suggested = intent.suggestedTitle { print("LIVE    corrected title: \(suggested)") }
        for evidence in intent.evidence { print("LIVE    evidence: \(evidence.saidLabel()) [\(evidence.offsetLabel ?? "?")] “\(evidence.quote)” (\(Int(evidence.score * 100))%)") }
        print("LIVE    why: \(intent.confidenceReasons.joined(separator: " · "))")
        switch intent.artifact {
        case .message(let subject, let body), .document(let subject, let body), .ticket(let subject, let body):
            print("LIVE    draft (\(intent.draftedBy ?? "template")): \(subject)")
            for line in body.components(separatedBy: .newlines) { print("LIVE      | \(line)") }
        case .calendarChange(let proposal):
            print("LIVE    event: \(proposal.eventTitle) \(proposal.currentStart.map { $0.formatted() } ?? "") source=\(proposal.source) editable=\(proposal.editable)")
            for slot in proposal.slots { print("LIVE      slot: \(IntentTools.slotLine(slot))") }
            if let note = proposal.note { print("LIVE      note: \(note)") }
        default: break
        }
        for link in intent.links { print("LIVE    link: \(link.title) — \(link.url.absoluteString)") }
        if let note = intent.linkNote, intent.links.isEmpty { print("LIVE    link note: \(note)") }
    }

    @Test(.enabled(if: IntentLiveTests.storePath != nil), .timeLimit(.minutes(20)))
    func northwind() async throws {
        let container = try openCopy()
        let context = container.mainContext
        let match = Self.env["LIDIA_INTENTS_LIVE_TITLE"] ?? "Northwind"
        let start = Calendar.current.startOfDay(for: .now)
        let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date)]))
            .filter { $0.title.contains(match) && $0.date >= start && !$0.isDeleted }
        try #require(!meetings.isEmpty, "No \(match) meeting today in the copy")
        let store = IntentStore(url: URL(fileURLWithPath: try #require(Self.storePath)).deletingLastPathComponent().appendingPathComponent(IntentStore.fileName))

        print("LIVE ===== BEFORE (as extracted this morning)")
        for meeting in meetings {
            for item in meeting.actionItems { print("LIVE   [\(meeting.date.formatted(date: .omitted, time: .shortened))] \(item.title) · owner \(item.assignee ?? "-")") }
        }

        let modelID = Self.env["LIDIA_INTENTS_LIVE_MODEL"] ?? "mlx-community/Qwen3.5-4B-4bit"
        let manager = ModelManager(storage: ModelStorage(hubCacheDirectory: ModelStorage.appModelsDirectory))
        try await manager.loadModel(modelID)
        defer { manager.unloadModel() }
        let local = MLXLocalClient(modelManager: manager, preferredModelID: modelID)

        // 1. The check on the items as they are now (no re-summary).
        print("LIVE ===== CHECK of the existing items (\(ModelCatalog.entry(for: modelID)?.displayName ?? modelID))")
        for meeting in meetings where !meeting.actionItems.isEmpty {
            let responses = meeting.actionItems.map { MeetingSummaryResponse.ActionItemResponse(title: $0.title, assignee: $0.assignee, deadline: nil, sourceQuote: nil) }
            let checked = await ActionItemVerifier.verify(
                responses, words: meeting.rawTranscript, transcript: meeting.refinedTranscript,
                attendees: meeting.calendarAttendees ?? [], userName: Self.userName, client: local, model: modelID
            )
            for (index, item) in meeting.actionItems.enumerated() {
                let check = checked.checks[index]
                print("LIVE   \(item.title) → \(checked.items[index].title) · owner \(checked.items[index].assignee ?? "-") · \(check?.verdict.rawValue ?? "no transcript")\(check?.checkedBy != nil ? " (model-checked)" : "")")
                if let check {
                    store.setVerification(.init(verdict: check.verdict, evidence: check.evidence, originalTitle: check.originalTitle, originalAssignee: check.originalAssignee, checkedBy: check.checkedBy), for: item.id)
                }
            }
        }

        // 2. Optional: re-run the summary with the fixed prompts.
        if Self.env["LIDIA_INTENTS_LIVE_REPROCESS"] == "1", let longest = meetings.max(by: { $0.rawTranscript.count < $1.rawTranscript.count }) {
            print("LIVE ===== RE-SUMMARY of \(longest.title) at \(longest.date.formatted(date: .omitted, time: .shortened)) with the fixed prompts")
            let started = Date()
            let pipeline = MeetingPipeline(llmClient: local, modelContext: context)
            try await pipeline.process(meeting: longest, model: modelID, userName: Self.userName)
            print("LIVE   took \(Int(Date().timeIntervalSince(started)))s; Next Steps:")
            for line in SummaryMarkdownParser.nextSteps(in: longest.summary) { print("LIVE   - \(line.assignee ?? "?"): \(line.title)") }
            for item in longest.actionItems {
                let verdict = IntentStore.shared.verification(for: item.id)
                print("LIVE   item: \(item.title) · owner \(item.assignee ?? "-") · \(verdict?.verdict.rawValue ?? "-")")
                if let verdict { store.setVerification(verdict, for: item.id) }
            }
        }

        // 3. Intents (deterministic), then drafts.
        let calendar = calendarSource()
        let settings = AppSettings()
        settings.displayName = Self.userName
        var connections = IntentConnections.current(settings: settings)
        connections.mail = .gmail // the owner uses Gmail on the web
        let events = IntentEngine.calendarEvents(calendar, now: .now)
        var intents: [(ActionIntent, IntentInput)] = []
        for meeting in meetings where !meeting.actionItems.isEmpty {
            for input in IntentEngine.inputs(for: meeting, items: meeting.actionItems.filter { !$0.isCompleted }, userName: Self.userName, store: store) {
                var intent = IntentBuilder.build(input, connections: connections, events: events)
                intent.inputFingerprint = IntentEngine.fingerprint(input, connections: connections, now: .now)
                intents.append((intent, input))
            }
        }

        // A Claude draft from an earlier run is reused rather than paid for again.
        if let path = Self.env["LIDIA_INTENTS_LIVE_PRIOR"] {
            let prior = IntentStore(url: URL(fileURLWithPath: path))
            for index in intents.indices {
                if let old = prior.intent(for: intents[index].0.itemID), old.draftedBy?.hasPrefix("claude") == true, old.kind == intents[index].0.kind {
                    intents[index].0.artifact = old.artifact
                    intents[index].0.links = old.links
                    intents[index].0.linkNote = old.linkNote
                    intents[index].0.draftedBy = old.draftedBy
                    intents[index].0.usedWebSearch = old.usedWebSearch
                    print("LIVE reused the \(old.draftedBy ?? "") draft from \(path.split(separator: "/").last ?? "")")
                }
            }
        }

        let localEndpoint = AgentEndpoints.endpoint(client: local, model: modelID, label: ModelCatalog.entry(for: modelID)?.displayName, providerName: "On-device model (MLX)", locality: .onDevice)
        var claudeUsed = false
        for index in intents.indices {
            let (intent, input) = intents[index]
            guard IntentEngine.wantsDraft(intent), intent.draftedBy == nil else { continue }
            if Self.env["LIDIA_INTENTS_LIVE_CLAUDE"] == "1", !claudeUsed, intent.kind == .message, let key = Self.env["ANTHROPIC_API_KEY"], !key.isEmpty {
                claudeUsed = true
                let endpoint = AgentEndpoints.endpoint(client: AnthropicClient(apiKey: key), model: "claude-sonnet-5-5", providerName: "Anthropic", locality: .cloud)
                if let drafted = await IntentEngine.draft(intent, input: input, endpoint: endpoint, webSearch: true, context: context, calendar: calendar, settings: nil) {
                    intents[index].0 = drafted
                    continue
                }
            }
            if let drafted = await IntentEngine.draft(intent, input: input, endpoint: localEndpoint, webSearch: false, context: context, calendar: calendar, settings: nil) {
                intents[index].0 = drafted
            }
        }

        // 4. Today's untitled notes get a title from the local model.
        let untitled = try context.fetch(FetchDescriptor<Meeting>())
            .filter { $0.date >= start && NoteAutoTitle.isPlaceholder($0.title) && $0.notes.count >= NoteAutoTitle.minimumContent }
        for note in untitled {
            let reply = try await local.chat(
                messages: [LLMChatMessage(role: "system", content: NoteAutoTitle.systemPrompt), LLMChatMessage(role: "user", content: note.notes)],
                model: modelID, format: nil
            )
            guard let title = NoteAutoTitle.clean(reply) else { continue }
            print("LIVE ===== NOTE TITLE: “\(note.title)” → “\(title)” (from \(note.notes.count) characters)")
            store.setAITitle(title, contentLength: note.notes.count, for: note.id)
            note.title = title
        }
        try context.save()

        print("LIVE ===== AFTER: intents")
        for (intent, input) in intents {
            describe(intent, title: input.title)
            store.setIntent(intent)
        }
        store.saveNow()
        print("LIVE wrote \(store.url?.path ?? "-")")
        #expect(!intents.isEmpty)
    }
}
