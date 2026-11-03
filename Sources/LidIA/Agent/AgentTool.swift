import Foundation
import SwiftData

/// What running a tool does to the world.
enum AgentToolEffect: String, Codable, Sendable {
    /// Reads the library. Runs as soon as the model calls it.
    case readOnly
    /// Drafts something (a dispatch proposal) without changing or sending
    /// anything. Runs immediately; its result is a proposal the user confirms.
    case proposal
    /// Changes the library. Never runs during the loop: the call becomes a
    /// pending action that runs only when the user confirms it.
    case mutating
}

/// What a tool hands back.
struct AgentToolOutput: Sendable {
    /// What the model sees.
    var text: String
    /// A dispatch proposal (from `propose_dispatch`).
    var proposal: AgentDispatchProposal?
    /// Meetings the result returned (structured sources).
    var meetings: [AgentMeetingRef] = []
    /// How many results it found (shown on the step).
    var resultCount: Int?
    /// A question for the user (from `ask_user`); ends the run.
    var clarification: AgentClarification?

    init(
        _ text: String,
        proposal: AgentDispatchProposal? = nil,
        meetings: [AgentMeetingRef] = [],
        resultCount: Int? = nil,
        clarification: AgentClarification? = nil
    ) {
        self.text = text
        self.proposal = proposal
        self.meetings = meetings
        self.resultCount = resultCount
        self.clarification = clarification
    }
}

/// Everything a tool handler may use. Main actor: SwiftData models are
/// fetched and touched only here, and always re-fetched by ID (LiveModel rule),
/// never carried across an await.
@MainActor
final class AgentToolContext {
    let modelContext: ModelContext
    let settings: AppSettings?
    let destinations: AgentDestinations
    let now: Date

    init(modelContext: ModelContext, settings: AppSettings?, destinations: AgentDestinations = .init(), now: Date = .now) {
        self.modelContext = modelContext
        self.settings = settings
        self.destinations = destinations
        self.now = now
    }
}

/// Where `propose_dispatch` may send things: only what the user has set up.
struct AgentDestinations: Sendable, Equatable {
    var clickUp = false
    var notion = false
    var n8n = false

    /// Destination identifiers, in the order offered to the model.
    var identifiers: [String] {
        var list: [String] = []
        if clickUp { list.append("clickup") }
        if notion { list.append("notion") }
        list.append("reminder")
        if n8n { list.append("n8n") }
        list.append("email")
        return list
    }

    @MainActor
    static func configured(in settings: AppSettings) -> AgentDestinations {
        AgentDestinations(
            clickUp: !settings.clickUpAPIKey.isEmpty && !settings.clickUpListID.isEmpty,
            notion: !settings.notionAPIKey.isEmpty && !settings.notionTasksDatabaseID.isEmpty,
            n8n: settings.n8nEnabled && !settings.n8nWebhookURL.isEmpty
        )
    }
}

/// A tool: its spec, its effect and a Swift handler.
struct AgentTool: Sendable {
    typealias Handler = @MainActor @Sendable (AgentArguments, AgentToolContext) async throws -> AgentToolOutput
    typealias Describe = @MainActor @Sendable (AgentArguments, AgentToolContext) -> String

    let spec: AgentToolSpec
    let effect: AgentToolEffect
    let handler: Handler
    /// For mutating tools: one line saying what confirming will do.
    let describe: Describe?

    init(spec: AgentToolSpec, effect: AgentToolEffect, describe: Describe? = nil, handler: @escaping Handler) {
        self.spec = spec
        self.effect = effect
        self.describe = describe
        self.handler = handler
    }

    var name: String { spec.name }
}

/// The tools offered to one run.
struct AgentToolRegistry: Sendable {
    let tools: [AgentTool]

    init(_ tools: [AgentTool]) {
        // Names are unique; the first wins.
        var seen = Set<String>()
        self.tools = tools.filter { seen.insert($0.name).inserted }
    }

    var specs: [AgentToolSpec] { tools.map(\.spec) }

    subscript(name: String) -> AgentTool? { tools.first { $0.name == name } }

    func only(_ names: Set<String>) -> AgentToolRegistry { AgentToolRegistry(tools.filter { names.contains($0.name) }) }
}

// MARK: - Pending actions

/// A change the model asked for that waits for the user. Created when the
/// model calls a mutating tool; it runs only through `AgentHarness.confirm`,
/// which only UI code calls after the user confirms.
struct AgentPendingAction: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable {
        case pending
        case confirmed
        case dismissed
        case failed
    }

    var id = UUID()
    var toolName: String
    var argumentsJSON: String
    /// What confirming does, for the confirmation UI.
    var summary: String
    var state: State = .pending
    /// Result or failure message after confirming.
    var resultMessage: String?
}

/// What `propose_dispatch` drafts. Nothing is sent until the user confirms
/// it and `AgentDispatch.confirmAndDispatch` runs.
struct AgentDispatchProposal: Codable, Sendable, Equatable {
    /// "clickup", "notion", "reminder", "n8n" or "email".
    var destination: String
    var title: String
    var body: String
    var actionItemID: UUID?
}
