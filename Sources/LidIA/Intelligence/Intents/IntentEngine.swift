import Foundation
import Observation
import SwiftData
import os

/// Works out intents for open action items in the background: the
/// deterministic part at once, then (when a model is available) a drafted
/// message or page through the agent harness. Results go to `IntentStore`.
///
/// Routing: drafting uses the "Follow-up drafts" route (Hybrid sends long
/// writing to the cloud), at effort low. Claude's web search runs only when
/// that route is a Claude model the cloud is allowed for; otherwise the
/// draft says "[add a link]".
@MainActor
@Observable
final class IntentEngine {
    static let shared = IntentEngine(store: .shared)

    private static let logger = Logger(subsystem: "io.lidia.app", category: "IntentEngine")

    let store: IntentStore
    /// Items being worked on now (the card shows a spinner).
    private(set) var working: Set<UUID> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: IntentStore) {
        self.store = store
    }

    struct Environment {
        var settings: AppSettings
        var modelManager: ModelManager?
        var calendar: (any IntentCalendarSource)?
        var modelContext: ModelContext
        /// Draft with a model. Off in tests and design snapshots.
        var useModel: Bool
        var now: Date = .now
        /// Keep any cached intent as is (design snapshots show recorded runs).
        var keepCached = false
    }

    /// Refreshes the intents of these meetings' open items, in the background.
    /// A newer call replaces a running one.
    func scheduleRefresh(meetingIDs: [UUID], environment: Environment) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh(meetingIDs: meetingIDs, environment: environment)
        }
    }

    /// Recomputes what changed. Deterministic intents are saved at once;
    /// drafts follow, one item at a time.
    func refresh(meetingIDs: [UUID], environment: Environment) async {
        let connections = IntentConnections.current(settings: environment.settings)
        var drafting: [(UUID, IntentInput)] = []
        for meetingID in meetingIDs {
            guard let meeting = LiveModel.meeting(meetingID, in: environment.modelContext) else { continue }
            let items = meeting.actionItems.filter { !$0.isDeleted && !$0.isCompleted }
            guard !items.isEmpty else { continue }
            let input = Self.inputs(for: meeting, items: items, userName: environment.settings.displayName, store: store)
            let events = Self.calendarEvents(environment.calendar, now: environment.now)
            for itemInput in input {
                let fingerprint = Self.fingerprint(itemInput, connections: connections, now: environment.now)
                if let cached = store.intent(for: itemInput.itemID), cached.inputFingerprint == fingerprint || environment.keepCached { continue }
                var intent = IntentBuilder.build(itemInput, connections: connections, events: events, now: environment.now)
                intent.inputFingerprint = fingerprint
                store.setIntent(intent)
                // Drafting costs a model call: only for recent meetings.
                if environment.useModel, Self.wantsDraft(intent), environment.now.timeIntervalSince(meeting.date) < Self.draftWindow {
                    drafting.append((itemInput.itemID, itemInput))
                }
            }
        }
        for (itemID, input) in drafting {
            guard !Task.isCancelled, let intent = store.intent(for: itemID) else { continue }
            working.insert(itemID)
            let drafted = await draft(intent, input: input, environment: environment)
            working.remove(itemID)
            if let drafted, store.intent(for: itemID)?.inputFingerprint == intent.inputFingerprint {
                store.setIntent(drafted)
            }
        }
    }

    static func wantsDraft(_ intent: ActionIntent) -> Bool {
        guard !intent.verdict.needsReview, intent.ownerIsUser || intent.direction == .othersOweUser else { return false }
        switch intent.artifact {
        case .message, .document, .ticket, .research: return true
        default: return false
        }
    }

    // MARK: - Inputs

    static func inputs(for meeting: Meeting, items: [ActionItem], userName: String, store: IntentStore) -> [IntentInput] {
        let words = meeting.rawTranscript
        let turns = words.isEmpty
            ? TranscriptTimeline.turns(fromText: LidIATools.transcriptText(meeting), userName: userName)
            : TranscriptTimeline.turns(from: words, userName: userName)
        let attendees = AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: userName)
        let summary = LidIATools.summaryText(meeting)
        return items.map { item in
            IntentInput(
                itemID: item.id, meetingID: meeting.id, title: item.title, assignee: item.assignee,
                meetingTitle: meeting.title, meetingDate: meeting.date, attendees: attendees,
                turns: turns, userName: userName, summary: summary,
                verification: store.verification(for: item.id),
                hasTimedTranscript: !words.isEmpty
            )
        }
    }

    static func calendarEvents(_ source: (any IntentCalendarSource)?, now: Date) -> [IntentCalendarEvent] {
        guard let source, source.isAvailable else { return [] }
        let start = Calendar.current.startOfDay(for: now)
        return source.events(from: start, to: start.addingTimeInterval(16 * 86_400))
    }

    static func fingerprint(_ input: IntentInput, connections: IntentConnections, now: Date) -> String {
        var hasher = Hasher()
        hasher.combine(input.title)
        hasher.combine(input.assignee)
        hasher.combine(input.turns.count)
        hasher.combine(input.summary.count)
        hasher.combine(input.verification?.verdict)
        hasher.combine(input.userName)
        hasher.combine(connections.fingerprint)
        // Free time changes daily.
        hasher.combine(Calendar.current.startOfDay(for: now))
        return String(hasher.finalize(), radix: 36) + "-v\(builderVersion)"
    }

    static let builderVersion = 4
    /// Meetings older than this get intents but no model draft.
    static let draftWindow: TimeInterval = 10 * 86_400

    // MARK: - Drafting

    /// Rewrites the template draft with a model through the agent harness.
    func draft(_ intent: ActionIntent, input: IntentInput, environment: Environment) async -> ActionIntent? {
        let endpoint = AgentEndpoints.resolve(settings: environment.settings, modelManager: environment.modelManager, taskType: .followUp)
        let webSearch = Self.allowsWebSearch(endpoint: endpoint, settings: environment.settings)
        return await Self.draft(intent, input: input, endpoint: endpoint, webSearch: webSearch, context: environment.modelContext, calendar: environment.calendar, settings: environment.settings)
    }

    /// Claude's web search, only when this route already sends to Claude and
    /// the cloud is allowed.
    static func allowsWebSearch(endpoint: AgentHarness.Endpoint, settings: AppSettings?) -> Bool {
        guard endpoint.locality == .cloud, endpoint.backend.kind == .anthropicTools else { return false }
        return !(settings?.localOnlyMode ?? PrivacyGate.isLocalOnly)
    }

    static func draft(
        _ intent: ActionIntent,
        input: IntentInput,
        endpoint: AgentHarness.Endpoint,
        webSearch: Bool,
        context: ModelContext,
        calendar: (any IntentCalendarSource)?,
        settings: AppSettings?
    ) async -> ActionIntent? {
        let box = IntentToolBox()
        box.turns[input.meetingID] = input.turns
        box.meetingStarts[input.meetingID] = input.meetingDate
        box.calendar = calendar
        box.userName = input.userName
        var configuration = AgentHarness.Configuration.standard(for: endpoint.family, effort: .low, locality: endpoint.locality)
        configuration.maxSteps = webSearch ? 4 : 3
        if webSearch { configuration.serverTools = [.webSearch(maxUses: 2)] }
        let harness = AgentHarness(endpoint: endpoint, tools: IntentTools.all(box: box), configuration: configuration)
        let result = await harness.run(
            prompt: AgentPromptContext(task: .intent, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps, userName: input.userName),
            history: [],
            userMessage: brief(intent, input: input, webSearch: webSearch),
            context: AgentToolContext(modelContext: context, settings: settings)
        )
        guard let draft = box.drafts.last else {
            logger.info("Intent draft: no draft (\(result.outcome.rawValue, privacy: .public))")
            return nil
        }
        var updated = intent
        let (body, links) = keepRealLinks(draft.body, results: result.webResults)
        switch intent.artifact {
        case .message:
            updated.artifact = .message(subject: draft.subject.isEmpty ? subject(of: intent) : draft.subject, body: body)
        case .document(let title, _):
            if intent.primaryDestination?.id == "notion" {
                updated.artifact = .document(title: draft.subject.isEmpty ? title : draft.subject, body: body)
            } else {
                updated.artifact = .message(subject: draft.subject.isEmpty ? title : draft.subject, body: body)
            }
        case .ticket(let title, _):
            updated.artifact = .ticket(title: draft.subject.isEmpty ? title : draft.subject, body: body)
        case .research:
            updated.artifact = .research(notes: body)
        default:
            break
        }
        updated.links = links
        updated.usedWebSearch = webSearch && !result.webResults.isEmpty
        if !links.isEmpty { updated.linkNote = nil }
        updated.draftedBy = endpoint.modelLabel
        return updated
    }

    static func subject(of intent: ActionIntent) -> String {
        if case .message(let subject, _) = intent.artifact { return subject }
        return ""
    }

    /// Keeps only URLs that came from a web search; anything else becomes
    /// "[add a link]". Returns the cleaned body and the links it uses (or the
    /// top results when it uses none).
    nonisolated static func keepRealLinks(_ body: String, results: [AgentWebResult]) -> (String, [ActionIntent.Link]) {
        let known = Set(results.map { normalized($0.url) })
        var cleaned = body
        var used: [ActionIntent.Link] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed()
            for match in matches {
                guard let url = match.url, let range = Range(match.range, in: cleaned) else { continue }
                if known.contains(normalized(url)), let result = results.first(where: { normalized($0.url) == normalized(url) }) {
                    used.insert(ActionIntent.Link(title: result.title, url: result.url), at: 0)
                } else if url.scheme?.hasPrefix("http") == true {
                    cleaned.replaceSubrange(range, with: "[add a link]")
                }
            }
        }
        if used.isEmpty { used = results.prefix(2).map { ActionIntent.Link(title: $0.title, url: $0.url) } }
        return (cleaned, used)
    }

    nonisolated private static func normalized(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "")
    }

    /// The facts the model drafts from. Everything is in the transcript.
    /// (Summary bullets can carry the summary's own mistakes; the user's
    /// words from the transcript come first.)
    static func brief(_ intent: ActionIntent, input: IntentInput, webSearch: Bool) -> String {
        var lines: [String] = []
        lines.append("Action item: \(intent.suggestedTitle ?? input.title)")
        if intent.suggestedTitle != nil { lines.append("(The notes wrote it as \"\(input.title)\", but the transcript shows the user owes it.)") }
        lines.append("Meeting [\(LidIATools.shortID(input.meetingID))]: \(input.meetingTitle), \(AgentDates.day(input.meetingDate))")
        let who = intent.recipients.map { person in person.email.map { "\(person.name) <\($0)>" } ?? person.name }.joined(separator: ", ")
        switch intent.direction {
        case .userOwes: lines.append("The user (\(input.userName.isEmpty ? "me" : input.userName)) does it, for: \(who.isEmpty ? (intent.recipientLabel ?? "the other attendees") : who)")
        case .othersOweUser: lines.append("\(intent.owner ?? "Someone") owes it to the user: write a short, friendly nudge from the user.")
        default: break
        }
        lines.append("Kind: \(intent.kind.rawValue). Goes to: \(intent.primaryDestination?.name ?? "email").")
        for evidence in intent.evidence.prefix(2) {
            lines.append("Said\(evidence.offsetLabel.map { " at \($0)" } ?? "")\(evidence.speaker.map { " by \($0)\(evidence.speakerIsUser == true ? " (the user)" : "")" } ?? ""): \"\(evidence.quote)\"")
        }
        // What the user already said about it: the substance of the follow-up.
        if let offset = intent.bestEvidence?.offset, let index = input.turns.firstIndex(where: { $0.start == offset }) {
            let said = input.turns[(index + 1)...].prefix(4).filter { $0.isUser == true }.prefix(2).map(\.text).joined(separator: " ")
            if !said.isEmpty { lines.append("What the user said about it in the meeting: \"\(String(said.prefix(900)))\"") }
        }
        let bullets = IntentBuilder.relevantBullets(input.summary, title: intent.suggestedTitle ?? input.title, exclude: [input.userName], limit: 3)
        if !bullets.isEmpty { lines.append("From the meeting notes:\n" + bullets.map { "- " + $0 }.joined(separator: "\n")) }
        switch intent.artifact {
        case .message(let subject, let body), .document(let subject, let body), .ticket(let subject, let body):
            lines.append("Starting draft (improve it):\nSubject: \(subject)\n\(body)")
        default: break
        }
        lines.append(webSearch
            ? "Search the web once for one good public reference to link, if it helps the reader."
            : "You can't search the web: where a link would help, write [add a link].")
        lines.append("Call draft_message now.")
        return lines.joined(separator: "\n")
    }
}
