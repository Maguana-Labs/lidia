import Foundation

/// How the harness talks tools with a model.
enum AgentBackendKind: String, Codable, Sendable {
    /// Anthropic Messages API `tools` / `tool_use` / `tool_result`.
    case anthropicTools
    /// OpenAI-compatible `tools` / `tool_calls` (function calling).
    case openAITools
    /// Apple Foundation Models' native `Tool` protocol.
    case appleTools
    /// A compact JSON action format validated against the schema, for models
    /// without native tool calling (MLX Qwen / LFM, Ollama, CLI agents).
    case jsonActions

    var displayName: String {
        switch self {
        case .anthropicTools: "Anthropic tool use"
        case .openAITools: "OpenAI function calling"
        case .appleTools: "Apple Foundation Models tools"
        case .jsonActions: "JSON actions"
        }
    }
}

/// Exactly what one agent run sent and received. Shown by "View what was
/// sent", it is the proof of what left the Mac (or didn't).
struct AgentTranscript: Codable, Sendable, Identifiable, Equatable {
    struct ToolDefinition: Codable, Sendable, Equatable {
        var name: String
        var description: String
        var schemaJSON: String
        var effect: AgentToolEffect
    }

    /// One request to the model.
    struct ModelCall: Codable, Sendable, Equatable {
        var step: Int
        /// The request carried `messages[0..<sentMessageCount]`.
        var sentMessageCount: Int
        /// Tools were offered on this request (the last step offers none).
        var toolsOffered: Bool
        var outputText: String
        var toolCalls: [AgentToolCall]
        var seconds: Double
        var stopReason: String?
    }

    /// One tool call and what happened to it.
    struct ToolRun: Codable, Sendable, Equatable {
        enum Status: String, Codable, Sendable {
            case executed
            /// A mutating tool: waiting for the user's confirmation.
            case awaitingConfirmation
            case invalidArguments
            case unknownTool
            case failed
            /// Over the step/tool budget.
            case skipped
        }

        var step: Int
        var call: AgentToolCall
        var status: Status
        var result: String
        var seconds: Double
    }

    enum Entry: Codable, Sendable, Equatable {
        case modelCall(ModelCall)
        case toolRun(ToolRun)
        /// The JSON-action output was invalid; the model was asked once to fix it.
        case repair(step: Int, problem: String, rejectedOutput: String)
        case note(String)
    }

    enum Outcome: String, Codable, Sendable {
        case answered
        case stepLimit
        case deadline
        case cancelled
        case failed
    }

    var id = UUID()
    var startedAt = Date()
    var seconds: Double = 0
    var task: String
    var model: String
    var providerName: String
    var locality: DataLocality
    var backend: AgentBackendKind
    var profileID: String
    var profileVersion: String
    var effort: AgentEffort
    var maxSteps: Int
    var deadlineSeconds: Double
    var systemPrompt: String
    var tools: [ToolDefinition]
    /// The conversation as sent: history, the user's message, then every
    /// assistant and tool message of this run.
    var messages: [AgentMessage] = []
    var entries: [Entry] = []
    var outcome: Outcome = .answered
    var errorMessage: String?

    var modelCalls: [ModelCall] {
        entries.compactMap { if case .modelCall(let call) = $0 { call } else { nil } }
    }

    var toolRuns: [ToolRun] {
        entries.compactMap { if case .toolRun(let run) = $0 { run } else { nil } }
    }

    /// "On this Mac", "Your network server" or "Cloud provider, your key".
    var whereItRan: String { locality.label }

    /// The whole transcript as pretty JSON (for copying).
    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
