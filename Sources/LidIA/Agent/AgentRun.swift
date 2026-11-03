import Foundation
import Observation

/// A meeting a tool returned or read: the structured source of an answer.
/// Recurring meetings share titles, so the ID and date tell them apart.
struct AgentMeetingRef: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var date: Date
    /// The passage that matched (search) or was read (get_meeting).
    var excerpt: String?
}

/// Something the user decides before anything happens: a change the agent
/// prepared, a drafted dispatch, or a clarifying question.
struct AgentApproval: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A mutating tool call waiting for Confirm.
        case change(AgentPendingAction)
        /// A `propose_dispatch` draft waiting to be sent.
        case dispatch(AgentDispatchProposal)
        /// The agent asked the user to choose or clarify (`ask_user`).
        case clarification
    }

    struct Option: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var isPrimary = false
        var isCancel = false
    }

    enum Choice: Sendable, Equatable {
        case option(String)
        case freeText(String)
    }

    enum State: Sendable, Equatable {
        case pending
        /// Done, with what happened ("Created …", "Dismissed").
        case resolved(String)
        case failed(String)
    }

    var id = UUID()
    var kind: Kind
    var question: String
    var options: [Option]
    /// Offer a free-text "Something else…" answer.
    var allowsFreeText: Bool
    var state: State = .pending
}

/// One answer as it happens, for the Ask / chat UI: phase and timing, steps,
/// reasoning summary, streaming answer, structured sources, follow-ups,
/// approvals, and the model and where it ran. The harness updates it live on
/// the main actor; the finished transcript is attached at the end.
@MainActor
@Observable
final class AgentRun: Identifiable {
    enum Phase: String, Sendable {
        case thinking
        case searching
        case answering
        case waitingForApproval
        case done
        case failed
        case cancelled
    }

    struct Step: Identifiable, Sendable, Equatable {
        enum Status: String, Sendable {
            case running
            case succeeded
            case failed
            /// A change prepared for the user to confirm.
            case awaitingApproval
        }

        var id: String
        var toolName: String
        /// "Searched meetings: Northwind, last 30 days".
        var summary: String
        var argumentsJSON: String
        var status: Status
        var startedAt: Date
        var duration: TimeInterval?
        var resultCount: Int?
    }

    nonisolated let id = UUID()
    let question: String
    private(set) var phase: Phase = .thinking
    let startedAt: Date
    private(set) var finishedAt: Date?
    private(set) var steps: [Step] = []
    /// A user-presentable reasoning summary, when the model gives one
    /// (Claude's summarized thinking). Empty otherwise.
    private(set) var reasoningSummary = ""
    /// The answer as it streams; the final text when done.
    private(set) var answer = ""
    private(set) var sources: [AgentMeetingRef] = []
    /// Meetings tools returned so far (read with get_meeting, or only seen in
    /// results), so the UI can cite and show context while the answer streams.
    private(set) var meetingsRead: [AgentMeetingRef] = []
    private(set) var meetingsSeen: [AgentMeetingRef] = []
    private(set) var followUps: [String] = []
    private(set) var approvals: [AgentApproval] = []
    /// "Qwen 3.5 4B" (the resolved model, never "automatic").
    let modelLabel: String
    let providerName: String
    let locality: DataLocality
    private(set) var transcript: AgentTranscript?
    private(set) var errorMessage: String?

    /// Runs an approval choice (set by whoever owns the run). Returns what
    /// happened, shown on the approval.
    var onApproval: (@MainActor (AgentApproval, AgentApproval.Choice) async -> AgentApproval.State)?

    /// `startedAt` is for fixtures (snapshots, tests); runs start now.
    init(question: String, modelLabel: String, providerName: String, locality: DataLocality, startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.question = question
        self.modelLabel = modelLabel
        self.providerName = providerName
        self.locality = locality
    }

    /// Seconds since the run started (frozen when it ends).
    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    /// "Qwen 3.5 4B · On this Mac".
    var modelAndLocality: String { "\(modelLabel) · \(locality.label)" }

    var isFinished: Bool { finishedAt != nil }

    // MARK: Updates (harness)

