import Foundation
import FoundationModels

// Apple Foundation Models' native `Tool` protocol. The session runs its own
// tool loop; each LidIA tool is bridged to the harness, which validates,
// gates (mutating tools only queue a confirmation) and records every call.

/// One LidIA tool as an Apple `Tool`. Arguments arrive as `GeneratedContent`
/// shaped by a schema built from the tool's `AgentToolSpec`.
struct AppleAgentTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let run: AgentNativeToolRunner

    init(spec: AgentToolSpec, run: @escaping AgentNativeToolRunner) throws {
        self.name = spec.name
        self.description = spec.description
        self.parameters = try Self.schema(for: spec)
        self.run = run
    }

    func call(arguments: GeneratedContent) async throws -> String {
        await run(AgentToolCall(
            id: "apple_\(UUID().uuidString.prefix(8).lowercased())",
            name: name,
            argumentsJSON: arguments.jsonString
        ))
    }

    /// The tool's arguments as a generation schema. Optional arguments stay
    /// optional so the model can leave them out.
    static func schema(for spec: AgentToolSpec) throws -> GenerationSchema {
        let properties = spec.parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name,
                description: parameter.description,
                schema: propertySchema(parameter, toolName: spec.name),
                isOptional: !parameter.required
            )
        }
        let root = DynamicGenerationSchema(name: "\(spec.name)_arguments", description: spec.description, properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func propertySchema(_ parameter: AgentParameter, toolName: String) -> DynamicGenerationSchema {
        switch parameter.kind {
        case .string, .date:
            return DynamicGenerationSchema(type: String.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .oneOf(let values):
            return DynamicGenerationSchema(name: "\(toolName)_\(parameter.name)", anyOf: values)
        }
    }
}

struct AppleToolBackend: AgentBackend {
    var kind: AgentBackendKind { .appleTools }

    /// Room left for the answer inside Apple's small context.
    static let answerTokens = 600

    func turn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        let availability = AppleFoundationClient.availability
        guard availability == .available else { throw LLMError.setupRequired(availability.userMessage) }

        var tools: [any Tool] = []
        if let runTool = request.runTool {
            tools = try request.tools.map { try AppleAgentTool(spec: $0, run: runTool) }
        }
        let session = LanguageModelSession(tools: tools, instructions: request.system)
        let prompt = Self.prompt(from: request.messages)
        let options = GenerationOptions(temperature: Double(LLMTemperature.structured), maximumResponseTokens: Self.answerTokens)
        var delta = StreamSnapshotDelta()
        var text = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                try Task.checkCancellation()
                let piece = delta.next(snapshot.content)
                if !piece.isEmpty {
                    text += piece
                    request.onText(piece)
                }
            }
        } catch {
            throw AppleFoundationClient.map(error)
        }
        // Tool calls already ran inside the session (through `runTool`).
        return AgentTurnResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Apple's session takes one prompt: earlier turns become a short
    /// transcript (the last few only, for the 4K context).
    static func prompt(from messages: [AgentMessage]) -> String {
        let turns = messages.filter { $0.role != .tool }
        guard let last = turns.last else { return "" }
        let earlier = turns.dropLast().suffix(4)
        if earlier.isEmpty { return last.text }
        let history = earlier.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text.agentTruncated(400))" }.joined(separator: "\n")
        return "Conversation so far:\n\(history)\n\nUser: \(last.text)"
    }
}
