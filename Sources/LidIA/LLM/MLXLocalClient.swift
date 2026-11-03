import Foundation
import MLX
@preconcurrency import MLXLMCommon
import MLXLLM
import os

// MARK: - MLXLocalError

enum MLXLocalError: LocalizedError {
    case noModelLoaded

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No on-device model is downloaded yet. Download one in Settings → AI."
        }
    }
}

// MARK: - Generation stats

/// Collects MLX generation statistics (token counts and timings) for the
/// requests made inside a `MLXLocalClient.$statsRecorder.withValue` scope.
/// Used by the summary benchmark; nil (and free) in the app.
final class MLXGenerationStatsRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        let promptTokens: Int
        let generatedTokens: Int
        let promptTime: TimeInterval
        let generateTime: TimeInterval
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] { lock.withLock { storage } }

    func record(_ info: GenerateCompletionInfo) {
        let entry = Entry(
            promptTokens: info.promptTokenCount,
            generatedTokens: info.generationTokenCount,
            promptTime: info.promptTime,
            generateTime: info.generateTime
        )
        lock.withLock { storage.append(entry) }
    }

    func reset() { lock.withLock { storage.removeAll() } }
}

// MARK: - MLXLocalClient

/// Local MLX inference client using the framework's managed `generate()` API.
///
/// Per model (from `ModelCatalog`): reasoning blocks are stripped (Qwen
/// `<think>`, Gemma 4 thinking channel), chat sampling follows the family's
/// recommendation, and prompts longer than the LidIA context cap are
/// condensed with map-reduce before generation.
///
/// @unchecked Sendable is safe: `modelManager` is @MainActor-isolated and only
/// accessed via `await MainActor.run { }` blocks.
final class MLXLocalClient: LLMClient, @unchecked Sendable {

    private static let logger = Logger(subsystem: "io.lidia.app", category: "MLXLocalClient")

    /// Context cap used for models outside the catalogue.
    static let defaultContextCap = 16_384
    /// Upper bound on generated tokens per request.
    static let maxOutputTokens = 4_096

    /// Benchmark hook: receives generation stats for requests in scope.
    @TaskLocal static var statsRecorder: MLXGenerationStatsRecorder?

    /// Chat temperature for requests in scope (the agent harness asks for a
    /// lower one on tool turns); nil keeps the family's recommendation.
    @TaskLocal static var chatTemperatureOverride: Float?

    private let modelManager: ModelManager
    /// The model to load when none is loaded (settings' selected MLX model).
    let preferredModelID: String

    @MainActor
    init(modelManager: ModelManager, preferredModelID: String = "") {
        self.modelManager = modelManager
        self.preferredModelID = preferredModelID
    }

    // MARK: - LLMClient

    func listModels() async throws -> [String] {
        await MainActor.run {
            modelManager.downloadedModels.map(\.id)
        }
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        let (container, modelID) = try await getContainer()
        let profile = Self.profile(for: modelID)
        let fitted = try await fit(messages, container: container, profile: profile, isJSON: format == .json)
        let userInput = buildUserInput(from: fitted)
        let parameters = Self.parameters(for: profile, isJSON: format == .json)

        let output: String = try await withModelInUse {
            try await Self.generateText(container: container, input: userInput, parameters: parameters)
        }

        let cleaned = ReasoningFilter.strip(output, family: profile.implicitThinking ? .qwen3 : nil)
        Self.logger.info("MLX generation complete: \(cleaned.count) chars")
        return cleaned
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (container, modelID) = try await self.getContainer()
                    let profile = Self.profile(for: modelID)
                    let fitted = try await self.fit(messages, container: container, profile: profile, isJSON: false)
                    nonisolated(unsafe) let userInput = self.buildUserInput(from: fitted)
                    let parameters = Self.parameters(for: profile, isJSON: false)

                    let recorder = Self.statsRecorder
                    try await self.withModelInUse { try await MLXInferenceLock.shared.run { try await container.perform { context in
                        let lmInput = try await context.processor.prepare(input: userInput)
                        let (stream, generation) = try Self.startGeneration(input: lmInput, parameters: parameters, context: context)

                        var filter = ReasoningFilter(expectsImplicitThinking: profile.implicitThinking)
                        for await event in stream {
                            if Task.isCancelled { break }
                            switch event {
                            case .chunk(let text):
                                let visible = filter.consume(text)
                                if !visible.isEmpty { continuation.yield(visible) }
                            case .info(let info):
                                recorder?.record(info)
                            case .toolCall, .rejectedToolCall:
                                break
                            }
                        }
                        // Stopping early leaves the model evaluating for a few ms;
                        // hold the lock until it is really done.
                        generation.cancel()
                        await generation.value
                        let tail = filter.finish()
                        if !tail.isEmpty { continuation.yield(tail) }
                    } } }

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

    // MARK: - Model profile

    /// Generation settings derived from the catalogue entry.
    struct Profile: Sendable {
        let family: ModelFamily?
        let contextCap: Int
        /// Legacy Qwen 3 thinking models open `<think>` in the template.
        let implicitThinking: Bool
    }

    static func profile(for modelID: String) -> Profile {
        let entry = ModelCatalog.entry(for: modelID)
        return Profile(
            family: entry?.family,
            contextCap: entry?.contextCap ?? defaultContextCap,
            // enable_thinking=false makes even legacy Qwen 3 8B answer directly.
            implicitThinking: false
        )
    }

    static func parameters(for profile: Profile, isJSON: Bool) -> GenerateParameters {
        if isJSON {
            return GenerateParameters(
                maxTokens: maxOutputTokens,
                temperature: LLMTemperature.structured,
                repetitionPenalty: 1.1,
                repetitionContextSize: 64
            )
        }
        let sampling = (profile.family ?? .gemma3).chatSampling
        return GenerateParameters(
            maxTokens: maxOutputTokens,
            temperature: chatTemperatureOverride ?? sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64
        )
    }

    // MARK: - Private

    private static func generateText(
        container: ModelContainer,
        input: UserInput,
        parameters: GenerateParameters
    ) async throws -> String {
        nonisolated(unsafe) let input = input
        let recorder = statsRecorder
        return try await MLXInferenceLock.shared.run {
            try await container.perform { context in
                let lmInput = try await context.processor.prepare(input: input)
                let (stream, generation) = try startGeneration(input: lmInput, parameters: parameters, context: context)
                var fullText = ""
                for await event in stream {
                    switch event {
                    case .chunk(let text): fullText += text
                    case .info(let info): recorder?.record(info)
                    default: break
                    }
                }
                await generation.value
                return fullText
            }
        }
    }

    /// Starts a generation and returns its stream plus the task doing the work,
    /// so callers can wait until the GPU is idle before releasing the lock.
    static func startGeneration(
        input: LMInput,
        parameters: GenerateParameters,
        context: ModelContext
    ) throws -> (AsyncStream<Generation>, Task<Void, Never>) {
        let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
        return generateTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator,
            toolCallPolicy: parameters.toolCallPolicy
        )
    }

