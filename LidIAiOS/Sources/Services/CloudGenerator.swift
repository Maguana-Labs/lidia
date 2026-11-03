import Foundation
import LidIAIntelligence

/// A cloud model with the user's own key (Anthropic or OpenAI), streaming.
/// Only built when the user picked it in Settings and Local-only is off.
struct CloudGenerator: TextGenerator {
    enum Provider: Sendable {
        case anthropic
        case openAI
    }

    let provider: Provider
    let apiKey: String
    let model: String

    var displayName: String {
        switch provider {
        case .anthropic: "Claude"
        case .openAI: "OpenAI"
        }
    }

    var isOnDevice: Bool { false }
    /// Generous but bounded: long meetings still go through map-reduce.
    var contextTokens: Int { 120_000 }

    func countTokens(_ text: String) async throws -> Int { TokenEstimate.estimate(text) }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        var text = ""
        for try await delta in stream(instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature) {
            text += delta
        }
        return text
    }

    func stream(instructions: String, prompt: String, maxTokens: Int, temperature: Double) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let provider = provider
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw GeneratorError.unavailable(Self.message(status: status, body: body))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let delta = Self.delta(from: json, provider: provider), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(instructions: String, prompt: String, maxTokens: Int, temperature: Double) throws -> URLRequest {
        switch provider {
        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": max(maxTokens, 1024) * 2,
                "system": instructions,
                "stream": true,
                "messages": [["role": "user", "content": prompt]],
                // Effort at most medium, as on the Mac.
                "output_config": ["effort": "medium"],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        case .openAI:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": model,
                "stream": true,
                "max_completion_tokens": max(maxTokens, 1024) * 2,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": prompt],
                ],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private static func delta(from json: [String: Any], provider: Provider) -> String? {
        switch provider {
        case .anthropic:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        case .openAI:
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return nil }
            return delta["content"] as? String
        }
    }

    private static func message(status: Int, body: String) -> String {
        switch status {
        case 401, 403: return "The API key was rejected. Check it in Settings."
        case 429: return "The provider is rate-limiting this key. Try again in a minute."
        case 0: return "Couldn't reach the provider. Check your connection."
        default:
            let detail = body.isEmpty ? "" : " (\(body.prefix(160)))"
            return "The provider returned an error \(status)\(detail)."
        }
    }
}
