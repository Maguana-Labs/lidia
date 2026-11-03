import Foundation

// MARK: - Anthropic Request/Response Types

private struct AnthropicModelsResponse: Codable, Sendable {
    let data: [Model]

    struct Model: Codable, Sendable {
        let id: String
    }
}

// MARK: - AnthropicClient

actor AnthropicClient: LLMClient {
    let apiKey: String
    let baseURL: URL
    let timeoutInterval: TimeInterval

    init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, timeoutInterval: TimeInterval = 120) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
    }

    /// Lists the account's Claude models.
    ///
    /// Errors propagate. A 401/403 means the key is wrong and must never be
    /// reported as valid, and there is no hard-coded fallback list: model IDs go
    /// stale, so callers resolve a default from the live list instead
    /// (`ModelMenuCatalog.autoModel`).
    func listModels() async throws -> [String] {
        if apiKey.isEmpty {
            throw LLMError.authenticationError("API key not configured. Open Settings and enter your Anthropic API key.")
        }
        let url = baseURL.appendingPathComponent("v1/models")
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let request = urlRequest

        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: request)
        }
        try validateResponse(response, data: data)

        let modelsResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        return modelsResponse.data
            .map(\.id)
            .filter { $0.hasPrefix("claude") }
            .sorted()
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        // Streamed even here: a long summary can take minutes, and a silent
        // non-streaming request would hit the idle timeout before it finished.
        var text = ""
        for try await chunk in stream(messages: messages, model: model, format: format, effort: Self.effort(for: messages, streaming: false)) {
            text += chunk
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidResponse("Anthropic API returned no content")
        }
        return text
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, model: model, format: nil, effort: Self.effort(for: messages, streaming: true))
    }

    /// Effort per step (never above medium): the meeting summary gets
    /// `medium` whether or not it streams; chat and the small pipeline steps
    /// (title/action-item facts, map notes, prep) get `low`; other
    /// non-streamed requests keep `medium`.
    static func effort(for messages: [LLMChatMessage], streaming: Bool) -> String {
        let system = messages.first { $0.role == "system" }?.content ?? ""
        if system.hasPrefix(SummaryPrompts.markdownSummaryMarker) { return "medium" }
        if system.hasPrefix(SummaryPrompts.factsMarker)
            || system.hasPrefix(ActionRouting.systemPrompt.prefix(40))
            || system.contains("You are condensing part")
            || messages.first?.content.hasPrefix("You are a meeting prep assistant") == true {
            return "low"
        }
        return streaming ? "low" : "medium"
    }

    // MARK: - Streaming

    /// Builds the Messages request body. Internal for tests.
    static func requestBody(
        messages: [LLMChatMessage],
        model: String,
        format: LLMResponseFormat?,
        effort: String
    ) -> [String: Any] {
        var system: [String] = []
        var chatMessages: [[String: Any]] = []
        for msg in messages {
            if msg.role == "system" {
                system.append(msg.content)
            } else {
                chatMessages.append(["role": msg.role, "content": msg.content])
            }
        }
        if case .json = format {
            system.append("Respond ONLY with valid JSON, no markdown fences.")
        }

        var body: [String: Any] = [
            "model": model,
            // Room for thinking plus a long structured summary.
            "max_tokens": 32_000,
            "messages": chatMessages,
            "stream": true,
        ]
        if !system.isEmpty {
            body["system"] = system.joined(separator: "\n\n")
        }
        if supportsEffort(model) {
            body["output_config"] = ["effort": effort]
        }
        if supportsDefaultFallback(model) {
            body["fallbacks"] = "default"
        }
        return body
    }

    /// Models that accept `output_config.effort` (Opus 4.6+, Sonnet 4.6+, Haiku 5+, Fable).
    static func supportsEffort(_ model: String) -> Bool {
        let m = model.lowercased()
        return ["claude-opus-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5", "claude-fable"]
            .contains { m.hasPrefix($0) }
    }

    /// Models whose safety classifiers can decline, where the API can retry the
    /// request on its recommended fallback model (`fallbacks: "default"`).
    static func supportsDefaultFallback(_ model: String) -> Bool {
        let m = model.lowercased()
        return ["claude-opus-5", "claude-sonnet-5-5", "claude-fable"].contains { m.hasPrefix($0) }
    }

    private func stream(
        messages: [LLMChatMessage],
        model: String,
        format: LLMResponseFormat?,
        effort: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try PrivacyGate.checkAIEndpoint(baseURL, provider: "Anthropic")
                    if apiKey.isEmpty {
                        throw LLMError.authenticationError("API key not configured. Open Settings and enter your Anthropic API key.")
                    }
                    var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = max(timeoutInterval, 300)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if Self.supportsDefaultFallback(model) {
                        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    }
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.requestBody(
                            messages: OutboundRedactor.prepare(messages, for: DataLocality.forHost(baseURL.host ?? "")),
                            model: model, format: format, effort: effort
                        )
                    )
                    let prepared = request

                    let (bytes, response) = try await withRetry {
                        try await URLSession.shared.bytes(for: prepared)
                    }
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        try validateResponse(response, data: data)
                    }

                    var parser = AnthropicSSEParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch try parser.consume(line: line) {
                        case .text(let chunk):
                            continuation.yield(chunk)
                        case .none:
                            break
                        }
                    }
                    try parser.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct AnthropicErrorResponse: Codable {
        let error: ErrorBody

        struct ErrorBody: Codable {
            let message: String
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data))?.error.message
            throw LLMError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }
}

// MARK: - SSE parsing

/// Reads the Messages API event stream: text deltas out, thinking skipped,
/// refusals and stream errors turned into errors.
struct AnthropicSSEParser {
    enum Output: Equatable {
        case text(String)
        case none
    }

    private(set) var stopReason: String?
    private(set) var sawText = false

    mutating func consume(line: String) throws -> Output {
        guard line.hasPrefix("data:") else { return .none }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return .none }

        switch type {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                sawText = true
                return .text(text)
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
        return .none
    }

    /// Call when the stream ends.
    func finish() throws {
        if stopReason == "refusal" {
            throw LLMError.invalidResponse(
                sawText
                    ? "Claude stopped partway through this request. Try again, or pick another model."
                    : "Claude declined this request. Try again, or pick another model."
            )
        }
    }
}
