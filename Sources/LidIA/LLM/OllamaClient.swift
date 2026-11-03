import Foundation
import os

// MARK: - Shared Types

struct LLMChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct MeetingSummaryResponse: Codable, Sendable {
    let title: String
    /// Legacy flat summary — used as fallback and backward compatibility.
    let summary: String?
    /// Structured sections with quote anchoring.
    let summarySections: [StructuredSummary.SummarySection]?
    let decisions: [String]
    let actionItems: [ActionItemResponse]

    struct ActionItemResponse: Codable, Sendable {
        let title: String
        let assignee: String?
        let deadline: String?
        let sourceQuote: String?

        enum CodingKeys: String, CodingKey {
            case title, assignee, deadline
            case sourceQuote = "source_quote"
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions, actionItems
        case summarySections = "summary_sections"
    }

    /// Convert to StructuredSummary if sections are available.
    func toStructured() -> StructuredSummary? {
        guard let sections = summarySections, !sections.isEmpty else { return nil }
        return StructuredSummary(
            title: title,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems.map {
                StructuredSummary.SummaryActionItem(
                    title: $0.title,
                    assignee: $0.assignee,
                    deadline: $0.deadline,
                    sourceQuote: $0.sourceQuote
                )
            }
        )
    }

    /// Flat markdown summary — from structured sections or legacy field.
    var flatSummary: String {
        if let structured = toStructured() {
            return structured.markdownSummary
        }
        return summary ?? ""
    }
}

// MARK: - LLMClient Protocol

protocol LLMClient: Sendable {
    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String
    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error>
    func listModels() async throws -> [String]
}

enum LLMResponseFormat: Sendable {
    case json
}

/// Temperature presets for different task types.
enum LLMTemperature {
    /// Low temperature for structured output (JSON, summaries). Deterministic.
    static let structured: Float = 0.3
    /// Medium temperature for transcript refinement. Mostly faithful.
    static let refinement: Float = 0.4
    /// Normal temperature for conversational chat.
    static let chat: Float = 0.7
}

// LLMError is defined in LLMError.swift

// Default implementations for refineTranscript and summarizeMeeting
extension LLMClient {

