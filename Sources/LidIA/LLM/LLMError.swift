import Foundation

// MARK: - Unified LLM Error

/// Single error type for all LLM provider failures.
/// Replaces the former per-provider OpenAIError, AnthropicError, and the
/// minimal LLMError that lived in OllamaClient.swift.
enum LLMError: LocalizedError {
    /// Generic network-level failure (URLError, connection refused, etc.)
    case networkError(Error)

    /// Non-2xx HTTP status with optional body/message.
    case httpError(statusCode: Int, message: String?)

    /// JSON or data decoding failure.
    case decodingError(Error)

    /// 401 / missing or invalid API key.
    case authenticationError(String)

    /// 429 — rate limit hit.
    case rateLimited(retryAfter: TimeInterval?)

    /// Requested model does not exist on the provider.
    case modelNotFound(String)

    /// Prompt + history exceeds provider context window.
    case contextLengthExceeded

    /// 5xx from the provider.
    case serverError(String)

    /// Provider could not be reached or is not configured.
    case providerUnavailable(String)

    /// Error during SSE / chunked streaming.
    case streamingError(String)

    /// Response was technically successful but content is unusable.
    case invalidResponse(String)

    /// No usable AI is configured yet (no local model downloaded, Apple
    /// Intelligence unavailable, no cloud provider). Shown as "Finish setup".
    case setupRequired(String)

    /// The request would have sent meeting data to a cloud provider, and the
    /// cloud gate (`allowsCloud(for:settings:)`) or the fallback policy
    /// blocked it. `provider` is the cloud provider that was not used.
    case cloudBlocked(provider: String, reason: String)

    // MARK: - Helpers

    /// HTTP status code when the error maps to one, otherwise -1.
    var statusCode: Int {
        switch self {
        case .httpError(let code, _): return code
        case .authenticationError: return 401
        case .rateLimited: return 429
        case .serverError: return 500
        default: return -1
        }
    }

    var errorDescription: String? {
        switch self {
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .httpError(let code, let message):
            if let message, !message.isEmpty {
                return "HTTP \(code): \(message)"
            }
            return "HTTP \(code)"
        case .decodingError(let underlying):
            return "Decoding error: \(underlying.localizedDescription)"
        case .authenticationError(let message):
            return "Authentication error: \(message)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Retry after \(Int(retryAfter))s."
            }
            return "Rate limited."
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .contextLengthExceeded:
            return "Context length exceeded."
        case .serverError(let message):
            return "Server error: \(message)"
        case .providerUnavailable(let provider):
            return "Provider unavailable: \(provider)"
        case .streamingError(let message):
            return "Streaming error: \(message)"
        case .invalidResponse(let message):
            return message
        case .setupRequired(let message):
            return message
        case .cloudBlocked(let provider, let reason):
            return "Not sent to \(provider): \(reason)"
        }
    }
}