    /// Condenses the request if it exceeds the model's context cap.
    private func fit(
        _ messages: [LLMChatMessage],
        container: ModelContainer,
        profile: Profile,
        isJSON: Bool
    ) async throws -> [LLMChatMessage] {
        let condenseParameters = GenerateParameters(
            maxTokens: max(512, profile.contextCap / 4),
            temperature: LLMTemperature.structured,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64
        )
        let implicitThinking = profile.implicitThinking
        let fitter = ContextFitter(
            contextTokens: profile.contextCap,
            reservedOutputTokens: min(Self.maxOutputTokens, profile.contextCap / 4),
            countTokens: { await container.encode($0).count },
            condense: { [self] chunk, index, total in
                Self.logger.info("Condensing part \(index + 1, privacy: .public) of \(total, privacy: .public) to fit the \(profile.contextCap, privacy: .public)-token cap")
                let input = self.buildUserInput(from: [
                    LLMChatMessage(role: "system", content: ContextFitter.condenseInstructions),
                    LLMChatMessage(role: "user", content: chunk),
                ])
                let raw = try await self.withModelInUse {
                    try await Self.generateText(container: container, input: input, parameters: condenseParameters)
                }
                return ReasoningFilter.strip(raw, family: implicitThinking ? .qwen3 : nil)
            }
        )
        return try await fitter.fit(messages)
    }

    /// Keeps the model from being idle-unloaded while `body` runs.
    private func withModelInUse<T>(_ body: () async throws -> T) async throws -> T {
        await MainActor.run { modelManager.beginUse() }
        do {
            let result = try await body()
            await MainActor.run { modelManager.endUse() }
            return result
        } catch {
            await MainActor.run { modelManager.endUse() }
            throw error
        }
    }

    /// Returns the loaded container and its model ID, loading lazily.
    private func getContainer() async throws -> (ModelContainer, String) {
        let loaded: (ModelContainer, String)? = await MainActor.run {
            guard let container = modelManager.modelContainer, let id = modelManager.loadedModelID else { return nil }
            return (container, id)
        }
        let preferred = preferredModelID
        let wanted: String? = await MainActor.run {
            if !preferred.isEmpty, modelManager.isVerified(preferred) {
                return preferred
            }
            // No usable pick: only this Mac's recommended model, never "whatever is installed".
            return ModelCatalog.automaticModelID(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                isVerified: { modelManager.isVerified($0.id) }
            )
        }

        if let loaded, wanted == nil || wanted == loaded.1 {
            return loaded
        }

        if let wanted {
            Self.logger.info("Loading MLX model on first use: \(wanted, privacy: .public)")
            try await modelManager.loadModel(wanted)
            let reloaded: (ModelContainer, String)? = await MainActor.run {
                guard let container = modelManager.modelContainer, let id = modelManager.loadedModelID else { return nil }
                return (container, id)
            }
            if let reloaded { return reloaded }
        }

        throw MLXLocalError.noModelLoaded
    }

    private func buildUserInput(from messages: [LLMChatMessage]) -> UserInput {
        let chatMessages = messages.compactMap { msg -> Chat.Message? in
            switch msg.role {
            case "system": return .system(msg.content)
            case "user": return .user(msg.content)
            case "assistant": return .assistant(msg.content)
            case "tool": return .tool(msg.content)
            default: return .user(msg.content)
            }
        }
        return UserInput(chat: chatMessages, additionalContext: Self.templateContext)
    }

    /// Chat-template variables for every request. Thinking is turned off: LidIA
    /// strips reasoning before showing anything, so thinking only adds latency
    /// (Qwen 3.6 / 3.8 think by default; Qwen 3.5 small models and Gemma 4 don't,
    /// and ignore the flag). Measured in docs/research/2026-11-summary-benchmark.md.
    static let templateContext: [String: any Sendable] = ["enable_thinking": false]
}