    /// Minimal prompt for short transcripts (< 100 words). Removes all structural
    /// section requirements that cause LLMs to hallucinate content for thin transcripts.
    static var briefTranscriptPrompt: String {
        """
        You are a meeting note assistant. Given a SHORT meeting transcript, produce a JSON object:

        {"title": "...", "summary": "...", "decisions": [...], "actionItems": [...]}

        CRITICAL RULES:
        1. "summary" MUST be a single JSON string (not an array). Use \\n for newlines.
        2. NEVER FABRICATE. Only include information EXPLICITLY stated in the transcript.
        3. Do NOT invent participant names, ideas, proposals, or details not present.
        4. Do NOT generate structured sections (### headings) — the transcript is too brief.
        5. Write a simple 1-3 sentence summary of what was actually said. Nothing more.
        6. When the transcript has speaker labels (**Name:**), attribute statements to them by name.
        7. "decisions": empty array [] unless a decision was EXPLICITLY stated.
        8. "actionItems": empty array [] unless someone said "I will..." or clearly took ownership of a task. \
        "We should..." or "it would be nice to..." are suggestions, NOT action items.
        9. If the transcript is vague, your summary must be equally vague.

        This transcript is very short. A short, accurate summary is ALWAYS better than \
        a long, fabricated one. If the content only fills one sentence, write one sentence.

        Respond ONLY with valid JSON. No markdown fences. No commentary.
        """
    }
    /// Uses the streaming endpoint to collect a complete response, avoiding HTTP idle timeouts
    /// on long-running LLM calls. Falls back to non-streaming `chat` if streaming yields nothing.
    /// When JSON format is requested, uses non-streaming `chat` directly since `chatStream`
    /// doesn't support response format constraints.
    func chatViaStream(messages: [LLMChatMessage], model: String, format: LLMResponseFormat? = nil) async throws -> String {
        if case .json = format {
            return try await chat(messages: messages, model: model, format: format)
        }
        var collected = ""
        for try await token in await chatStream(messages: messages, model: model) {
            collected += token
        }
        guard !collected.isEmpty else {
            // Fallback to non-streaming if stream yielded nothing
            return try await chat(messages: messages, model: model, format: format)
        }
        return collected
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await chat(messages: messages, model: model, format: nil)
                    if !response.isEmpty {
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func refineTranscript(rawText: String, model: String, attendees: [String]? = nil, vocabulary: [AppSettings.VocabularyEntry] = []) async throws -> String {
        var systemPrompt = """
            You are a transcript editor. Fix grammar, punctuation, and formatting \
            in the following meeting transcript. Preserve the original meaning. \
            Do not add or remove content. Output only the cleaned transcript.
            """

        if !vocabulary.isEmpty {
            let terms = vocabulary.map { "\"\($0.heardAs)\" → \"\($0.replaceTo)\"" }
            systemPrompt += """

            IMPORTANT: The following domain-specific terms are commonly misheard by \
            speech recognition. Correct any instances you find:
            \(terms.joined(separator: ", "))
            """
        }

        if let attendees, !attendees.isEmpty {
            systemPrompt += """

            The meeting attendees are: \(attendees.joined(separator: ", ")).
            IMPORTANT: Actively identify and label speakers throughout the transcript.
            Use **Name:** format at the start of each speaking turn.
            Use contextual clues to determine who is speaking:
            - References to "my team", "I'll handle", first-person statements
            - Topic ownership (who is presenting/reporting)
            - Direct address ("Sarah, what do you think?")
            - Role indicators ("as the PM", "from engineering")
            If you can't determine the speaker with confidence, use **Speaker:** as a generic label.
            Always add a speaker label at the start and when speakers change.
            """
        }

        // For long transcripts, chunk to avoid LLM context/timeout limits.
        // ~3000 words per chunk keeps us well within most model context windows.
        let words = rawText.split(separator: " ", omittingEmptySubsequences: true)
        let chunkSize = 3000
        guard words.count > chunkSize else {
            return try await chatViaStream(
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: rawText),
                ],
                model: model
            )
        }

        var refinedParts: [String] = []
        var offset = 0
        while offset < words.count {
            let end = min(offset + chunkSize, words.count)
            let chunkText = words[offset..<end].joined(separator: " ")
            let chunkPrompt = systemPrompt + (refinedParts.isEmpty ? "" : "\nThis is a continuation of the same meeting transcript. Maintain consistent formatting with the previous sections.")
            let refined = try await chatViaStream(
                messages: [
                    .init(role: "system", content: chunkPrompt),
                    .init(role: "user", content: chunkText),
                ],
                model: model
            )
            refinedParts.append(refined)
            offset = end
        }
        return refinedParts.joined(separator: "\n\n")
    }

    func summarizeMeeting(transcript: String, model: String, template: MeetingTemplate? = nil, attendees: [String]? = nil) async throws -> MeetingSummaryResponse {
        let wordCount = transcript.split(separator: " ").count
        var systemPrompt: String
        if wordCount < 100 {
            // Short transcript — use minimal prompt to prevent hallucination.
            // Structural section requirements cause LLMs to fabricate content
            // when the transcript is too thin to fill them.
            systemPrompt = Self.briefTranscriptPrompt
        } else {
            systemPrompt = template?.effectiveSystemPrompt ?? MeetingTemplate.general.systemPrompt
        }

        // Ground the model against hallucinating speaker attributions
        if let attendees, !attendees.isEmpty {
            systemPrompt += """

            ATTENDEES IN THIS MEETING: \(attendees.joined(separator: ", "))

            CRITICAL RULES:
            - You may ONLY use names from the attendees list above. Never invent or guess names.
            - When the transcript clearly indicates who is speaking (through context, direct address, or role), attribute to the correct attendee.
            - When it is genuinely unclear who said something, use "The team discussed" or describe the topic without attributing to a specific person.
            - Do NOT fabricate statements, events, or details not present in the transcript.
            - Focus on WHAT was discussed and decided, not just who said what.
            """
        } else {
            systemPrompt += """

            CRITICAL RULES:
            - No attendee list is available. Do NOT guess or fabricate speaker names.
            - If the transcript has speaker labels (e.g., **Name:**), use those names only.
            - Otherwise, use "A participant" or "The team" for attributions.
            - Do NOT fabricate names, statements, or events not present in the transcript.
            - Stick strictly to what was actually said in the transcript.
            """
        }
        var content: String
        do {
            content = try await chatViaStream(
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: transcript),
                ],
                model: model,
                format: .json
            )
        } catch {
            throw error
        }

