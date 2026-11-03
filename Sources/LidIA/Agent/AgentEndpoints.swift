import Foundation
import LidIAKit

/// Builds the harness for the user's settings: which client (always through
/// the gated factory, so Local-only mode and the cloud switch apply), which
/// backend, which prompt profile, and where it runs.
@MainActor
enum AgentEndpoints {
    /// The endpoint for `taskType` as routed (Hybrid included): `.ask` for
    /// Ask and chat, `.chat` for voice and Comment to AI. Or `provider` when
    /// the user picked one ("Retry with…").
    static func resolve(
        settings: AppSettings,
        modelManager: ModelManager?,
        taskType: LLMTaskType = .chat,
        provider override: AppSettings.LLMProvider? = nil
    ) -> AgentHarness.Endpoint {
        let provider = override ?? resolvedProvider(settings: settings, taskType: taskType)
        var client: any LLMClient = makeGatedClient(for: provider, settings: settings, modelManager: modelManager)
            ?? UnavailableLLMClient(.setupRequired("\(provider.displayName) isn't ready. Finish AI setup in Settings → AI."))
        var model = override == nil
            ? effectiveModel(for: .query, settings: settings, taskType: taskType)
            : defaultModelForProvider(provider, settings: settings)
        var label = model

        // Automatic and MLX resolve to a concrete local model, so the profile
        // and the inspector name the model that really runs. Both stay on
        // this Mac, so this never widens where data goes.
        if client is AutomaticLocalClient || client is MLXLocalClient {
            let preferred = settings.selectedMLXModelID
            let backend: AutomaticLocalClient.Backend
            // Same rule as the clients: a pick counts only when verified on disk;
            // otherwise the label is the recommended model that really runs.
            if client is MLXLocalClient, !preferred.isEmpty, modelManager?.isVerified(preferred) == true {
                backend = .mlx(modelID: preferred)
            } else {
                backend = AutomaticLocalClient.currentBackend(modelManager: modelManager, preferredMLXModelID: preferred)
            }
            switch backend {
            case .mlx(let id):
                if let modelManager { client = MLXLocalClient(modelManager: modelManager, preferredModelID: id) }
                model = id
                label = ModelCatalog.entry(for: id)?.displayName ?? id
            case .appleOnDevice:
                client = AppleFoundationClient()
                model = AppleFoundationClient.modelID
                label = AppleFoundationClient.displayName
            case .none:
                break
            }
        } else if client is AppleFoundationClient {
            label = AppleFoundationClient.displayName
        }

        return endpoint(client: client, model: model, label: label, providerName: provider.displayName, locality: provider.locality(settings: settings))
    }

    /// The endpoint for a given client. Pure apart from type checks; for tests.
    nonisolated static func endpoint(
        client: any LLMClient,
        model: String,
        label: String? = nil,
        providerName: String,
        locality: DataLocality
    ) -> AgentHarness.Endpoint {
        let family = AgentModelFamily.detect(clientTypeName: String(describing: type(of: client)), modelID: model)
        return AgentHarness.Endpoint(
            backend: backend(for: client, family: family),
            family: family,
            model: model,
            modelLabel: label ?? model,
            providerName: providerName,
            locality: locality
        )
    }

    /// Native tool calling where the client has it, JSON actions elsewhere.
    nonisolated static func backend(for client: any LLMClient, family: AgentModelFamily) -> any AgentBackend {
        if family != .cliAgent {
            if let anthropic = client as? AnthropicClient { return AnthropicToolBackend(client: anthropic) }
            if let openAI = client as? OpenAIClient { return OpenAIToolBackend(client: openAI) }
            if client is AppleFoundationClient { return AppleToolBackend() }
        }
        return JSONActionBackend(client: client)
    }

    /// The tools for a run, with the user's configured destinations.
    static func destinations(settings: AppSettings?) -> AgentDestinations {
        settings.map(AgentDestinations.configured(in:)) ?? AgentDestinations()
    }

    /// The user's own standing instructions (SOUL.md, MEMORY.md) and
    /// personality, capped. Shown in the transcript like everything else.
    static func userInstructions(settings: AppSettings) -> String {
        var parts = [settings.assistantPersonality.promptFragment]
        for (label, path) in [("SOUL.md", LidIAFiles.soulFilePath), ("MEMORY.md", LidIAFiles.memoryFilePath)] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append("\(label):\n\(trimmed.agentTruncated(500))") }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
