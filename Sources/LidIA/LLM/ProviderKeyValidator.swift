import Foundation

// MARK: - Result

/// Outcome of checking an API key against its provider.
enum KeyValidationResult: Equatable, Sendable {
    /// The key works. `detail` carries extra info (e.g. OpenRouter credit).
    case valid(detail: String?)
    /// The key is accepted but out of credit or rate-limited.
    case validButLimited(String)
    /// The provider rejected the key.
    case rejected(String)
    /// The provider couldn't be reached or failed; the key is untested.
    case unreachable(String)
    /// No key entered.
    case notConfigured

    var isUsable: Bool {
        switch self {
        case .valid, .validButLimited: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .valid(let detail): return detail.map { "Valid · \($0)" } ?? "Valid"
        case .validButLimited(let reason): return "Key valid, but \(reason)"
        case .rejected(let reason): return "Key rejected: \(reason)"
        case .unreachable(let reason): return "Can't reach provider: \(reason)"
        case .notConfigured: return "No key entered"
        }
    }
}

// MARK: - Validator

/// Validates API keys with one authenticated call per provider. Never falls
/// back to a hard-coded list, and never treats a public endpoint as proof
/// (OpenRouter's /models answers 200 without auth, so it uses /key).
enum ProviderKeyValidator {
    /// How a provider's key is checked.
    enum Method: Equatable, Sendable {
        /// `GET {base}/models` with a Bearer token.
        case listModels(base: URL)
        /// `GET {base}/v1/models` with `x-api-key`.
        case anthropicModels(base: URL)
        /// `GET https://openrouter.ai/api/v1/key` — authenticated; returns credit.
        case openRouterKey
        /// 1-token `POST {base}/chat/completions` (providers without /models).
        case chatProbe(base: URL, model: String)
    }

    @MainActor
    static func method(for provider: AppSettings.LLMProvider, settings: AppSettings) -> Method? {
        switch provider {
        case .openai:
            return .listModels(base: URL(string: settings.openaiBaseURL) ?? URL(string: "https://api.openai.com/v1")!)
        case .anthropic:
            return .anthropicModels(base: URL(string: "https://api.anthropic.com")!)
        case .openRouter:
            return .openRouterKey
        case .cerebras:
            return .listModels(base: URL(string: "https://api.cerebras.ai/v1")!)
        case .deepseek:
            return .listModels(base: URL(string: "https://api.deepseek.com/v1")!)
        case .nvidiaNIM:
            let model = settings.nvidiaModel.isEmpty ? "nvidia/llama-3.3-70b-instruct" : settings.nvidiaModel
            return .chatProbe(base: URL(string: "https://integrate.api.nvidia.com/v1")!, model: model)
        case .gemini:
            return .listModels(base: OpenAICompatiblePreset.gemini.baseURL)
        case .groq:
            return .listModels(base: OpenAICompatiblePreset.groq.baseURL)
        case .openAICompatible:
            guard let base = URL(string: settings.llm.customBaseURL), base.host != nil else { return nil }
            return .listModels(base: base)
        case .automaticLocal, .appleOnDevice, .mlx, .ollama, .lmStudio, .codexCLI, .grokCLI:
            return nil
        }
    }

    /// Checks a key. `isGemini` enables Gemini's "400 = bad key" mapping.
    static func validate(apiKey: String, method: Method, isGemini: Bool = false, session: URLSession = .shared) async -> KeyValidationResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .notConfigured }
        let request = makeRequest(apiKey: key, method: method)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("Unexpected response")
            }
            return interpret(statusCode: http.statusCode, body: data, method: method, isGemini: isGemini)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func makeRequest(apiKey: String, method: Method) -> URLRequest {
        var request: URLRequest
        switch method {
        case .listModels(let base):
            request = URLRequest(url: base.appendingPathComponent("models"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropicModels(let base):
            request = URLRequest(url: base.appendingPathComponent("v1/models"))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouterKey:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .chatProbe(let base, let model):
            request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 1,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 20
        return request
    }

    /// Maps an HTTP result to a validation result (research doc §5.2).
    static func interpret(statusCode: Int, body: Data, method: Method, isGemini: Bool = false) -> KeyValidationResult {
        let text = String(decoding: body.prefix(2048), as: UTF8.self)
        switch statusCode {
        case 200...299:
            if case .openRouterKey = method {
                return .valid(detail: openRouterCreditDetail(body))
            }
            return .valid(detail: nil)
        case 401, 403:
            return .rejected(errorMessage(from: body) ?? "HTTP \(statusCode)")
        case 402:
            return .validButLimited("the account is out of credit")
        case 429:
            return .validButLimited("the provider is rate-limiting this key")
        case 400 where isGemini || looksLikeBadKey(text):
            return .rejected(errorMessage(from: body) ?? "API key not valid")
        case 500...599:
            return .unreachable("provider error (HTTP \(statusCode))")
        default:
            // A chat probe that gets past auth (e.g. 404 unknown model)
            // proves the key; other endpoints shouldn't answer this way.
            if case .chatProbe = method {
                return .valid(detail: "key accepted")
            }
            return .unreachable("unexpected HTTP \(statusCode)")
        }
    }

    private static func looksLikeBadKey(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("api key not valid") || lower.contains("api_key_invalid")
            || lower.contains("invalid api key") || lower.contains("invalid_api_key")
    }

    private static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        if let dict = object as? [String: Any] {
            if let error = dict["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = dict["message"] as? String { return message }
            if let error = dict["error"] as? String { return error }
        }
        if let array = object as? [[String: Any]],
           let error = array.first?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    /// "Credit left: $4.20" from OpenRouter's /key response.
    static func openRouterCreditDetail(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        if let remaining = data["limit_remaining"] as? Double {
            return String(format: "credit left: $%.2f", remaining)
        }
        if let usage = data["usage"] as? Double {
            return String(format: "used: $%.2f", usage)
        }
        return nil
    }
}
