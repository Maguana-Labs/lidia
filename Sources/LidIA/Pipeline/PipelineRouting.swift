import Foundation

// MARK: - Budget for the client actually in use

extension SummarizationBudget {
    /// Output tokens held back for the summary itself plus the prompt.
    static let localReservedTokens = 4096

    /// Like `infer(for:)`, but resolves automatic local mode to the backend it
    /// will use and sizes MLX budgets from the model's catalogue context cap,
    /// so a 128K-context model isn't forced through 16K map-reduce (and
    /// automatic mode isn't treated as an unknown 4K client).
    @MainActor
    static func resolved(for client: any LLMClient) -> SummarizationBudget {
        switch client {
        case let mlx as MLXLocalClient:
            return mlxBudget(modelID: mlx.preferredModelID)
        case let automatic as AutomaticLocalClient:
            switch automatic.backend {
            case .mlx(let modelID): return mlxBudget(modelID: modelID)
            case .appleOnDevice: return appleOnDevice
            case .none: return .conservative
            }
        case is AppleFoundationClient:
            return appleOnDevice
        case let routed as TaskRoutedClient:
            return resolved(for: routed.primaryClient)
        default:
            return infer(for: client)
        }
    }

    static func mlxBudget(modelID: String) -> SummarizationBudget {
        let cap = ModelCatalog.entry(for: modelID)?.contextCap ?? MLXLocalClient.defaultContextCap
        return SummarizationBudget(contextTokens: max(cap, 8192), reservedTokens: localReservedTokens)
    }

    /// Apple's on-device model: the context it reports (8K on macOS 27, 4K before).
    static var appleOnDevice: SummarizationBudget {
        let context = AppleFoundationClient.contextSize
        return SummarizationBudget(contextTokens: context, reservedTokens: min(2560, context * 5 / 8))
    }
}

// MARK: - Concurrency

extension PipelineClientFactory {
    /// True when the client talks to a hosted provider that serves concurrent
    /// requests. Local runtimes (MLX, Apple on-device, Ollama, LM Studio) run one
    /// generation at a time on the GPU, so a second request only queues.
    static func canRunConcurrently(_ client: any LLMClient) -> Bool {
        switch client {
        case is AnthropicClient:
            return true
        case let routed as TaskRoutedClient:
            return canRunConcurrently(routed.primaryClient)
        case let openAI as OpenAIClient:
            let host = openAI.baseURL.host?.lowercased() ?? ""
            return !(host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local"))
        default:
            return false
        }
    }
}

// MARK: - Vocabulary

/// Applies the user's custom vocabulary ("heard as" → "replace with") to a
/// transcript without an LLM. Whole words only.
enum VocabularyCorrector {
    static func apply(_ vocabulary: [AppSettings.VocabularyEntry], to text: String) -> String {
        var result = text
        for entry in vocabulary {
            let heard = entry.heardAs.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, heard != entry.replaceTo else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: entry.caseSensitive ? [] : [.caseInsensitive]
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.replaceTo)
            )
        }
        return result
    }
}
