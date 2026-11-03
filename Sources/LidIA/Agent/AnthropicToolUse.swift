import Foundation

// Native tool use for `AnthropicClient` (raw HTTP Messages API): `tools`
// definitions, `tool_use` blocks out, `tool_result` blocks back. Every
// assistant turn is replayed verbatim, thinking blocks included, as the API
// requires.

struct AnthropicToolBackend: AgentBackend {
    let client: AnthropicClient

    var kind: AgentBackendKind { .anthropicTools }

    func turn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        try await client.toolTurn(request)
    }
}

extension AnthropicClient {
    /// One streamed Messages request with tools.
    func toolTurn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        try PrivacyGate.checkAIEndpoint(baseURL, provider: "Anthropic")
        if apiKey.isEmpty {
            throw LLMError.authenticationError("API key not configured. Open Settings and enter your Anthropic API key.")
        }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = max(timeoutInterval, 300)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if Self.supportsDefaultFallback(request.model) {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        var outbound = request
        (outbound.system, outbound.messages) = AgentOutbound.prepare(request, host: baseURL.host ?? "")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.toolRequestBody(outbound))
        let prepared = urlRequest

        let (bytes, response) = try await withRetry {
            try await URLSession.shared.bytes(for: prepared)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = (AgentJSON.object(String(decoding: data, as: UTF8.self))?["error"] as? [String: Any])?["message"] as? String
            throw LLMError.httpError(statusCode: http.statusCode, message: message)
        }

        var parser = AnthropicToolStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try parser.consume(line: line) {
            case .text(let text): request.onText(text)
            case .reasoning(let text): request.onReasoning(text)
            case nil: break
            }
        }
        return try parser.finish()
    }

    /// The Messages request body for a tool turn. Internal for tests.
    static func toolRequestBody(_ request: AgentTurnRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": 8_192,
            "stream": true,
            "system": request.system,
            "messages": toolMessages(request.messages),
        ]
        var tools: [[String: Any]] = request.tools.map { spec in
            ["name": spec.name, "description": spec.description, "input_schema": spec.jsonSchema] as [String: Any]
        }
        for server in request.serverTools {
            switch server {
            case .webSearch(let maxUses):
                tools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": max(1, maxUses)])
            }
        }
        if !tools.isEmpty { body["tools"] = tools }
        if supportsEffort(request.model) {
            body["output_config"] = ["effort": request.effort.rawValue]
            // Adaptive thinking with a readable summary: shown as the answer's reasoning.
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if supportsDefaultFallback(request.model) {
            body["fallbacks"] = "default"
        }
        return body
    }

    /// Agent messages as Messages API content. Consecutive tool results go
    /// in one user message, as the API expects for parallel calls.
    static func toolMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var pendingResults: [[String: Any]] = []

        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            result.append(["role": "user", "content": pendingResults])
            pendingResults = []
        }

        for message in messages {
            switch message.role {
            case .tool:
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.text.isEmpty ? "(empty)" : message.text,
                ]
                if message.isError { block["is_error"] = true }
                pendingResults.append(block)
            case .user:
                flushResults()
                result.append(["role": "user", "content": message.text])
            case .assistant:
                flushResults()
                if let native = message.nativeContentJSON, let blocks = AgentJSON.array(native), !blocks.isEmpty {
                    result.append(["role": "assistant", "content": blocks])
                } else {
                    var blocks: [[String: Any]] = []
                    if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
                    for call in message.toolCalls {
                        blocks.append([
                            "type": "tool_use", "id": call.id, "name": call.name,
                            "input": AgentJSON.object(call.argumentsJSON) ?? [:],
                        ])
                    }
                    if blocks.isEmpty { blocks.append(["type": "text", "text": "(no reply)"]) }
                    result.append(["role": "assistant", "content": blocks])
                }
            }
        }
        flushResults()
        return result
    }
}

/// Reads a streamed Messages response with tool use: text deltas out, and the
/// full content blocks (text, tool_use, thinking with signature) rebuilt for
/// replay.
struct AnthropicToolStreamParser {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private(set) var stopReason: String?
    private var sawText = false

    enum Delta: Equatable {
        case text(String)
        /// Summarized thinking, shown as the answer's reasoning.
        case reasoning(String)
    }

    /// Returns visible text or reasoning to stream, if the line carried some.
    mutating func consume(line: String) throws -> Delta? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = AgentJSON.object(payload), let type = event["type"] as? String else { return nil }
        let index = event["index"] as? Int ?? 0

        switch type {
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any] {
                blocks[index] = block
                if ["tool_use", "server_tool_use"].contains(block["type"] as? String) { partialJSON[index] = "" }
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], let deltaType = delta["type"] as? String else { return nil }
            var block = blocks[index] ?? [:]
            switch deltaType {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                block["type"] = block["type"] ?? "text"
                block["text"] = (block["text"] as? String ?? "") + text
                blocks[index] = block
                if !text.isEmpty { sawText = true; return .text(text) }
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                let thinking = delta["thinking"] as? String ?? ""
                block["thinking"] = (block["thinking"] as? String ?? "") + thinking
                blocks[index] = block
                if !thinking.isEmpty { return .reasoning(thinking) }
            case "signature_delta":
                block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                blocks[index] = block
            default:
                break
            }
        case "content_block_stop":
            if var block = blocks[index], ["tool_use", "server_tool_use"].contains(block["type"] as? String) {
                let json = partialJSON[index] ?? ""
                if json.trimmingCharacters(in: .whitespaces).isEmpty {
                    block["input"] = block["input"] ?? [String: Any]()
                } else if let input = AgentJSON.object(json) {
                    block["input"] = input
                } else {
                    // Kept as text so validation reports it and the model can retry.
                    block["input"] = ["_unparsed": json]
                }
                blocks[index] = block
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Anthropic stream error"
            if error?["type"] as? String == "overloaded_error" {
                throw LLMError.httpError(statusCode: 529, message: message)
            }
            throw LLMError.invalidResponse(message)
        default:
            break
        }
        return nil
    }

    /// The turn, once the stream ended.
    func finish() throws -> AgentTurnResponse {
        if stopReason == "refusal" {
            throw LLMError.invalidResponse(sawText
                ? "Claude stopped partway through this request. Try again, or pick another model."
                : "Claude declined this request. Try again, or pick another model.")
        }
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        var text = ""
        var calls: [AgentToolCall] = []
        var webResults: [AgentWebResult] = []
        for block in ordered {
            switch block["type"] as? String {
            case "web_search_tool_result":
                // A list on success; an error object otherwise.
                for result in block["content"] as? [[String: Any]] ?? [] {
                    guard let url = (result["url"] as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { continue }
                    webResults.append(AgentWebResult(title: result["title"] as? String ?? url.host ?? url.absoluteString, url: url))
                }
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                let arguments = (input["_unparsed"] as? String) ?? AgentJSON.string(input)
                calls.append(AgentToolCall(id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "", argumentsJSON: arguments))
            default:
                break
            }
        }
        // A tool call cut off by max_tokens may parse as a partial object: don't run it.
        if stopReason == "max_tokens", !calls.isEmpty {
            throw LLMError.invalidResponse("Claude's tool call was cut off. Try again.")
        }
        let replay = ordered.filter { ($0["type"] as? String) != "text" || !(($0["text"] as? String) ?? "").isEmpty }
        return AgentTurnResponse(
            text: text,
            toolCalls: calls,
            nativeContentJSON: replay.isEmpty ? nil : AgentJSON.string(replay),
            stopReason: stopReason,
            webResults: webResults
        )
    }
}
