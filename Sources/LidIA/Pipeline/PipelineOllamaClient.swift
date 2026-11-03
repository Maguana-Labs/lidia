import Foundation

/// Ollama client used by the post-meeting pipeline.
///
/// Ollama silently truncates prompts to its default context (2k–4k tokens depending
/// on version) unless `options.num_ctx` is sent, which meant long meetings were
/// summarised from their last few minutes only. This client always sends an explicit
/// context size that matches `SummarizationBudget.ollama`, so the chunker and the
/// server agree on how much text fits.
///
/// Lives in `Pipeline/` (not `LLM/`) so the pipeline owns the context-size contract.
actor PipelineOllamaClient: LLMClient {
    static let defaultContextTokens = 16384

    nonisolated let baseURL: URL
    nonisolated let contextTokens: Int
    nonisolated let timeoutInterval: TimeInterval

    init(baseURL: URL, contextTokens: Int = PipelineOllamaClient.defaultContextTokens, timeoutInterval: TimeInterval = 600) {
        self.baseURL = baseURL
        self.contextTokens = contextTokens
        self.timeoutInterval = timeoutInterval
    }

    struct Options: Codable, Sendable, Equatable {
        var num_ctx: Int
        var temperature: Float?
    }

    struct Request: Codable, Sendable {
        let model: String
        let messages: [LLMChatMessage]
        let stream: Bool
        var format: String?
        var options: Options
    }

    private struct Response: Decodable {
        let message: LLMChatMessage
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    /// Builds the request body. Exposed for tests so the `num_ctx` contract is checked.
    nonisolated static func makeRequest(
        messages: [LLMChatMessage],
        model: String,
        format: LLMResponseFormat?,
        contextTokens: Int
    ) -> Request {
        var request = Request(
            model: model,
            messages: messages,
            stream: false,
            format: nil,
            options: Options(num_ctx: contextTokens, temperature: LLMTemperature.refinement)
        )
        if case .json = format {
            request.format = "json"
            request.options.temperature = LLMTemperature.structured
        }
        return request
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        try PrivacyGate.checkAIEndpoint(baseURL, provider: "Ollama")
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            Self.makeRequest(messages: messages, model: model, format: format, contextTokens: contextTokens)
        )
        let prepared = urlRequest

        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: prepared)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.httpError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8))
        }
        return try JSONDecoder().decode(Response.self, from: data).message.content
    }

    /// Streams tokens (for the live summary) with the same explicit `num_ctx`.
    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        do {
            try PrivacyGate.checkAIEndpoint(baseURL, provider: "Ollama")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        var body = Self.makeRequest(messages: messages, model: model, format: nil, contextTokens: contextTokens)
        body = Request(model: body.model, messages: body.messages, stream: true, format: nil, options: body.options)
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(body)
        let prepared = urlRequest

        struct Chunk: Decodable {
            let message: LLMChatMessage?
            let done: Bool?
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: prepared)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw LLMError.httpError(statusCode: http.statusCode, message: nil)
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty,
                              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
                        if let text = chunk.message?.content, !text.isEmpty { continuation.yield(text) }
                        if chunk.done == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        urlRequest.timeoutInterval = timeoutInterval
        let prepared = urlRequest
        let (data, _) = try await withRetry {
            try await URLSession.shared.data(for: prepared)
        }
        return try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
    }
}

// MARK: - Pipeline client selection

enum PipelineClientFactory {
    /// Returns the client the pipeline should use for `client`, upgrading a plain
    /// `OllamaClient` to one that sends an explicit context size.
    static func pipelineClient(for client: any LLMClient) -> any LLMClient {
        if let ollama = client as? OllamaClient {
            return PipelineOllamaClient(baseURL: ollama.baseURL, timeoutInterval: ollama.timeoutInterval)
        }
        return client
    }
}
