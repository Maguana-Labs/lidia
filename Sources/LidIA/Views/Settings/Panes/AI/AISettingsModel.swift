import AppKit
import SwiftUI

/// State and actions behind Settings › AI and its sub-pages: key validation,
/// model discovery and the model menus. Moved from the old AI Models tab
/// without changing behavior.
@MainActor
@Observable
final class AISettingsModel {
    enum KeyStatus: Equatable {
        case testing
        case result(KeyValidationResult)
    }

    static let customSentinel = "__custom__"
    private static let showAllModelsKey = "settings.showAdvancedModels"

    var modelFetchError: String?
    var modelFetchSuccess: String?
    var isFetchingModels = false
    var keyStatus: [AppSettings.LLMProvider: KeyStatus] = [:]
    var lastFreedBytes: Int64?
    /// Text typed after choosing "Custom…" in a model menu, per menu.
    var customModelText: [String: String] = [:]
    /// Installed / signed-in state of the subscription CLIs.
    var cliStatus: [CLIVendor: CLIStatus] = [:]
    var cliChecking: Set<CLIVendor> = []
    /// Models listed by a cloud provider that isn't the main one (Hybrid's cloud side).
    var cloudModels: [AppSettings.LLMProvider: [String]] = [:]
    var cloudModelError: [AppSettings.LLMProvider: String] = [:]
    var fetchingCloudModels: Set<AppSettings.LLMProvider> = []

    /// Show every model the provider lists, not just the curated ones.
    var showAllModels: Bool = UserDefaults.standard.bool(forKey: AISettingsModel.showAllModelsKey) {
        didSet { UserDefaults.standard.set(showAllModels, forKey: Self.showAllModelsKey) }
    }

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - Where AI runs

    func mode(settings: AppSettings) -> AIRunMode {
        runMode(settings: settings)
    }

    func setMode(_ mode: AIRunMode, settings: AppSettings) {
        setRunMode(mode, settings: settings)
    }

    /// Engines for "On this Mac" (and Hybrid's local side), in menu groups.
    var localProviderGroups: [(title: String?, providers: [AppSettings.LLMProvider])] {
        [
            (nil, AppSettings.LLMProvider.providers(in: .onThisMac)),
            ("Local server", AppSettings.LLMProvider.providers(in: .localServer)),
        ]
    }

    /// Cloud providers: API keys, then subscriptions.
    var cloudProviderGroups: [(title: String?, providers: [AppSettings.LLMProvider])] {
        [
            ("Your API key", AppSettings.LLMProvider.providers(in: .cloud)),
            ("Your subscription", AppSettings.LLMProvider.providers(in: .subscription)),
        ]
    }

    /// Answers "Use Hybrid?". Either answer is final: it's offered once.
    func answerHybridOffer(accept: Bool, provider: AppSettings.LLMProvider, settings: AppSettings) {
        settings.llm.hybridOfferHandled = true
        guard accept else { return }
        settings.llm.hybridCloudProvider = provider
        setRunMode(.hybrid, settings: settings)
    }

    /// Clears what belonged to the previous provider. Same as the old tab.
    func providerDidChange(settings: AppSettings) {
        settings.availableModels = []
        settings.queryModel = ""
        settings.summaryModel = ""
        modelFetchError = nil
        modelFetchSuccess = nil
    }

    // MARK: - Keys