        // Strip <think>…</think> reasoning blocks (Qwen3/3.5)
        if let range = content.range(of: "</think>") {
            content = String(content[range.upperBound...])
        }

        // Strip markdown fences defensively
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```json") {
            content = String(content.dropFirst(7))
        } else if content.hasPrefix("```") {
            content = String(content.dropFirst(3))
        }
        if content.hasSuffix("```") {
            content = String(content.dropLast(3))
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Last resort: extract first JSON object from mixed output
        if !content.hasPrefix("{"), let start = content.firstIndex(of: "{") {
            content = String(content[start...])
        }

        // Fix common model error: "summary": [...] instead of "summary": "..."
        // Convert array-style summary to a joined string
        if content.contains("\"summary\": [") || content.contains("\"summary\":[") {
            content = fixSummaryArray(content)
        }

        guard let data = content.data(using: .utf8) else {
            throw LLMError.invalidResponse("Unable to encode LLM response as UTF-8")
        }
        do {
            return try JSONDecoder().decode(MeetingSummaryResponse.self, from: data)
        } catch {
            throw error
        }
    }

    /// Fix model error where "summary" is output as a JSON array instead of a string.
    /// Extracts the array content, joins it, and wraps it as a proper string value.
    private func fixSummaryArray(_ json: String) -> String {
        // Find "summary": [ and the matching ]
        guard let arrayStart = json.range(of: "\"summary\":")?.upperBound else { return json }
        let afterKey = json[arrayStart...].drop(while: { $0.isWhitespace })
        guard afterKey.first == "[" else { return json }

        let bracketStart = afterKey.startIndex
        var depth = 0
        var bracketEnd: String.Index?
        for idx in json.indices[bracketStart...] {
            if json[idx] == "[" { depth += 1 }
            else if json[idx] == "]" {
                depth -= 1
                if depth == 0 { bracketEnd = idx; break }
            }
        }
        guard let end = bracketEnd else { return json }

        // Extract the raw content between [ and ], clean it into a single string
        let arrayContent = String(json[json.index(after: bracketStart)..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Escape it as a JSON string: replace unescaped quotes and newlines
        let escaped = arrayContent
            .replacingOccurrences(of: "\\\"", with: "ESCAPED_QUOTE_PLACEHOLDER")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "ESCAPED_QUOTE_PLACEHOLDER", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "\\t")

        var result = json
        guard let openBracket = json[arrayStart...].firstIndex(of: "["),
              openBracket > json.startIndex else { return json }
        let fullRange = json.index(before: openBracket)...end
        result.replaceSubrange(fullRange, with: "\"\(escaped)\"")
        return result
    }
}

// MARK: - Ollama Request/Response Types

private struct OllamaChatRequest: Codable, Sendable {
    let model: String
    let messages: [LLMChatMessage]
    let stream: Bool
    var format: String?
    var options: OllamaOptions?
}

private struct OllamaOptions: Codable, Sendable {
    var temperature: Float?
}

private struct OllamaChatResponse: Codable, Sendable {
    let model: String
    let message: LLMChatMessage
    let done: Bool
}

private struct OllamaTagsResponse: Codable, Sendable {
    struct Model: Codable, Sendable {
        let name: String
        let size: Int64
    }
    let models: [Model]
}

// MARK: - OllamaClient