    func appendAnswer(_ text: String) {
        answer += text
        if phase == .thinking || phase == .searching { phase = .answering }
    }

    func resetAnswer() { answer = "" }

    func appendReasoning(_ text: String) { reasoningSummary += text }

    func stepStarted(_ step: Step) {
        steps.append(step)
        phase = .searching
    }

    func stepFinished(id: String, status: Step.Status, summary: String?, resultCount: Int?) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].status = status
        steps[index].duration = Date().timeIntervalSince(steps[index].startedAt)
        if let summary { steps[index].summary = summary }
        steps[index].resultCount = resultCount
        if phase == .searching, !steps.contains(where: { $0.status == .running }) { phase = .thinking }
    }

    /// Meetings a tool returned (additive; the final sources still come with `finish`).
    func noteMeetings(_ refs: [AgentMeetingRef], read: Bool) {
        guard !refs.isEmpty else { return }
        if read { meetingsRead += refs } else { meetingsSeen += refs }
    }

    /// The sources as they stand: the final ones when done, else the same rule
    /// applied to what tools returned so far (so numbering doesn't jump).
    var liveSources: [AgentMeetingRef] {
        if isFinished { return sources }
        return AgentRunPresentation.sources(read: meetingsRead, seen: meetingsSeen, answer: answer)
    }

    func finish(
        answer: String,
        sources: [AgentMeetingRef],
        followUps: [String],
        approvals: [AgentApproval],
        transcript: AgentTranscript
    ) {
        self.answer = answer
        self.sources = sources
        self.followUps = followUps
        self.approvals = approvals
        self.transcript = transcript
        errorMessage = transcript.errorMessage
        finishedAt = Date()
        switch transcript.outcome {
        case .answered, .stepLimit, .deadline:
            phase = approvals.isEmpty ? .done : .waitingForApproval
        case .cancelled:
            phase = .cancelled
        case .failed:
            phase = .failed
        }
    }

    // MARK: Approvals (UI)

    /// The user's answer to an approval. Runs nothing unless the owner's
    /// handler does; a cancel option just resolves it.
    func respond(to approvalID: UUID, with choice: AgentApproval.Choice) async {
        guard let index = approvals.firstIndex(where: { $0.id == approvalID }), approvals[index].state == .pending else { return }
        let approval = approvals[index]
        let state: AgentApproval.State
        if case .option(let optionID) = choice, approval.options.first(where: { $0.id == optionID })?.isCancel == true {
            state = .resolved("Dismissed")
        } else if let onApproval {
            state = await onApproval(approval, choice)
        } else {
            state = .failed("Nothing can handle this here.")
        }
        guard let current = approvals.firstIndex(where: { $0.id == approvalID }) else { return }
        approvals[current].state = state
        if !approvals.contains(where: { $0.state == .pending }), phase == .waitingForApproval { phase = .done }
    }
}

extension AgentRun: Equatable {
    nonisolated static func == (lhs: AgentRun, rhs: AgentRun) -> Bool { lhs === rhs }
}

// MARK: - Derived pieces

enum AgentRunPresentation {
    /// Approvals for what a run left waiting.
    static func approvals(pending: [AgentPendingAction], proposals: [AgentDispatchProposal], clarification: AgentClarification?) -> [AgentApproval] {
        var result: [AgentApproval] = pending.map { action in
            AgentApproval(
                kind: .change(action),
                question: action.summary + "?",
                options: [
                    .init(id: "confirm", label: "Confirm", isPrimary: true),
                    .init(id: "cancel", label: "Cancel", isCancel: true),
                ],
                allowsFreeText: false
            )
        }
        result += proposals.map { proposal in
            let verb: String
            switch proposal.destination {
            case "clickup": verb = "Create a ClickUp task"
            case "notion": verb = "Add to Notion"
            case "reminder": verb = "Add an Apple Reminder"
            case "n8n": verb = "Send to n8n"
            case "email": verb = "Draft an email"
            default: verb = "Send"
            }
            return AgentApproval(
                kind: .dispatch(proposal),
                question: "\(verb): “\(proposal.title)”?",
                options: [
                    .init(id: "confirm", label: proposal.destination == "email" ? "Open in Mail" : "Send", isPrimary: true),
                    .init(id: "cancel", label: "Cancel", isCancel: true),
                ],
                allowsFreeText: true
            )
        }
        if let clarification {
            result.append(AgentApproval(
                kind: .clarification,
                question: clarification.question,
                options: clarification.options.enumerated().map { .init(id: "option\($0.offset)", label: $0.element, isPrimary: $0.offset == 0) },
                allowsFreeText: true
            ))
        }
        return result
    }