    func keyBinding(for provider: AppSettings.LLMProvider, settings: AppSettings) -> Binding<String> {
        let llm = settings.llm
        switch provider {
        case .openai: return Binding(get: { llm.openaiAPIKey }, set: { llm.openaiAPIKey = $0 })
        case .anthropic: return Binding(get: { llm.anthropicAPIKey }, set: { llm.anthropicAPIKey = $0 })
        case .cerebras: return Binding(get: { llm.cerebrasAPIKey }, set: { llm.cerebrasAPIKey = $0 })
        case .deepseek: return Binding(get: { llm.deepseekAPIKey }, set: { llm.deepseekAPIKey = $0 })
        case .nvidiaNIM: return Binding(get: { llm.nvidiaAPIKey }, set: { llm.nvidiaAPIKey = $0 })
        case .openRouter: return Binding(get: { llm.openRouterAPIKey }, set: { llm.openRouterAPIKey = $0 })
        case .gemini: return Binding(get: { llm.geminiAPIKey }, set: { llm.geminiAPIKey = $0 })
        case .groq: return Binding(get: { llm.groqAPIKey }, set: { llm.groqAPIKey = $0 })
        case .openAICompatible: return Binding(get: { llm.customAPIKey }, set: { llm.customAPIKey = $0 })
        case .automaticLocal, .appleOnDevice, .mlx, .ollama, .lmStudio, .codexCLI, .grokCLI: return .constant("")
        }
    }

    func validateKey(for provider: AppSettings.LLMProvider, settings: AppSettings, modelManager: ModelManager) async {
        settings.llm.commitAPIKey(for: provider)
        guard let method = ProviderKeyValidator.method(for: provider, settings: settings) else {
            keyStatus[provider] = .result(.unreachable("enter a valid base URL first"))
            return
        }
        keyStatus[provider] = .testing
        let result = await ProviderKeyValidator.validate(
            apiKey: settings.llm.apiKey(for: provider),
            method: method,
            isGemini: provider == .gemini
        )
        keyStatus[provider] = .result(result)

        // A working key for the main provider: pick a model if none is set.
        if result.isUsable, provider == settings.llmProvider,
           storedModel(for: provider, settings: settings).isEmpty {
            await fetchModels(settings: settings, modelManager: modelManager)
            let auto = ModelMenuCatalog.autoModel(for: provider, availableModels: settings.availableModels)
            if !auto.isEmpty { defaultModelBinding(settings: settings).wrappedValue = auto }
        }
    }

    static func symbol(for result: KeyValidationResult) -> String {
        switch result {
        case .valid: return "checkmark.circle.fill"
        case .validButLimited: return "exclamationmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .unreachable, .notConfigured: return "questionmark.circle.fill"
        }
    }

    static func color(for result: KeyValidationResult) -> Color {
        switch result {
        case .valid: return .green
        case .validButLimited, .unreachable: return .orange
        case .rejected: return .red
        case .notConfigured: return .secondary
        }
    }

    // MARK: - Models

    func defaultModelBinding(settings: AppSettings) -> Binding<String> {
        modelBinding(for: settings.llmProvider, settings: settings)
    }

    /// The stored model of any provider. For the subscription CLIs, "" in the
    /// menu means the CLI's own default.
    func modelBinding(for provider: AppSettings.LLMProvider, settings: AppSettings) -> Binding<String> {
        let llm = settings.llm
        switch provider {
        case .automaticLocal, .appleOnDevice, .mlx:
            return Binding(get: { llm.selectedMLXModelID }, set: { llm.selectedMLXModelID = $0 })
        case .ollama:
            return Binding(get: { llm.ollamaModel }, set: { llm.ollamaModel = $0 })
        case .lmStudio:
            return Binding(get: { llm.lmStudioModel }, set: { llm.lmStudioModel = $0 })
        case .openai:
            return Binding(get: { llm.openaiModel }, set: { llm.openaiModel = $0 })
        case .anthropic:
            return Binding(get: { llm.anthropicModel }, set: { llm.anthropicModel = $0 })
        case .cerebras:
            return Binding(get: { llm.cerebrasModel }, set: { llm.cerebrasModel = $0 })
        case .deepseek:
            return Binding(get: { llm.deepseekModel }, set: { llm.deepseekModel = $0 })
        case .nvidiaNIM:
            return Binding(get: { llm.nvidiaModel }, set: { llm.nvidiaModel = $0 })
        case .openRouter:
            return Binding(get: { llm.openRouterModel }, set: { llm.openRouterModel = $0 })
        case .gemini:
            return Binding(get: { llm.geminiModel }, set: { llm.geminiModel = $0 })
        case .groq:
            return Binding(get: { llm.groqModel }, set: { llm.groqModel = $0 })
        case .openAICompatible:
            return Binding(get: { llm.customModel }, set: { llm.customModel = $0 })
        case .codexCLI:
            return Binding(
                get: { CLIVendor.isDefaultModel(llm.codexModel) ? "" : llm.codexModel },
                set: { llm.codexModel = $0.isEmpty ? CLIVendor.defaultModelID : $0 }
            )
        case .grokCLI:
            return Binding(
                get: { CLIVendor.isDefaultModel(llm.grokModel) ? "" : llm.grokModel },
                set: { llm.grokModel = $0.isEmpty ? CLIVendor.defaultModelID : $0 }
            )
        }
    }

