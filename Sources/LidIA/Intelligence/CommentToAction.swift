import Foundation
import SwiftData

/// "Comment to AI" on an action item card: the user writes what they want
/// ("open a ticket for this in ClickUp") and LidIA turns it into one concrete
/// action that the user confirms before anything happens.
///
/// A deterministic reading comes first; AI (low effort, gated) only refines
/// the destination and title when it's available. Either way the result is a
/// proposal: `ActionProposalSheet` shows it and nothing runs until Confirm.
struct ActionProposal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Send through `ActionItemDispatcher` ("clickup", "notion", "reminder", "n8n").
        case dispatch(destination: String)
        /// Draft a follow-up email (opens in Mail; nothing is sent).
        case email
        /// Move the card.
        case move(ActionItemStatus)
    }

    var kind: Kind
    /// Ticket / reminder title.
    var title: String
    /// Extra description to include.
    var note: String?
    /// Whether AI wrote this proposal (else LidIA's own reading).
    var byAI = false

    /// Leaves this Mac when confirmed (Local-only mode blocks these).
    var isOutbound: Bool {
        if case .dispatch(let destination) = kind { return destination != "reminder" }
        return false
    }

    var destinationName: String {
        switch kind {
        case .dispatch(let destination): CommentToAction.displayName(destination)
        case .email: "Mail"
        case .move(let status): status.title
        }
    }

    /// "Create a ClickUp task", "Move to In Progress"…
    var summary: String {
        switch kind {
        case .dispatch("clickup"): "Create a ClickUp task"
        case .dispatch("notion"): "Add to your Notion tasks"
        case .dispatch("reminder"): "Add an Apple Reminder"
        case .dispatch("n8n"): "Send to your n8n workflow"
        case .dispatch(let other): "Send to \(other)"
        case .email: "Draft a follow-up email"
        case .move(let status): "Move to \(status.title)"
        }
    }
}

enum CommentToAction {
    /// Destinations the user has set up.
    struct Available: Equatable, Sendable {
        var clickUp = false
        var notion = false
        var n8n = false
        var reminders = true
    }

    static func displayName(_ destination: String) -> String {
        switch destination {
        case "clickup": "ClickUp"
        case "notion": "Notion"
        case "reminder": "Apple Reminders"
        case "n8n": "n8n"
        default: destination
        }
    }

    /// LidIA's own reading of a comment. Nil when it can't tell what's wanted.
    static func interpret(_ comment: String, itemTitle: String, available: Available) -> ActionProposal? {
        let text = comment.lowercased()
        let title = quotedText(in: comment) ?? itemTitle

        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        if has("clickup", "click up") { return ActionProposal(kind: .dispatch(destination: "clickup"), title: title, note: noteText(comment)) }
        if has("notion") { return ActionProposal(kind: .dispatch(destination: "notion"), title: title, note: noteText(comment)) }
        if has("n8n", "webhook", "workflow", "automation") { return ActionProposal(kind: .dispatch(destination: "n8n"), title: title, note: noteText(comment)) }
        if has("remind", "reminder") { return ActionProposal(kind: .dispatch(destination: "reminder"), title: title, note: nil) }
        if has("email", "e-mail", "mail ", "follow up with", "follow-up email", "write to", "send a note") {
            return ActionProposal(kind: .email, title: title, note: noteText(comment))
        }
        if has("ticket", "task", "issue", "jira", "linear") {
            // The tracker the user has: ClickUp, else Notion, else a reminder.
            let destination = available.clickUp ? "clickup" : (available.notion ? "notion" : "reminder")
            return ActionProposal(kind: .dispatch(destination: destination), title: title, note: noteText(comment))
        }
        if has("in progress", "start", "working on") { return ActionProposal(kind: .move(.inProgress), title: itemTitle) }
        if has("waiting", "blocked", "on hold") { return ActionProposal(kind: .move(.waiting), title: itemTitle) }
        if has("done", "complete", "finished", "close") { return ActionProposal(kind: .move(.done), title: itemTitle) }
        return nil
    }

    /// Reads AI's JSON answer, keeping only known destinations and a sane title.
    static func parseAI(_ object: [String: Any], itemTitle: String) -> ActionProposal? {
        guard let action = (object["action"] as? String)?.lowercased() else { return nil }
        let rawTitle = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty || rawTitle.count > 140 ? itemTitle : rawTitle
        let note = (object["note"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(500)) }
        switch action {
        case "clickup", "notion", "reminder", "n8n":
            return ActionProposal(kind: .dispatch(destination: action), title: title, note: note, byAI: true)
        case "email":
            return ActionProposal(kind: .email, title: title, note: note, byAI: true)
        case "in_progress", "inprogress":
            return ActionProposal(kind: .move(.inProgress), title: itemTitle, byAI: true)
        case "waiting":
            return ActionProposal(kind: .move(.waiting), title: itemTitle, byAI: true)
        case "done":
            return ActionProposal(kind: .move(.done), title: itemTitle, byAI: true)
        default:
            return nil
        }
    }

    /// AI's reading of the comment, falling back to LidIA's own. Runs the
    /// agent harness (low effort, gated client) with only `propose_dispatch`
    /// and `update_action_item_status`: the model sees the item's title, its
    /// meeting's title and date, and the comment, and can only draft. The
    /// returned transcript shows exactly what was sent.
    @MainActor
    static func propose(
        comment: String,
        itemID: UUID,
        itemTitle: String,
        meetingTitle: String,
        meetingDate: Date,
        available: Available,
        settings: AppSettings,
        modelManager: ModelManager? = nil,
        modelContext: ModelContext
    ) async -> (proposal: ActionProposal?, transcript: AgentTranscript?) {
        let own = interpret(comment, itemTitle: itemTitle, available: available)
        guard IntelligenceLLM.unavailableReason(settings: settings) == nil else { return (own, nil) }
        let destinations = AgentDestinations(clickUp: available.clickUp, notion: available.notion, n8n: available.n8n)
        let endpoint = AgentEndpoints.resolve(settings: settings, modelManager: modelManager)
        var configuration = AgentHarness.Configuration.standard(for: endpoint.family, locality: endpoint.locality)
        configuration.maxSteps = 3
        let harness = AgentHarness(endpoint: endpoint, tools: LidIATools.commentTools(destinations: destinations), configuration: configuration)
        let message = """
        Action item [\(LidIATools.shortID(itemID))]: \(itemTitle)
        Meeting: \(meetingTitle), \(AgentDates.day(meetingDate))
        Comment: \(comment)
        """
        let result = await harness.run(
            prompt: AgentPromptContext(task: .comment, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps, userName: settings.displayName),
            history: [],
            userMessage: message,
            context: AgentToolContext(modelContext: modelContext, settings: settings, destinations: destinations)
        )
        return (AgentDispatch.proposal(from: result, itemTitle: itemTitle) ?? own, result.transcript)
    }

    // MARK: - Pieces

    /// Text in quotes becomes the title: open a ticket "Fix SSO login".
    static func quotedText(in comment: String) -> String? {
        guard let match = comment.firstMatch(of: /["“'‘](.{3,140}?)["”'’]/) else { return nil }
        return String(match.1)
    }

    /// The comment itself, as context for the ticket.
    private static func noteText(_ comment: String) -> String? {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 12 ? trimmed : nil
    }
}
