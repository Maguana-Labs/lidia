import Foundation
import Observation
import Security

@MainActor
@Observable
final class LLMSettings {
    private var isLoading = false

    // LLM Provider. New users start on-device; never on Ollama, which needs a
    // separately installed server.
    var llmProvider: AppSettings.LLMProvider = .automaticLocal {
        didSet { saveDefault(llmProvider.rawValue, forKey: "llmProvider") }
    }

    /// What happens when a local provider fails and the fallback is cloud.
    /// Default `.ask`: never cross to the cloud without the user's OK.
    var cloudFallbackPolicy: CloudFallbackPolicy = .ask {
        didSet { saveDefault(cloudFallbackPolicy.rawValue, forKey: "cloudFallbackPolicy") }
    }
    var ollamaURL: String = "http://localhost:11434" {
        didSet { saveDefault(ollamaURL, forKey: "ollamaURL") }
    }
    var ollamaModel: String = "" {
        didSet { saveDefault(ollamaModel, forKey: "ollamaModel") }
    }

    // LM Studio (OpenAI-compatible local server)
    var lmStudioURL: String = "http://localhost:1234/v1" {
        didSet { saveDefault(lmStudioURL, forKey: "lmStudioURL") }
    }
    var lmStudioModel: String = "" {
        didSet { saveDefault(lmStudioModel, forKey: "lmStudioModel") }
    }
    var openaiBaseURL: String = "https://api.openai.com/v1" {
        didSet { saveDefault(openaiBaseURL, forKey: "openaiBaseURL") }
    }
    var openaiAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.openai, openaiAPIKey) }
    }
    var openaiModel: String = "" {
        didSet { saveDefault(openaiModel, forKey: "openaiModel") }
    }

    // MLX
    var selectedMLXModelID: String = "" {
        didSet { saveDefault(selectedMLXModelID, forKey: "selectedMLXModelID") }
    }

    // Anthropic
    var anthropicAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.anthropic, anthropicAPIKey) }
    }
    var anthropicModel: String = LLMSettings.defaultAnthropicModel {
        didSet { saveDefault(anthropicModel, forKey: "anthropicModel") }
    }

    // Cerebras
    var cerebrasAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.cerebras, cerebrasAPIKey) }
    }
    var cerebrasModel: String = "llama-3.3-70b" {
        didSet { saveDefault(cerebrasModel, forKey: "cerebrasModel") }
    }

    // DeepSeek
    var deepseekAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.deepseek, deepseekAPIKey) }
    }
    var deepseekModel: String = "deepseek-chat" {
        didSet { saveDefault(deepseekModel, forKey: "deepseekModel") }
    }

    // NVIDIA NIM
    var nvidiaAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.nvidia, nvidiaAPIKey) }
    }
    var nvidiaModel: String = "nvidia/llama-3.3-70b-instruct" {
        didSet { saveDefault(nvidiaModel, forKey: "nvidiaModel") }
    }

    // OpenRouter
    var openRouterAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.openRouter, openRouterAPIKey) }
    }
    var openRouterModel: String = "google/gemini-2.5-flash" {
        didSet { saveDefault(openRouterModel, forKey: "openRouterModel") }
    }
    /// Ask OpenRouter to route only to providers that don't collect data
    /// and keep zero data retention. On by default.
    var openRouterEnforceZDR: Bool = true {
        didSet { saveDefault(openRouterEnforceZDR, forKey: "openRouterEnforceZDR") }
    }

    // Google Gemini (OpenAI-compatible endpoint)
    var geminiAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.gemini, geminiAPIKey) }
    }
    var geminiModel: String = "" {
        didSet { saveDefault(geminiModel, forKey: "geminiModel") }
    }

    // Groq (OpenAI-compatible endpoint)
    var groqAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.groq, groqAPIKey) }
    }
    var groqModel: String = "" {
        didSet { saveDefault(groqModel, forKey: "groqModel") }
    }

    // Custom OpenAI-compatible endpoint (vLLM, self-hosted, other providers)
    var customBaseURL: String = "" {
        didSet { saveDefault(customBaseURL, forKey: "customBaseURL") }
    }
    var customAPIKey: String = "" {
        didSet { scheduleKeyCommit(Self.KeyAccount.custom, customAPIKey) }
    }
    var customModel: String = "" {
        didSet { saveDefault(customModel, forKey: "customModel") }
    }

    // Subscription CLIs. A model of `CLIVendor.defaultModelID` lets the CLI
    // pick its own default (empty would read as "not configured").
    var codexModel: String = CLIVendor.defaultModelID {
        didSet { saveDefault(codexModel, forKey: "codexModel") }
    }
    var grokModel: String = CLIVendor.defaultModelID {
        didSet { saveDefault(grokModel, forKey: "grokModel") }
    }

    // MARK: Hybrid

    /// "Where AI runs" is Hybrid: `llmProvider` stays the local engine and
    /// cloud-placed tasks go to `hybridCloudProvider`. Off for everyone until
    /// they choose it, so existing behaviour never changes on update.
    var hybridEnabled: Bool = false {
        didSet { saveDefault(hybridEnabled, forKey: "hybridEnabled") }
    }
    /// The cloud model Hybrid uses for its cloud tasks.
    var hybridCloudProvider: AppSettings.LLMProvider = .anthropic {
        didSet { saveDefault(hybridCloudProvider.rawValue, forKey: "hybridCloudProvider") }
    }
    /// "Use Hybrid?" was answered (or Hybrid was chosen). Offered once.
    var hybridOfferHandled: Bool = false {
        didSet { saveDefault(hybridOfferHandled, forKey: "hybridOfferHandled") }
    }

    /// The provider last used on each side of "Where AI runs", so switching
    /// back returns to it. Same keys the AI pane used before Hybrid.
    var lastLocalProvider: AppSettings.LLMProvider? {
        get {
            UserDefaults.standard.string(forKey: "settings.lastLocalProvider")
                .flatMap(AppSettings.LLMProvider.init(storedValue:))
                .flatMap { $0.nominalLocality == .cloud ? nil : $0 }
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "settings.lastLocalProvider") }
    }
    var lastCloudProvider: AppSettings.LLMProvider? {
        get {
            UserDefaults.standard.string(forKey: "settings.lastCloudProvider")
                .flatMap(AppSettings.LLMProvider.init(storedValue:))
                .flatMap { $0.nominalLocality == .cloud ? $0 : nil }
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "settings.lastCloudProvider") }
    }

    /// Sync API keys to the user's other devices via iCloud Keychain.
    /// Off by default; keys stay on this Mac.
    var syncKeysViaICloud: Bool = false {
        didSet {
            saveDefault(syncKeysViaICloud, forKey: "syncKeysViaICloud")
            guard !isLoading, oldValue != syncKeysViaICloud else { return }
            // Re-save every key with the new sync setting.
            for account in Self.KeyAccount.all { commitKey(account: account) }
        }
    }

    /// Keychain save failures by account, for "Couldn't save key" in Settings.
    private(set) var keychainErrors: [String: String] = [:]
    private var pendingKeyCommits: [String: Task<Void, Never>] = [:]

    var queryModel: String = "" {
        didSet { saveDefault(queryModel, forKey: "queryModel") }
    }
    var summaryModel: String = "" {
        didSet { saveDefault(summaryModel, forKey: "summaryModel") }
    }
    var routeOverrides: [String: Data] = [:] {
        didSet { saveRouteOverrides() }
    }
    var availableModels: [String] = []

    // Fallback Provider
    var fallbackProvider: String = "" {
        didSet { saveDefault(fallbackProvider, forKey: "fallbackProvider") }
    }
    var fallbackModel: String = "" {
        didSet { saveDefault(fallbackModel, forKey: "fallbackModel") }
    }

    // MARK: - Init

    init() {
        loadFromDefaults()
    }

    func loadFromDefaults() {
        isLoading = true
        defer { isLoading = false }
        let defaults = UserDefaults.standard
        llmProvider = AppSettings.LLMProvider(storedValue: defaults.string(forKey: "llmProvider") ?? "") ?? .automaticLocal
        cloudFallbackPolicy = CloudFallbackPolicy(rawValue: defaults.string(forKey: "cloudFallbackPolicy") ?? "") ?? .ask
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? ""
        lmStudioURL = defaults.string(forKey: "lmStudioURL") ?? "http://localhost:1234/v1"
        lmStudioModel = defaults.string(forKey: "lmStudioModel") ?? ""
        var loadedURL = defaults.string(forKey: "openaiBaseURL") ?? "https://api.openai.com/v1"
        // Migrate old URLs that don't include /v1
        if loadedURL == "https://api.openai.com" {
            loadedURL = "https://api.openai.com/v1"
        }
        openaiBaseURL = loadedURL
        openaiModel = defaults.string(forKey: "openaiModel") ?? ""
        openaiAPIKey = SettingsKeychain.load(key: Self.KeyAccount.openai) ?? ""
        selectedMLXModelID = defaults.string(forKey: "selectedMLXModelID") ?? ""
        anthropicAPIKey = SettingsKeychain.load(key: Self.KeyAccount.anthropic) ?? ""
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? Self.defaultAnthropicModel
        cerebrasAPIKey = SettingsKeychain.load(key: Self.KeyAccount.cerebras) ?? ""
        cerebrasModel = defaults.string(forKey: "cerebrasModel") ?? "llama-3.3-70b"
        deepseekAPIKey = SettingsKeychain.load(key: Self.KeyAccount.deepseek) ?? ""
        deepseekModel = defaults.string(forKey: "deepseekModel") ?? "deepseek-chat"
        nvidiaAPIKey = SettingsKeychain.load(key: Self.KeyAccount.nvidia) ?? ""
        nvidiaModel = defaults.string(forKey: "nvidiaModel") ?? "nvidia/llama-3.3-70b-instruct"
        openRouterAPIKey = SettingsKeychain.load(key: Self.KeyAccount.openRouter) ?? ""
        openRouterModel = defaults.string(forKey: "openRouterModel") ?? "google/gemini-2.5-flash"
        openRouterEnforceZDR = defaults.object(forKey: "openRouterEnforceZDR") as? Bool ?? true
        geminiAPIKey = SettingsKeychain.load(key: Self.KeyAccount.gemini) ?? ""
        geminiModel = defaults.string(forKey: "geminiModel") ?? ""
        groqAPIKey = SettingsKeychain.load(key: Self.KeyAccount.groq) ?? ""
        groqModel = defaults.string(forKey: "groqModel") ?? ""
        customBaseURL = defaults.string(forKey: "customBaseURL") ?? ""
        customAPIKey = SettingsKeychain.load(key: Self.KeyAccount.custom) ?? ""
        customModel = defaults.string(forKey: "customModel") ?? ""
        codexModel = defaults.string(forKey: "codexModel").flatMap { $0.isEmpty ? nil : $0 } ?? CLIVendor.defaultModelID
        grokModel = defaults.string(forKey: "grokModel").flatMap { $0.isEmpty ? nil : $0 } ?? CLIVendor.defaultModelID
        hybridEnabled = defaults.bool(forKey: "hybridEnabled")
        hybridCloudProvider = AppSettings.LLMProvider(storedValue: defaults.string(forKey: "hybridCloudProvider") ?? "")
            .flatMap { $0.nominalLocality == .cloud ? $0 : nil } ?? .anthropic
        hybridOfferHandled = defaults.bool(forKey: "hybridOfferHandled")
        syncKeysViaICloud = defaults.bool(forKey: "syncKeysViaICloud")
        queryModel = defaults.string(forKey: "queryModel") ?? ""
        summaryModel = defaults.string(forKey: "summaryModel") ?? ""
        fallbackProvider = defaults.string(forKey: "fallbackProvider") ?? ""
        fallbackModel = defaults.string(forKey: "fallbackModel") ?? ""
        loadRouteOverrides()
    }

    // MARK: - Route Override Persistence

    func routeConfig(for taskType: LLMTaskType) -> LLMRouteConfig? {
        guard let data = routeOverrides[taskType.rawValue] else { return nil }
        return try? JSONDecoder().decode(LLMRouteConfig.self, from: data)
    }

    func setRouteConfig(_ config: LLMRouteConfig?, for taskType: LLMTaskType) {
        if let config, let data = try? JSONEncoder().encode(config) {
            routeOverrides[taskType.rawValue] = data
        } else {
            routeOverrides.removeValue(forKey: taskType.rawValue)
        }
    }

    private func saveRouteOverrides() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(routeOverrides) {
            UserDefaults.standard.set(data, forKey: "routeOverrides")
        }
    }

    private func loadRouteOverrides() {
        guard let data = UserDefaults.standard.data(forKey: "routeOverrides"),
              let saved = try? JSONDecoder().decode([String: Data].self, from: data) else {
            return
        }
        routeOverrides = saved
    }

    // MARK: - API keys

    /// Fallback Anthropic model when none is chosen and none was fetched.
    nonisolated static let defaultAnthropicModel = "claude-sonnet-5-5"

    /// Keychain account names. Unchanged from earlier builds so stored keys
    /// keep working.
    enum KeyAccount {
        static let openai = "lidia.openai.apiKey"
        static let anthropic = "lidia.anthropic.apiKey"
        static let cerebras = "lidia.cerebras.apiKey"
        static let deepseek = "lidia.deepseek.apiKey"
        static let nvidia = "lidia.nvidia.apiKey"
        static let openRouter = "lidia.openrouter.apiKey"
        static let gemini = "lidia.gemini.apiKey"
        static let groq = "lidia.groq.apiKey"
        static let custom = "lidia.customOpenAI.apiKey"

        static let all = [openai, anthropic, cerebras, deepseek, nvidia, openRouter, gemini, groq, custom]

        static func account(for provider: AppSettings.LLMProvider) -> String? {
            switch provider {
            case .openai: return openai
            case .anthropic: return anthropic
            case .cerebras: return cerebras
            case .deepseek: return deepseek
            case .nvidiaNIM: return nvidia
            case .openRouter: return openRouter
            case .gemini: return gemini
            case .groq: return groq
            case .openAICompatible: return custom
            case .automaticLocal, .appleOnDevice, .mlx, .ollama, .lmStudio, .codexCLI, .grokCLI: return nil
            }
        }
    }

    /// The in-memory key for a provider ("" when none).
    func apiKey(for provider: AppSettings.LLMProvider) -> String {
        guard let account = KeyAccount.account(for: provider) else { return "" }
        return currentValue(account: account)
    }

    private func currentValue(account: String) -> String {
        switch account {
        case KeyAccount.openai: return openaiAPIKey
        case KeyAccount.anthropic: return anthropicAPIKey
        case KeyAccount.cerebras: return cerebrasAPIKey
        case KeyAccount.deepseek: return deepseekAPIKey
        case KeyAccount.nvidia: return nvidiaAPIKey
        case KeyAccount.openRouter: return openRouterAPIKey
        case KeyAccount.gemini: return geminiAPIKey
        case KeyAccount.groq: return groqAPIKey
        case KeyAccount.custom: return customAPIKey
        default: return ""
        }
    }

    /// Writes the provider's key to the Keychain now (on submit, focus loss
    /// or validation). Returns false and records an error if it failed.
    @discardableResult
    func commitAPIKey(for provider: AppSettings.LLMProvider) -> Bool {
        guard let account = KeyAccount.account(for: provider) else { return true }
        return commitKey(account: account)
    }

    /// Writes every pending key now (e.g. when Settings closes).
    func commitPendingAPIKeys() {
        for account in pendingKeyCommits.keys { commitKey(account: account) }
    }

    @discardableResult
    private func commitKey(account: String) -> Bool {
        pendingKeyCommits[account]?.cancel()
        pendingKeyCommits[account] = nil
        let status = SettingsKeychain.save(key: account, value: currentValue(account: account), synchronizable: syncKeysViaICloud)
        if status == errSecSuccess {
            keychainErrors[account] = nil
            return true
        }
        keychainErrors[account] = SettingsKeychain.KeychainError.unexpectedStatus(status).localizedDescription
        return false
    }

    /// Typing in a key field doesn't hit the Keychain on every keystroke:
    /// the write happens once typing pauses, or immediately via `commitAPIKey`.
    private func scheduleKeyCommit(_ account: String, _ value: String) {
        guard !isLoading else { return }
        pendingKeyCommits[account]?.cancel()
        pendingKeyCommits[account] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.commitKey(account: account)
        }
    }

    // MARK: - Persistence Helpers

    private func saveDefault(_ value: some Any, forKey key: String) {
        guard !isLoading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
