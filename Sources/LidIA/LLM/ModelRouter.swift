import Foundation

@MainActor
enum ModelRouter {
    private static let complexKeywords = [
        "analyze", "compare", "contrast", "why", "explain",
        "plan", "strategy", "evaluate", "synthesize", "recommend",
        "pros and cons", "trade-off", "deep dive", "root cause"
    ]

    static func route(query: String, settings: AppSettings) -> String {
        let lower = query.lowercased()
        let wordCount = query.split(separator: " ").count
        let isComplex = wordCount > 50 || complexKeywords.contains(where: { lower.contains($0) })

        if isComplex {
            return thinkingModel(for: settings)
        } else {
            return defaultModel(for: settings)
        }
    }

    /// A reasoning-capable model from the provider's fetched list, when one
    /// is listed; otherwise the normal model. Nothing is hard-coded, so a
    /// model the provider no longer offers is never requested.
    private static func thinkingModel(for settings: AppSettings) -> String {
        let fallback = defaultModel(for: settings)
        // The fetched list belongs to the main provider; only use it when
        // Ask resolves there.
        let provider = resolvedProvider(settings: settings, taskType: .ask)
        guard provider == settings.llmProvider, provider.group == .cloud else { return fallback }
        let markers = reasoningMarkers(for: provider)
        guard !markers.isEmpty else { return fallback }
        let match = settings.availableModels.first { id in
            let lower = id.lowercased()
            return markers.contains { lower.contains($0) }
        }
        return match ?? fallback
    }

    nonisolated static func reasoningMarkers(for provider: AppSettings.LLMProvider) -> [String] {
        switch provider {
        case .openai: return ["o4", "o3", "thinking"]
        case .deepseek: return ["reasoner"]
        case .openRouter, .groq, .cerebras, .nvidiaNIM, .gemini, .openAICompatible: return ["thinking", "reasoner", "-r1"]
        case .anthropic, .automaticLocal, .appleOnDevice, .mlx, .ollama, .lmStudio, .codexCLI, .grokCLI: return []
        }
    }

    private static func defaultModel(for settings: AppSettings) -> String {
        return effectiveModel(for: .query, settings: settings, taskType: .ask)
    }
}
