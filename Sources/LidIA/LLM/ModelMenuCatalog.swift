import Foundation

/// Picks models for menus and "Auto" from a provider's live `/models` list.
///
/// Cloud model IDs change too often to hard-code, so instead of fixed IDs
/// each provider has ordered family patterns (e.g. Anthropic: opus, then
/// sonnet, then haiku) matched against what the provider actually lists.
enum ModelMenuCatalog {
    static func curatedModels(for provider: AppSettings.LLMProvider, availableModels: [String]) -> [String] {
        let cleaned = dedupe(availableModels)
        guard !cleaned.isEmpty else {
            return knownModels(for: provider)
        }

        switch provider {
        case .mlx, .automaticLocal, .appleOnDevice:
            return cleaned
        case .lmStudio, .openAICompatible, .codexCLI, .grokCLI:
            // User-loaded models, or the plan's own list: show them all.
            return Array(cleaned.prefix(12))
        default:
            let ranked = rankByFamily(cleaned, patterns: familyPreference(for: provider))
            return Array(ranked.prefix(provider == .openRouter ? 10 : 6))
        }
    }

    /// Models to offer before anything was fetched. Only local catalogues
    /// are known offline; cloud lists come from the provider.
    static func knownModels(for provider: AppSettings.LLMProvider) -> [String] {
        switch provider {
        case .mlx: return ModelManager.availableModels.map(\.id)
        case .appleOnDevice: return [AppleFoundationClient.modelID]
        case .anthropic: return [LLMSettings.defaultAnthropicModel]
        case .grokCLI: return ["grok-4.6", "grok-4.5"]
        default: return []
        }
    }

    static func autoModel(for provider: AppSettings.LLMProvider, availableModels: [String]) -> String {
        if let firstCurated = curatedModels(for: provider, availableModels: availableModels).first {
            return firstCurated
        }
        // Empty means "not configured"; callers detect it instead of guessing.
        return availableModels.first ?? ""
    }

    /// Ordered substrings: models matching an earlier pattern rank first;
    /// within a pattern, newer-looking IDs (higher version numbers) first.
    static func familyPreference(for provider: AppSettings.LLMProvider) -> [String] {
        switch provider {
        case .anthropic:
            return ["sonnet", "opus", "haiku"]
        case .openai:
            return ["gpt-5", "gpt-4.1", "o4", "o3", "gpt-4o"]
        case .gemini:
            return ["gemini-3", "gemini-2.5-flash", "gemini-2.5-pro", "gemini"]
        case .groq:
            return ["gpt-oss", "llama-4", "qwen", "llama"]
        case .openRouter:
            return ["anthropic/claude", "google/gemini", "openai/gpt", "qwen/", "meta-llama/"]
        case .deepseek:
            return ["deepseek-chat", "deepseek"]
        case .cerebras:
            return ["gpt-oss", "qwen", "llama"]
        case .nvidiaNIM:
            return ["nvidia/", "meta/llama", "moonshotai/", "mistralai/"]
        case .ollama:
            return ["gemma", "qwen", "llama", "mistral", "phi"]
        case .mlx, .automaticLocal, .appleOnDevice, .lmStudio, .openAICompatible, .codexCLI, .grokCLI:
            return []
        }
    }

    /// Patterns that mark non-chat models (embeddings, audio, images, moderation).
    private static let nonChatMarkers = [
        "embed", "whisper", "tts", "dall-e", "image", "moderation", "audio", "realtime", "transcribe", "search",
    ]

    static func rankByFamily(_ models: [String], patterns: [String]) -> [String] {
        let chat = models.filter { id in
            let lower = id.lowercased()
            return !nonChatMarkers.contains { lower.contains($0) }
        }
        guard !patterns.isEmpty else { return chat }
        func rank(_ id: String) -> Int {
            let lower = id.lowercased()
            return patterns.firstIndex { lower.contains($0) } ?? patterns.count
        }
        return chat.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l != r { return l < r }
            // Newer first: compare version-like strings descending, and
            // prefer undated aliases over dated snapshots on ties.
            let order = lhs.compare(rhs, options: [.numeric, .caseInsensitive])
            if order == .orderedSame { return false }
            return order == .orderedDescending
        }
    }

    private static func dedupe(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }
}