    /// The answer's sources: meetings the agent read, else those the answer
    /// names (by title or date), deduplicated by ID, newest first.
    static func sources(read: [AgentMeetingRef], seen: [AgentMeetingRef], answer: String) -> [AgentMeetingRef] {
        func unique(_ refs: [AgentMeetingRef]) -> [AgentMeetingRef] {
            var ids = Set<UUID>()
            return refs.filter { ids.insert($0.id).inserted }
        }
        if !read.isEmpty { return unique(read) }
        let mentioned = seen.filter { ref in
            answer.localizedCaseInsensitiveContains(ref.title) || answer.contains(AgentDates.day(ref.date))
        }
        return unique(mentioned).sorted { $0.date > $1.date }
    }

    /// Two or three follow-up questions derived from what the run did (no
    /// extra model call).
    static func followUps(question: String, toolsUsed: [String], sources: [AgentMeetingRef], hasApprovals: Bool) -> [String] {
        var ideas: [String] = []
        if let meeting = sources.first {
            let title = meeting.title.count > 40 ? String(meeting.title.prefix(39)) + "…" : meeting.title
            if !toolsUsed.contains("list_action_items") {
                ideas.append("What are the action items from “\(title)” on \(AgentDates.day(meeting.date))?")
            }
            ideas.append("Draft a follow-up email for “\(title)”")
            if sources.count == 1 { ideas.append("What did we discuss the time before that?") }
        }
        if toolsUsed.contains("list_action_items") {
            ideas.append("Which of these are overdue?")
            ideas.append("Which of these came from this week's meetings?")
        }
        if toolsUsed.contains("list_projects") {
            ideas.append("Which project has the most open items?")
        }
        if hasApprovals { ideas.removeAll { $0.hasPrefix("Draft") } }
        var seen = Set<String>()
        return ideas.filter { seen.insert($0).inserted && $0 != question }.prefix(3).map { $0 }
    }

    /// One line per step: "Searched meetings: Northwind, since 2026-10-01".
    static func stepSummary(tool: String, arguments: AgentArguments?, output: AgentToolOutput?) -> String {
        let a = arguments ?? AgentArguments()
        switch tool {
        case "search_meetings":
            var parts: [String] = []
            if let query = a.string("query") { parts.append(query) }
            if let person = a.string("person") { parts.append("with \(person)") }
            switch (a.string("from"), a.string("to")) {
            case let (from?, to?): parts.append("\(from) to \(to)")
            case let (from?, nil): parts.append("since \(from)")
            case let (nil, to?): parts.append("until \(to)")
            default: break
            }
            return parts.isEmpty ? "Listed recent meetings" : "Searched meetings: " + parts.joined(separator: ", ")
        case "get_meeting":
            if let ref = output?.meetings.first { return "Read “\(ref.title)”, \(AgentDates.day(ref.date))" }
            return "Read a meeting"
        case "list_action_items":
            var parts = [a.string("status") ?? "open"]
            if let assignee = a.string("assignee") { parts.append("owner \(assignee)") }
            if let project = a.string("project") { parts.append("project \(project)") }
            return "Listed action items: " + parts.joined(separator: ", ")
        case "list_projects":
            return "Listed projects"
        case "create_action_item":
            return "Prepared a new action item: \(a.string("title") ?? "")"
        case "update_action_item_status":
            return "Prepared a status change: \(a.string("status") ?? "")"
        case "propose_dispatch":
            return "Drafted a \(CommentToAction.displayName(a.string("destination") ?? "")) proposal"
        case "ask_user":
            return "Asked you to choose"
        default:
            return tool
        }
    }
}

/// A clarifying question from `ask_user`.
struct AgentClarification: Sendable, Equatable {
    var question: String
    var options: [String]
}