    /// Menu entries for a cloud provider other than the main one.
    func cloudModelsForMenu(_ provider: AppSettings.LLMProvider, selection: String, settings: AppSettings) -> [String] {
        let listed = provider == settings.llmProvider && !settings.availableModels.isEmpty
            ? settings.availableModels
            : (cloudModels[provider] ?? [])
        var options = listed.isEmpty
            ? ModelMenuCatalog.knownModels(for: provider)
            : (showAllModels ? listed : ModelMenuCatalog.curatedModels(for: provider, availableModels: listed))
        if !selection.isEmpty, selection != Self.customSentinel, !options.contains(selection) {
            options.insert(selection, at: 0)
        }
        return options
    }

    /// Lists a cloud provider's models without touching the main provider's
    /// list. Sets the provider's model when none was chosen.
    func fetchCloudModels(_ provider: AppSettings.LLMProvider, settings: AppSettings, modelManager: ModelManager) async {
        cloudModelError[provider] = nil
        fetchingCloudModels.insert(provider)
        defer { fetchingCloudModels.remove(provider) }
        settings.llm.commitAPIKey(for: provider)
        guard let client = makeClientForProvider(provider, settings: settings, modelManager: modelManager) else {
            cloudModelError[provider] = "\(provider.displayName) is not configured."
            return
        }
        do {
            let models = try await client.listModels()
            cloudModels[provider] = models
            if models.isEmpty {
                cloudModelError[provider] = "No models listed. You can type a model name."
            } else if storedModel(for: provider, settings: settings).isEmpty {
                let auto = ModelMenuCatalog.autoModel(for: provider, availableModels: models)
                if !auto.isEmpty { modelBinding(for: provider, settings: settings).wrappedValue = auto }
            }
        } catch {
            cloudModelError[provider] = error.localizedDescription
        }
    }

    // MARK: - Subscriptions

    func refreshCLIStatus(_ vendor: CLIVendor) async {
        guard !cliChecking.contains(vendor) else { return }
        cliChecking.insert(vendor)
        defer { cliChecking.remove(vendor) }
        cliStatus[vendor] = await CLIDetector.detect(vendor)
    }

