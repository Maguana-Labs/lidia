import Foundation

/// Runs a tool for a backend that drives its own tool loop (Apple's
/// `LanguageModelSession`). The harness validates, gates and records it.
typealias AgentNativeToolRunner = @Sendable (AgentToolCall) async -> String

/// One request to the model.
struct AgentTurnRequest: Sendable {
    var system: String
    var messages: [AgentMessage]
    /// Empty on the last step: the model must answer.
    var tools: [AgentToolSpec]
    var model: String
    var effort: AgentEffort
    /// Streams visible text as it arrives.
    var onText: @Sendable (String) -> Void
    /// For backends that run tools inside the model call (Apple).
    var runTool: AgentNativeToolRunner?
    /// Streams a model-provided reasoning summary (Claude), when there is one.
    var onReasoning: @Sendable (String) -> Void = { _ in }
    /// Tools the provider runs itself (Claude's web search). Only Claude
    /// backends send them; everything else ignores them.
    var serverTools: [AgentServerTool] = []
}

/// A tool the model provider runs on its side.
enum AgentServerTool: Sendable, Equatable {
    /// Claude's web search, at most `maxUses` searches per request.
    case webSearch(maxUses: Int)
}

/// One web search result the provider returned: real URLs only.
struct AgentWebResult: Sendable, Equatable, Codable, Hashable {
    var title: String
    var url: URL
}

/// What the model answered.
struct AgentTurnResponse: Sendable {
    var text: String
    var toolCalls: [AgentToolCall] = []
    /// Content to replay verbatim on the next request (Anthropic thinking blocks).
    var nativeContentJSON: String?
    var stopReason: String?
    /// Text already streamed through `onText` that isn't the answer (a
    /// malformed JSON action) and must be cleared from the UI.
    var retractStreamedText = false
    /// The JSON-action output had to be repaired once; why, and what it was.
    var repairProblem: String?
    var rejectedOutput: String?
    /// Results of searches the provider ran this turn (Claude web search).
    var webResults: [AgentWebResult] = []
}

enum AgentBackendError: LocalizedError, Equatable {
    /// The model's JSON action was still invalid after one repair attempt.
    case invalidAction(String, outputs: [String] = [])

    var errorDescription: String? {
        switch self {
        case .invalidAction(let problem, _): "The model's reply couldn't be used (\(problem))."
        }
    }
}

/// A way of talking tools with one kind of model.
protocol AgentBackend: Sendable {
    var kind: AgentBackendKind { get }
    func turn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse
}

// MARK: - Outbound hook

/// Native tool requests pass their text through `OutboundRedactor`, like
/// every other request that leaves the Mac.
enum AgentOutbound {
    static func prepare(_ request: AgentTurnRequest, host: String) -> (system: String, messages: [AgentMessage]) {
        let flat = [LLMChatMessage(role: "system", content: request.system)]
            + request.messages.map { LLMChatMessage(role: $0.role.rawValue, content: $0.text) }
        let prepared = OutboundRedactor.prepare(flat, for: DataLocality.forHost(host))
        guard prepared.count == flat.count else { return (request.system, request.messages) }
        var messages = request.messages
        for index in messages.indices { messages[index].text = prepared[index + 1].content }
        return (prepared[0].content, messages)
    }
}

// MARK: - JSON actions

/// Tool calling for models without a native tool API (MLX Qwen / LFM,
/// Ollama, CLI agents). The model answers either with plain text (the final
/// answer, streamed) or with exactly one JSON object
/// `{"tool": name, "arguments": {...}}`, which is validated against the
/// tool's schema. An invalid object gets ONE repair attempt. Free-text
/// markers are never parsed.
struct JSONActionBackend: AgentBackend {
    let client: any LLMClient

    var kind: AgentBackendKind { .jsonActions }

    /// Sampling temperature for agent turns on local models.
    static let temperature: Float = 0.2