actor OllamaClient: LLMClient {
    let baseURL: URL
    let timeoutInterval: TimeInterval

    init(baseURL: URL = URL(string: "http://localhost:11434")!, timeoutInterval: TimeInterval = 600) {
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
    }

    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeoutInterval
        let request = urlRequest
        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: request)
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw LLMError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
        let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return tagsResponse.models.map(\.name)
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        try PrivacyGate.checkAIEndpoint(baseURL, provider: "Ollama")
        let url = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var request = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: false
        )
        if case .json = format {
            request.format = "json"
            request.options = OllamaOptions(temperature: LLMTemperature.structured)
        }

        urlRequest.httpBody = try JSONEncoder().encode(request)
        let preparedRequest = urlRequest

        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: preparedRequest)
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw LLMError.httpError(statusCode: httpResponse.statusCode, message: body)
        }
        let chatResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        return chatResponse.message.content
    }

    /// Streaming-based complete response that supports format (e.g. JSON mode).
    /// Keeps the HTTP connection alive via chunked streaming, avoiding idle timeouts
    /// on long-running Ollama generations.
    func chatViaStream(messages: [LLMChatMessage], model: String, format: LLMResponseFormat? = nil) async throws -> String {
        try PrivacyGate.checkAIEndpoint(baseURL, provider: "Ollama")
        let url = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var request = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: true
        )
        if case .json = format {
            request.format = "json"
        }

        urlRequest.httpBody = try JSONEncoder().encode(request)
        let preparedRequest = urlRequest

        let (bytes, response) = try await URLSession.shared.bytes(for: preparedRequest)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw LLMError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }

        var collected = ""
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(OllamaChatResponse.self, from: lineData)
            collected += chunk.message.content
            if chunk.done { break }
        }
        return collected
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        do {
            try PrivacyGate.checkAIEndpoint(baseURL, provider: "Ollama")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let url = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let request = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: true
        )

        // Encode body before closure to avoid capturing mutable var
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        urlRequest.httpBody = encodedBody
        let preparedRequest = urlRequest

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: preparedRequest)
                    if let httpResponse = response as? HTTPURLResponse,
                       !(200...299).contains(httpResponse.statusCode) {
                        throw LLMError.httpError(statusCode: httpResponse.statusCode, message: nil)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let lineData = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(OllamaChatResponse.self, from: lineData)
                        let content = chunk.message.content
                        if !content.isEmpty {
                            continuation.yield(content)
                        }
                        if chunk.done {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - LLM Client Factory

/// Creates an LLM client for a specific provider, independent of routing/settings overrides.
///
/// Does NOT apply the privacy rules. Only use it for requests that carry no
/// meeting content (listing models). For anything else use `makeGatedClient`.
@MainActor
func makeClientForProvider(
    _ provider: AppSettings.LLMProvider,
    settings: AppSettings,
    modelManager: ModelManager? = nil
) -> (any LLMClient)? {
    switch provider {
    case .ollama:
        return OllamaClient(baseURL: URL(string: settings.ollamaURL) ?? URL(string: "http://localhost:11434")!, timeoutInterval: 600)
    case .lmStudio:
        // LM Studio's OpenAI-compatible server ignores the Authorization header,
        // but OpenAIClient requires a non-empty apiKey to send requests, so we
        // pass a placeholder. skipModelFilter=true because LM Studio model IDs
        // are paths like "qwen2.5-coder-32b-instruct" not "gpt-*"/"o1-*"/etc.
        return OpenAIClient(
            apiKey: "lm-studio",
            baseURL: URL(string: settings.lmStudioURL) ?? URL(string: "http://localhost:1234/v1")!,
            timeoutInterval: 600,
            skipModelFilter: true
        )
    case .automaticLocal:
        return AutomaticLocalClient(modelManager: modelManager, preferredMLXModelID: settings.selectedMLXModelID)
    case .appleOnDevice:
        return AppleFoundationClient()
    case .mlx:
        guard let modelManager else { return nil }
        return MLXLocalClient(modelManager: modelManager, preferredModelID: settings.selectedMLXModelID)
    case .openai:
        return OpenAIClient(
            apiKey: settings.openaiAPIKey,
            baseURL: URL(string: settings.openaiBaseURL) ?? URL(string: "https://api.openai.com/v1")!
        )
    case .anthropic:
        return AnthropicClient(apiKey: settings.anthropicAPIKey)
    case .cerebras:
        return OpenAIClient(apiKey: settings.cerebrasAPIKey, baseURL: URL(string: "https://api.cerebras.ai/v1")!)
    case .deepseek:
        return OpenAIClient(apiKey: settings.deepseekAPIKey, baseURL: URL(string: "https://api.deepseek.com/v1")!)
    case .nvidiaNIM:
        return OpenAIClient(apiKey: settings.nvidiaAPIKey, baseURL: URL(string: "https://integrate.api.nvidia.com/v1")!, timeoutInterval: 180)
    case .openRouter:
        return OpenAIClient(
            apiKey: settings.openRouterAPIKey,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            extraBody: settings.llm.openRouterEnforceZDR ? OpenAIClient.openRouterZDRBody : [:]
        )
    case .gemini:
        return OpenAIClient(apiKey: settings.llm.geminiAPIKey, baseURL: OpenAICompatiblePreset.gemini.baseURL)
    case .groq:
        return OpenAIClient(apiKey: settings.llm.groqAPIKey, baseURL: OpenAICompatiblePreset.groq.baseURL)
    case .openAICompatible:
        guard let base = URL(string: settings.llm.customBaseURL), base.host != nil else { return nil }
        // Self-hosted servers often need no key; OpenAIClient requires one.
        let key = settings.llm.customAPIKey.isEmpty ? "none" : settings.llm.customAPIKey
        return OpenAIClient(apiKey: key, baseURL: base, timeoutInterval: 600, skipModelFilter: true)
    case .codexCLI:
        return CLIChatClient(vendor: .codex)
    case .grokCLI:
        return CLIChatClient(vendor: .grok)
    }
}

/// Returns the client for the task's provider. Never returns a different
/// provider than the one configured: if it can't be built (MLX without a
/// ModelManager) or the cloud gate blocks it, the returned client throws a
/// clear error instead of silently talking to something else.
///
/// When the task's sub-steps resolve elsewhere (Hybrid's "Action items" on
/// this Mac while "Meeting notes" go to the cloud, or an Advanced override),
/// or Hybrid needs a local fallback for a cloud task, the client is a
/// `TaskRoutedClient` that sends each request to its own route.
@MainActor
func makeLLMClient(settings: AppSettings, modelManager: ModelManager? = nil, taskType: LLMTaskType? = nil) -> any LLMClient {
    let route = resolveRoute(settings: settings, taskType: taskType)
    let provider = route.provider
    guard let client = makeGatedClient(for: provider, settings: settings, modelManager: modelManager) else {
        return UnavailableLLMClient(.setupRequired(
            "\(provider.displayName) isn't ready. Finish AI setup in Settings → AI."
        ))
    }
    guard let taskType else { return client }

    var subRoutes: [LLMTaskType: RoutedTarget] = [:]
    for sub in classifiableSubTasks where sub != taskType {
        let subRoute = resolveRoute(settings: settings, taskType: sub)
        if subRoute.provider != provider || (!subRoute.model.isEmpty && subRoute.model != route.model) {
            subRoutes[sub] = routedTarget(for: subRoute, task: sub, settings: settings, modelManager: modelManager)
        }
    }
    let isCloud = provider.locality(settings: settings) == .cloud
    let wantsFallback = runMode(settings: settings) == .hybrid
        && (isCloud || subRoutes.values.contains(where: \.isCloud))
    guard !subRoutes.isEmpty || wantsFallback else { return client }

    let primary = RoutedTarget(
        task: taskType,
        providerName: provider.displayName,
        client: client,
        model: effectiveModel(for: taskType == .summarization ? .summary : .query, settings: settings, taskType: taskType),
        isCloud: isCloud
    )
    return TaskRoutedClient(
        declaredTask: taskType,
        primary: primary,
        subRoutes: subRoutes,
        localFallback: wantsFallback ? hybridLocalTarget(task: taskType, settings: settings, modelManager: modelManager) : nil,
        onFallback: { notice in
            Task { @MainActor in AIFallbackLog.shared.record(notice) }
        }
    )
}

/// A client for a specific provider that meeting data may be sent to.
///
/// Use this, not `makeClientForProvider`, whenever the request carries meeting
/// content ("Regenerate with…", "Retry with…", fallbacks). When the privacy
/// rules block the provider (Local-only mode, cloud AI off) it returns a client
/// that throws `LLMError.cloudBlocked` without sending anything. Returns nil
/// only when the provider can't be built (not configured).
@MainActor
func makeGatedClient(
    for provider: AppSettings.LLMProvider,
    purpose: LLMCloudPurpose = .primary,
    settings: AppSettings,
    modelManager: ModelManager? = nil
) -> (any LLMClient)? {
    if let blocked = providerBlockedError(provider, for: purpose, settings: settings) {
        return UnavailableLLMClient(blocked)
    }
    return makeClientForProvider(provider, settings: settings, modelManager: modelManager)
}

let fallbackLogger = Logger(subsystem: "io.lidia.app", category: "ProviderFallback")

/// Runs an LLM operation with automatic fallback to a secondary provider on failure.
///
/// A fallback that would move data from a local provider to a cloud provider
/// only runs when `allowsCloud(for: .fallback, …)` says so (the user chose
/// "Always"). Otherwise it throws `LLMError.cloudBlocked` (policy "Ask") or the
/// original error (policy "Never"); it never crosses silently.
@MainActor
func withProviderFallback<T: Sendable>(
    settings: AppSettings,
    modelManager: ModelManager? = nil,
    taskType: LLMTaskType? = nil,
    primaryModel: String,
    operation: @escaping @Sendable (any LLMClient, String) async throws -> T
) async throws -> T {
    let primaryClient = makeLLMClient(settings: settings, modelManager: modelManager, taskType: taskType)

    do {
        return try await withRetry {
            try await operation(primaryClient, primaryModel)
        }
    } catch {
        guard let fallbackProviderEnum = AppSettings.LLMProvider(storedValue: settings.fallbackProvider) else {
            throw error
        }

        let currentProvider = resolvedProvider(settings: settings, taskType: taskType)
        guard fallbackProviderEnum != currentProvider else {
            throw error
        }

        switch fallbackDecision(from: currentProvider, to: fallbackProviderEnum, settings: settings) {
        case .allow:
            break
        case .block(let blockError):
            fallbackLogger.info("Fallback from \(currentProvider.rawValue, privacy: .public) to \(fallbackProviderEnum.rawValue, privacy: .public) blocked by cloud policy")
            throw blockError ?? error
        }

        guard let client = makeGatedClient(for: fallbackProviderEnum, settings: settings, modelManager: modelManager) else {
            throw error
        }

        let model = settings.fallbackModel.isEmpty
            ? defaultModelForProvider(fallbackProviderEnum, settings: settings)
            : settings.fallbackModel

        fallbackLogger.info("Primary provider \(currentProvider.rawValue, privacy: .public) failed, falling back to \(fallbackProviderEnum.rawValue, privacy: .public)")

        return try await withRetry {
            try await operation(client, model)
        }
    }
}

@MainActor
func effectiveModel(for purpose: ModelPurpose, settings: AppSettings, taskType: LLMTaskType? = nil) -> String {
    let route = resolveRoute(settings: settings, taskType: taskType)
    switch route.source {
    case .override, .inheritedOverride, .hybridCloud:
        return route.model.isEmpty ? defaultModelForProvider(route.provider, settings: settings) : route.model
    case .hybridLocal, .localOnlyForced:
        // The per-purpose models belong to the main provider.
        guard route.provider == settings.llmProvider else {
            return defaultModelForProvider(route.provider, settings: settings)
        }
    case .base:
        break
    }

    switch purpose {
    case .query:
        return settings.queryModel.isEmpty ? effectiveDefaultModel(settings: settings) : settings.queryModel
    case .summary:
        return settings.summaryModel.isEmpty ? effectiveDefaultModel(settings: settings) : settings.summaryModel
    case .general:
        return effectiveDefaultModel(settings: settings)
    }
}

@MainActor
func defaultModelForProvider(_ provider: AppSettings.LLMProvider, settings: AppSettings) -> String {
    switch provider {
    case .automaticLocal:
        // The client resolves the real local model per request (only the
        // verified recommended one), so never echo a stale MLX pick here: it
        // was shown as the answering model even when it wasn't used.
        return AutomaticLocalClient.modelID
    case .appleOnDevice: return AppleFoundationClient.modelID
    case .ollama: return settings.ollamaModel.isEmpty ? "qwen3:4b" : settings.ollamaModel
    case .lmStudio: return settings.lmStudioModel
    case .mlx: return settings.selectedMLXModelID
    case .openai, .cerebras, .deepseek, .nvidiaNIM, .openRouter, .gemini, .groq, .openAICompatible:
        // The user's choice, else the best match in the fetched model list
        // by family preference (no stale hard-coded IDs).
        let chosen = storedModel(for: provider, settings: settings)
        if !chosen.isEmpty { return chosen }
        let fetched = provider == settings.llmProvider ? settings.availableModels : []
        return ModelMenuCatalog.autoModel(for: provider, availableModels: fetched)
    case .anthropic:
        if !settings.anthropicModel.isEmpty { return settings.anthropicModel }
        let fetched = provider == settings.llmProvider ? settings.availableModels : []
        let auto = ModelMenuCatalog.autoModel(for: .anthropic, availableModels: fetched)
        return auto.isEmpty ? LLMSettings.defaultAnthropicModel : auto
    case .codexCLI, .grokCLI:
        let chosen = storedModel(for: provider, settings: settings)
        return chosen.isEmpty ? CLIVendor.defaultModelID : chosen
    }
}

/// The model saved in settings for a provider ("" when none).
@MainActor
func storedModel(for provider: AppSettings.LLMProvider, settings: AppSettings) -> String {
    switch provider {
    case .automaticLocal, .mlx: return settings.selectedMLXModelID
    case .appleOnDevice: return AppleFoundationClient.modelID
    case .ollama: return settings.ollamaModel
    case .lmStudio: return settings.lmStudioModel
    case .openai: return settings.openaiModel
    case .anthropic: return settings.anthropicModel
    case .cerebras: return settings.cerebrasModel
    case .deepseek: return settings.deepseekModel
    case .nvidiaNIM: return settings.nvidiaModel
    case .openRouter: return settings.openRouterModel
    case .gemini: return settings.llm.geminiModel
    case .groq: return settings.llm.groqModel
    case .openAICompatible: return settings.llm.customModel
    case .codexCLI: return settings.llm.codexModel
    case .grokCLI: return settings.llm.grokModel
    }
}

@MainActor
private func effectiveDefaultModel(settings: AppSettings) -> String {
    let selectedModel = storedModel(for: settings.llmProvider, settings: settings)
    if !selectedModel.isEmpty {
        return selectedModel
    }
    return defaultModelForProvider(settings.llmProvider, settings: settings)
}

enum ModelPurpose {
    case query
    case summary
    case general
}

/// A kind of AI request, for per-task routing (Settings → AI → Advanced) and
/// the Hybrid list. Raw values are stored in route overrides: never change them.
/// `displayName`, defaults and order live in HybridRouting.swift.
enum LLMTaskType: String, CaseIterable, Codable, Sendable {
    case transcriptRefinement = "Transcript Refinement"
    case summarization = "Summarization"
    /// Short requests from dictation, Intelligence, voice, recipes and manual prep.
    case chat = "Chat"
    case templateDetection = "Template Detection"
    /// The structured facts step (title, decisions, action items) and action routing.
    case actionItems = "Action Items"
    /// Proactive prep briefs.
    case prepBrief = "Prep Briefs"
    /// Ask (⌘K) and chat bar answers.
    case ask = "Ask"
    /// Post-meeting follow-up drafts.
    case followUp = "Follow-up Drafts"
}

struct LLMRouteConfig: Codable, Sendable, Equatable {
    var provider: AppSettings.LLMProvider
    var model: String
}