    /// Opens Terminal running the vendor's own sign-in (`codex login`,
    /// `grok login`). LidIA never sees the credentials.
    func signIn(_ vendor: CLIVendor) {
        guard let executable = vendor.resolveExecutable() else { return }
        let script = """
            #!/bin/sh
            echo "Signing in to your \(vendor.planName) plan for LidIA."
            echo
            \(vendor.loginCommand(executable: executable))
            echo
            echo "Done. You can close this window and return to LidIA."
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LidIA \(vendor.toolName) sign in.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            cliStatus[vendor] = CLIStatus(executable: executable, version: nil, signIn: .unknown(error.localizedDescription))
        }
    }

    func modelsForMenu(selection: String, settings: AppSettings) -> [String] {
        let baseModels: [String]
        if settings.availableModels.isEmpty {
            baseModels = ModelMenuCatalog.knownModels(for: settings.llmProvider)
        } else if showAllModels {
            baseModels = settings.availableModels
        } else {
            baseModels = ModelMenuCatalog.curatedModels(for: settings.llmProvider, availableModels: settings.availableModels)
        }

        var seen = Set<String>()
        var options: [String] = []
        for model in baseModels where seen.insert(model).inserted {
            options.append(model)
        }
        if !selection.isEmpty, selection != Self.customSentinel, !options.contains(selection) {
            options.insert(selection, at: 0)
        }
        return options
    }

    func modelsForRouteProvider(_ provider: AppSettings.LLMProvider, settings: AppSettings, modelManager: ModelManager) -> [String] {
        if provider == settings.llmProvider && !settings.availableModels.isEmpty {
            return ModelMenuCatalog.curatedModels(for: provider, availableModels: settings.availableModels)
        }
        if provider == .mlx || provider == .automaticLocal {
            return modelManager.downloadedEntries.map(\.id)
        }
        if let listed = cloudModels[provider], !listed.isEmpty {
            return ModelMenuCatalog.curatedModels(for: provider, availableModels: listed)
        }
        return ModelMenuCatalog.knownModels(for: provider)
    }

    /// Whether a Hybrid row can pick `provider` now (see `isProviderSelectable`).
    func isSelectable(_ provider: AppSettings.LLMProvider, settings: AppSettings, modelManager: ModelManager) -> Bool {
        isProviderSelectable(
            provider,
            settings: settings,
            cliReady: { self.cliStatus[$0]?.isReady ?? false },
            hasDownloadedModel: !modelManager.downloadedEntries.isEmpty
        )
    }

    func fetchModels(settings: AppSettings, modelManager: ModelManager) async {
        modelFetchError = nil
        modelFetchSuccess = nil
        isFetchingModels = true
        defer { isFetchingModels = false }

        // Discover models for the provider the user is configuring here —
        // not for whatever the chat route override happens to point at.
        settings.llm.commitAPIKey(for: settings.llmProvider)
        guard let client = makeClientForProvider(settings.llmProvider, settings: settings, modelManager: modelManager) else {
            modelFetchError = "\(settings.llmProvider.displayName) is not configured."
            return
        }
        do {
            let models = try await client.listModels()
            settings.availableModels = models
            if models.isEmpty {
                switch settings.llmProvider {
                case .lmStudio:
                    modelFetchError = "LM Studio returned no models. Open LM Studio → Developer tab, click Start Server, and make sure a model is loaded."
                case .ollama:
                    modelFetchError = "Ollama returned no models. Pull a model first (e.g. `ollama pull qwen3:4b`)."
                case .codexCLI, .grokCLI:
                    modelFetchError = "The CLI listed no models. Its default model is used."
                default:
                    modelFetchError = "Provider returned no models. You can type a model name manually."
                }
            } else {
                let plural = models.count == 1 ? "" : "s"
                modelFetchSuccess = "Found \(models.count) model\(plural)."
            }
        } catch {
            switch settings.llmProvider {
            case .lmStudio:
                modelFetchError = "Could not reach LM Studio at \(settings.lmStudioURL): \(error.localizedDescription). Make sure LM Studio is open and the Developer-tab server is started."
            case .ollama:
                modelFetchError = "Could not reach Ollama at \(settings.ollamaURL): \(error.localizedDescription)."
            default:
                modelFetchError = "Failed to fetch models: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Automatic status

    func automaticStatus(settings: AppSettings, modelManager: ModelManager) -> String {
        switch AutomaticLocalClient.currentBackend(modelManager: modelManager, preferredMLXModelID: settings.selectedMLXModelID) {
        case .mlx(let id):
            let name = ModelCatalog.entry(for: id)?.displayName ?? id
            return "Using \(name). Meeting data never leaves this Mac."
        case .appleOnDevice:
            return "Using Apple Intelligence until you download a model. \(ModelCatalog.recommendedForThisMac.displayName) gives better summaries."
        case .none:
            return "Not set up yet. Download a model, or use your API key."
        }
    }
}
