import Foundation
import Testing
@testable import LidIA

// MARK: - Any provider per task

extension LocalOnlyModeTests {
    @Suite("Hybrid: any provider per task")
    @MainActor
    struct HybridAnyProviderTests {
        @Test("A row can pick any provider + model; the default pair clears the override")
        func anyProvider() async {
            await withHybridSettings { settings in
                settings.llm.hybridEnabled = true
                setTaskRoute(provider: .ollama, model: "qwen3:4b", for: .summarization, settings: settings)
                #expect(resolveRoute(settings: settings, taskType: .summarization) == LLMRoute(provider: .ollama, model: "qwen3:4b", source: .override))
                #expect(effectiveModel(for: .summary, settings: settings, taskType: .summarization) == "qwen3:4b")

                setTaskRoute(provider: .codexCLI, model: "", for: .actionItems, settings: settings)
                #expect(resolvedProvider(settings: settings, taskType: .actionItems) == .codexCLI)
                #expect(effectiveModel(for: .query, settings: settings, taskType: .actionItems) == settings.llm.codexModel)

                setTaskRoute(provider: .openAICompatible, model: "", for: .summarization, settings: settings)
                #expect(settings.routeConfig(for: .summarization) == nil)
                setTaskRoute(provider: .appleOnDevice, model: "", for: .actionItems, settings: settings)
                #expect(settings.routeConfig(for: .actionItems) == nil)
            }
        }

        @Test("Only configured providers are selectable")
        func selectable() async {
            await withHybridSettings { settings in
                let ready: (CLIVendor) -> Bool = { $0 == .codex }
                #expect(isProviderSelectable(.codexCLI, settings: settings, cliReady: ready, hasDownloadedModel: false))
                #expect(!isProviderSelectable(.grokCLI, settings: settings, cliReady: ready, hasDownloadedModel: false))
                #expect(!isProviderSelectable(.mlx, settings: settings, cliReady: ready, hasDownloadedModel: false))
                #expect(isProviderSelectable(.mlx, settings: settings, cliReady: ready, hasDownloadedModel: true))
                #expect(isProviderSelectable(.automaticLocal, settings: settings, cliReady: ready, hasDownloadedModel: false))
                #expect(isProviderSelectable(.openAICompatible, settings: settings, cliReady: ready, hasDownloadedModel: false))
                settings.llm.customBaseURL = ""
                #expect(!isProviderSelectable(.openAICompatible, settings: settings, cliReady: ready, hasDownloadedModel: false))
                // Every provider appears in exactly one group of the picker.
                let all = taskProviderGroups.flatMap(\.providers)
                #expect(Set(all) == Set(AppSettings.LLMProvider.allCases))
                #expect(all.count == AppSettings.LLMProvider.allCases.count)
            }
        }
    }
}

@Suite("Data handling")
struct DataHandlingTests {
    @Test("OpenRouter's zero-retention routing uses its documented provider preferences")
    func openRouterZDR() {
        let expected: JSONValue = .object(["zdr": .bool(true), "data_collection": .string("deny")])
        #expect(OpenAIClient.openRouterZDRBody["provider"] == expected)
    }

    @MainActor
    @Test("Cloud providers with a known policy have a one-line note; Gemini warns about its free tier")
    func notes() {
        let settings = AppSettings()
        #expect(AppSettings.LLMProvider.anthropic.privacyNote(settings: settings) != nil)
        #expect(AppSettings.LLMProvider.openai.privacyNote(settings: settings)?.contains("30 days") == true)
        #expect(AppSettings.LLMProvider.gemini.dataBadge(settings: settings)?.isWarning == true)
        #expect(AppSettings.LLMProvider.mlx.dataBadge(settings: settings) == nil)
    }
}