    func turn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        let messages = Self.chatMessages(system: request.system, messages: request.messages)
        let first = try await generate(messages, request: request)
        switch Self.interpret(first.text, tools: request.tools) {
        case .answer(let text):
            return AgentTurnResponse(text: text)
        case .call(let call):
            return AgentTurnResponse(text: first.text, toolCalls: [call], retractStreamedText: first.streamed)
        case .invalid(let problem):
            // One repair attempt: show the model its output and what was wrong.
            var repairMessages = messages
            repairMessages.append(LLMChatMessage(role: "assistant", content: first.text))
            repairMessages.append(LLMChatMessage(role: "user", content: Self.repairInstruction(problem, toolsOffered: !request.tools.isEmpty)))
            let second = try await generate(repairMessages, request: request)
            switch Self.interpret(second.text, tools: request.tools) {
            case .answer(let text):
                return AgentTurnResponse(text: text, retractStreamedText: first.streamed, repairProblem: problem, rejectedOutput: first.text)
            case .call(let call):
                return AgentTurnResponse(
                    text: second.text, toolCalls: [call],
                    retractStreamedText: first.streamed || second.streamed, repairProblem: problem, rejectedOutput: first.text
                )
            case .invalid(let again):
                throw AgentBackendError.invalidAction(again, outputs: [first.text, second.text])
            }
        }
    }

    /// Streams the reply. Text that starts like JSON is held back (it is a
    /// tool call, not something to show); anything else streams as it comes.
    private func generate(_ messages: [LLMChatMessage], request: AgentTurnRequest) async throws -> (text: String, streamed: Bool) {
        var text = ""
        var decided: Bool?
        var streamed = false
        // Tool turns want a steady hand: low temperature on local MLX models.
        let stream = await MLXLocalClient.$chatTemperatureOverride.withValue(Self.temperature) {
            await client.chatStream(messages: messages, model: request.model)
        }
        for try await chunk in stream {
            try Task.checkCancellation()
            text += chunk
            if decided == nil {
                let lead = text.drop { $0.isWhitespace }
                if let first = lead.first {
                    decided = !(first == "{" || first == "`" || first == "[")
                    if decided == true {
                        request.onText(String(lead))
                        streamed = true
                    }
                }
            } else if decided == true {
                request.onText(chunk)
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), streamed)
    }

    // MARK: Pure pieces (tested)

    enum Interpretation: Equatable {
        case answer(String)
        case call(AgentToolCall)
        case invalid(String)
    }

    /// Reads one reply: plain text is the answer; a JSON object is a tool call
    /// (or `{"answer": …}`). A reply mixing prose with an embedded action is
    /// invalid rather than guessed at.
    static func interpret(_ raw: String, tools: [AgentToolSpec]) -> Interpretation {
        let text = stripFences(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.hasPrefix("{") || text.hasPrefix("[") else {
            if text.isEmpty { return .invalid("the reply was empty") }
            if text.contains("{\"tool\"") || text.contains("{ \"tool\"") {
                return .invalid("a tool call must be the whole reply, with no other text")
            }
            return .answer(text)
        }
        guard let object = AgentJSON.object(text) ?? leadingObject(text) else {
            return .invalid(text.hasPrefix("[") ? "send one JSON object, not a list" : "the JSON is malformed")
        }
        if let answer = object["answer"] as? String, object["tool"] == nil {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .invalid("the answer was empty") : .answer(trimmed)
        }
        guard let name = (object["tool"] as? String) ?? (object["name"] as? String) else {
            return .invalid("the object has no \"tool\" field")
        }
        guard let spec = tools.first(where: { $0.name == name }) else {
            let offered = tools.map(\.name)
            return .invalid(offered.isEmpty
                ? "no tools are available now; answer in plain text"
                : "unknown tool \"\(name)\"; use one of \(offered.joined(separator: ", "))")
        }
        // Flat (the documented form) or nested under "arguments".
        let arguments = (object["arguments"] as? [String: Any])
            ?? (object["args"] as? [String: Any])
            ?? object.filter { $0.key != "tool" && $0.key != "name" }
        if case .failure(let error) = spec.validate(arguments) {
            return .invalid(error.localizedDescription)
        }
        return .call(AgentToolCall(id: "call_\(UUID().uuidString.prefix(8).lowercased())", name: name, argumentsJSON: AgentJSON.string(arguments)))
    }

    /// The JSON object a reply starts with, when stray text follows it
    /// (small models sometimes add a sentence after the action). Only a
    /// reply that STARTS with the object counts; nothing is fished out of prose.
    static func leadingObject(_ text: String) -> [String: Any]? {
        guard text.first == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return AgentJSON.object(String(text[...index])) }
            default: break
            }
        }
        return nil
    }

    static func repairInstruction(_ problem: String, toolsOffered: Bool) -> String {
        toolsOffered
            ? "Your reply could not be used: \(problem). Reply again with only one JSON object {\"tool\": \"<tool name>\", \"<argument name>\": <value>} using the tool list, or with the answer as plain text."
            : "Your reply could not be used: \(problem). No more tools now: reply with the answer as plain text."
    }

    /// Agent messages as plain chat messages. Tool results go back as user
    /// messages, which every chat template understands.
    static func chatMessages(system: String, messages: [AgentMessage]) -> [LLMChatMessage] {
        var result = [LLMChatMessage(role: "system", content: system)]
        for message in messages {
            switch message.role {
            case .user:
                result.append(LLMChatMessage(role: "user", content: message.text))
            case .assistant:
                result.append(LLMChatMessage(role: "assistant", content: message.text))
            case .tool:
                let label = message.isError ? "Error from \(message.toolName ?? "tool")" : "Result of \(message.toolName ?? "tool")"
                result.append(LLMChatMessage(role: "user", content: "\(label):\n\(message.text)"))
            }
        }
        return result
    }

    static func stripFences(_ text: String) -> String {
        var content = text
        if content.hasPrefix("```") {
            if let newline = content.firstIndex(of: "\n") {
                content = String(content[content.index(after: newline)...])
            } else {
                content = String(content.dropFirst(3))
            }
            if content.hasSuffix("```") { content = String(content.dropLast(3)) }
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
