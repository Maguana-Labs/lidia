import Foundation

// Native function calling for `OpenAIClient` (OpenAI and every
// OpenAI-compatible endpoint: LM Studio, OpenRouter, Groq, Gemini, …).

struct OpenAIToolBackend: AgentBackend {
    let client: OpenAIClient

    var kind: AgentBackendKind { .openAITools }

    func turn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        try await client.toolTurn(request)
    }
}

extension OpenAIClient {
    /// One chat-completions request with `tools`. Not streamed: tool rounds
    /// are short, and some compatible servers don't stream tool calls.
    func toolTurn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        try PrivacyGate.checkAIEndpoint(baseURL, provider: baseURL.host ?? "this server")
        if apiKey.isEmpty {
            throw LLMError.authenticationError("API key not configured. Open Settings and enter your API key.")
        }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var outbound = request
        (outbound.system, outbound.messages) = AgentOutbound.prepare(request, host: baseURL.host ?? "")
        var body = Self.toolRequestBody(outbound, isOpenAIProper: baseURL.host == "api.openai.com")
        for (key, value) in extraBody { body[key] = value.foundationValue }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let prepared = urlRequest

        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: prepared)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = (AgentJSON.object(String(decoding: data, as: UTF8.self))?["error"] as? [String: Any])?["message"] as? String
            throw LLMError.httpError(statusCode: http.statusCode, message: message)
        }
        let turn = try Self.parseToolResponse(data)
        if !turn.text.isEmpty { request.onText(turn.text) }
        return turn
    }

    /// Internal for tests.
    static func toolRequestBody(_ request: AgentTurnRequest, isOpenAIProper: Bool) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        for message in request.messages {
            switch message.role {
            case .user:
                messages.append(["role": "user", "content": message.text])
            case .assistant:
                var entry: [String: Any] = ["role": "assistant", "content": message.text.isEmpty ? NSNull() : message.text]
                if !message.toolCalls.isEmpty {
                    entry["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]] as [String: Any]
                    }
                }
                messages.append(entry)
            case .tool:
                messages.append(["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text])
            }
        }
        var body: [String: Any] = ["model": request.model, "messages": messages, "stream": false]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { spec in
                ["type": "function", "function": ["name": spec.name, "description": spec.description, "parameters": spec.jsonSchema]] as [String: Any]
            }
        }
        // Reasoning models on OpenAI itself take an effort; others ignore or reject it.
        let model = request.model.lowercased()
        if isOpenAIProper, model.hasPrefix("o") || model.hasPrefix("gpt-5") {
            body["reasoning_effort"] = request.effort.rawValue
        }
        return body
    }

    /// Internal for tests.
    static func parseToolResponse(_ data: Data) throws -> AgentTurnResponse {
        guard let object = AgentJSON.object(String(decoding: data, as: UTF8.self)),
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse("The server returned no choices")
        }
        let text = ReasoningFilter.strip((message["content"] as? String) ?? "")
        let calls: [AgentToolCall] = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let function = raw["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            let arguments: String
            if let string = function["arguments"] as? String {
                arguments = string
            } else if let object = function["arguments"] as? [String: Any] {
                arguments = AgentJSON.string(object)
            } else {
                arguments = "{}"
            }
            return AgentToolCall(id: raw["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))", name: name, argumentsJSON: arguments)
        }
        return AgentTurnResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls, stopReason: choice["finish_reason"] as? String)
    }
}
