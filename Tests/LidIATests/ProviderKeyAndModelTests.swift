import Testing
import Foundation
@testable import LidIA

@Suite("Key validation, model selection and provider presets")
struct ProviderKeyAndModelTests {
    private let base = URL(string: "https://api.example.com/v1")!

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Status mapping (research doc §5.2)

    @Test("2xx is valid")
    func valid() {
        #expect(ProviderKeyValidator.interpret(statusCode: 200, body: body("{}"), method: .listModels(base: base)) == .valid(detail: nil))
    }

    @Test("401 and 403 reject the key")
    func rejected() {
        let anthropic = ProviderKeyValidator.interpret(
            statusCode: 401,
            body: body(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
            method: .anthropicModels(base: URL(string: "https://api.anthropic.com")!)
        )
        #expect(anthropic == .rejected("invalid x-api-key"))
        #expect(!ProviderKeyValidator.interpret(statusCode: 403, body: Data(), method: .openRouterKey).isUsable)
    }

    @Test("Gemini's 400 for a bad key is a rejection")
    func geminiBadKey() {
        let json = #"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}]"#
        let result = ProviderKeyValidator.interpret(statusCode: 400, body: body(json), method: .listModels(base: OpenAICompatiblePreset.gemini.baseURL), isGemini: true)
        #expect(result == .rejected("API key not valid. Please pass a valid API key."))
    }

    @Test("402 and 429 mean the key works but is limited")
    func limited() {
        #expect(ProviderKeyValidator.interpret(statusCode: 402, body: Data(), method: .openRouterKey) == .validButLimited("the account is out of credit"))
        #expect(ProviderKeyValidator.interpret(statusCode: 429, body: Data(), method: .listModels(base: base)).isUsable)
    }

    @Test("5xx is 'can't reach provider', never 'valid'")
    func serverError() {
        guard case .unreachable = ProviderKeyValidator.interpret(statusCode: 503, body: Data(), method: .listModels(base: base)) else {
            Issue.record("Expected unreachable")
            return
        }
    }

    @Test("A chat probe past auth (e.g. unknown model) proves the key")
    func chatProbe() {
        let probe = ProviderKeyValidator.Method.chatProbe(base: base, model: "x")
        #expect(ProviderKeyValidator.interpret(statusCode: 404, body: Data(), method: probe).isUsable)
        #expect(!ProviderKeyValidator.interpret(statusCode: 401, body: Data(), method: probe).isUsable)
    }

    @Test("OpenRouter validates against the authenticated /key endpoint and reports credit")
    func openRouter() {
        let request = ProviderKeyValidator.makeRequest(apiKey: "sk-or-1", method: .openRouterKey)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-1")
        let result = ProviderKeyValidator.interpret(
            statusCode: 200,
            body: body(#"{"data":{"label":"x","usage":1.5,"limit":10,"limit_remaining":8.5}}"#),
            method: .openRouterKey
        )
        #expect(result == .valid(detail: "credit left: $8.50"))
    }

    @Test("Anthropic validation uses x-api-key on /v1/models")
    func anthropicRequest() {
        let request = ProviderKeyValidator.makeRequest(apiKey: "sk-ant", method: .anthropicModels(base: URL(string: "https://api.anthropic.com")!))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
    }

    @Test("Empty key is not configured, without a network call")
    func emptyKey() async {
        let result = await ProviderKeyValidator.validate(apiKey: "  ", method: .openRouterKey)
        #expect(result == .notConfigured)
    }

    @MainActor
    @Test("Every cloud provider has a validation method; local ones don't")
    func methods() {
        let settings = AppSettings()
        for provider in AppSettings.LLMProvider.allCases {
            let method = ProviderKeyValidator.method(for: provider, settings: settings)
            switch provider.group {
            case .cloud where provider != .openAICompatible:
                #expect(method != nil, "\(provider) needs a validation method")
            case .onThisMac, .localServer:
                #expect(method == nil)
            default:
                break
            }
        }
        #expect(ProviderKeyValidator.method(for: .openRouter, settings: settings) == .openRouterKey)
    }

    // MARK: - Family preference

    @Test("Anthropic prefers Sonnet, then Opus, then Haiku, newest first")
    func anthropicRanking() {
        let live = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-4-8", "claude-opus-5-5", "claude-sonnet-4-6"]
        let ranked = ModelMenuCatalog.curatedModels(for: .anthropic, availableModels: live)
        #expect(ranked.first == "claude-sonnet-5-5")
        #expect(ranked.firstIndex(of: "claude-sonnet-4-6")! < ranked.firstIndex(of: "claude-opus-5-5")!)
        #expect(ranked.firstIndex(of: "claude-opus-4-8")! < ranked.firstIndex(of: "claude-haiku-5-5")!)
    }

    @Test("Non-chat models are filtered out of OpenAI lists")
    func nonChatFiltered() {
        let ranked = ModelMenuCatalog.curatedModels(
            for: .openai,
            availableModels: ["text-embedding-3-large", "whisper-1", "gpt-5", "tts-1", "gpt-4o"]
        )
        #expect(ranked == ["gpt-5", "gpt-4o"])
    }

    @Test("No hard-coded cloud IDs before a fetch, except the Anthropic fallback")
    func noStaleIDs() {
        #expect(ModelMenuCatalog.knownModels(for: .openai).isEmpty)
        #expect(ModelMenuCatalog.knownModels(for: .openRouter).isEmpty)
        #expect(ModelMenuCatalog.knownModels(for: .anthropic) == [LLMSettings.defaultAnthropicModel])
        #expect(ModelMenuCatalog.autoModel(for: .groq, availableModels: []) == "")
    }

    @Test("Reasoning model markers come from the live list, not hard-coded IDs")
    func reasoningMarkers() {
        #expect(ModelRouter.reasoningMarkers(for: .deepseek) == ["reasoner"])
        #expect(ModelRouter.reasoningMarkers(for: .automaticLocal).isEmpty)
    }

    // MARK: - OpenRouter ZDR body

    @Test("extraBody merges OpenRouter's no-data-collection routing into requests")
    func zdrBody() throws {
        struct Request: Encodable { let model: String }
        let data = try OpenAIClient.encodeBody(Request(model: "m"), extraBody: OpenAIClient.openRouterZDRBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "m")
        let provider = try #require(object["provider"] as? [String: Any])
        #expect(provider["data_collection"] as? String == "deny")
        #expect(provider["zdr"] as? Bool == true)

        let plain = try OpenAIClient.encodeBody(Request(model: "m"), extraBody: [:])
        #expect(String(decoding: plain, as: UTF8.self) == #"{"model":"m"}"#)
    }

    // MARK: - New providers

    @MainActor
    @Test("Gemini, Groq and custom endpoints are cloud by default; a LAN custom endpoint is not")
    func newProviders() {
        let settings = AppSettings()
        let saved = settings.llm.customBaseURL
        defer { settings.llm.customBaseURL = saved }
        #expect(AppSettings.LLMProvider.gemini.locality(settings: settings) == .cloud)
        #expect(AppSettings.LLMProvider.groq.locality(settings: settings) == .cloud)
        settings.llm.customBaseURL = "http://192.168.1.4:8000/v1"
        #expect(AppSettings.LLMProvider.openAICompatible.locality(settings: settings) == .localNetwork)
        settings.llm.customBaseURL = "https://api.together.example/v1"
        #expect(AppSettings.LLMProvider.openAICompatible.locality(settings: settings) == .cloud)
    }

    @Test("Keychain accounts keep their old names")
    func keychainAccounts() {
        #expect(LLMSettings.KeyAccount.account(for: .openai) == "lidia.openai.apiKey")
        #expect(LLMSettings.KeyAccount.account(for: .anthropic) == "lidia.anthropic.apiKey")
        #expect(LLMSettings.KeyAccount.account(for: .openRouter) == "lidia.openrouter.apiKey")
        #expect(LLMSettings.KeyAccount.account(for: .automaticLocal) == nil)
    }

    @MainActor
    @Test("Privacy notes: OpenRouter reflects the ZDR toggle; Cerebras is no longer called free")
    func privacyNotes() {
        let settings = AppSettings()
        let saved = settings.llm.openRouterEnforceZDR
        defer { settings.llm.openRouterEnforceZDR = saved }
        settings.llm.openRouterEnforceZDR = true
        #expect(AppSettings.LLMProvider.openRouter.privacyNote(settings: settings)?.contains("Zero data retention") == true)
        #expect(AppSettings.LLMProvider.cerebras.displayName == "Cerebras")
    }
}
