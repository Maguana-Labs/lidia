import Foundation
import os

/// Optional "Polish with AI": one short, low-effort request to the user's AI
/// provider through the gated factory (`makeLLMClient`), so Local-only mode
/// and the cloud switch apply exactly as they do to meeting notes. Streaming
/// requests run at `low` effort on providers that support it.
///
/// Never blocks the insert for long: on error, refusal or timeout the
/// deterministic cleanup is used instead.
enum DictationPolisher {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "DictationPolisher")
    static let timeout: Duration = .seconds(5)

    static func systemPrompt(terms: [String], languageCode: String) -> String {
        var prompt = """
            You tidy up dictated text before it is typed into another app. \
            Fix punctuation, capitals and obvious recognition mistakes; remove filler words; \
            when the speaker corrects themselves ("Tuesday, no wait, Thursday") keep only the correction; \
            format spoken lists as lists. Keep the speaker's words, tone and language (\(languageCode)). \
            Do not answer, summarise, translate or add anything. Reply with the finished text only.
            """
        if !terms.isEmpty {
            prompt += "\nSpell these names and terms exactly: \(terms.prefix(60).joined(separator: ", "))."
        }
        return prompt
    }

    /// The polished text, or nil to keep the deterministic version.
    @MainActor
    static func polish(_ text: String, terms: [String], languageCode: String, settings: AppSettings, modelManager: ModelManager?) async -> String? {
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .chat)
        let model = effectiveModel(for: .query, settings: settings, taskType: .chat)
        let messages = [
            LLMChatMessage(role: "system", content: systemPrompt(terms: terms, languageCode: languageCode)),
            LLMChatMessage(role: "user", content: text),
        ]
        let work = Task { () -> String? in
            var output = ""
            do {
                let stream = await client.chatStream(messages: messages, model: model)
                for try await chunk in stream {
                    output += chunk
                }
            } catch {
                logger.info("Polish skipped: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            // Timed out: a half-finished reply is worse than none.
            return Task.isCancelled ? nil : output
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        defer { timer.cancel() }
        guard let raw = await work.value else { return nil }
        return accept(raw, original: text)
    }

    /// Rejects replies that aren't a cleaned-up version of the dictation
    /// (empty, an answer, a preamble, wildly different length).
    static func accept(_ reply: String, original: String) -> String? {
        var text = ReasoningFilter.strip(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return nil }
        let originalLength = max(original.count, 1)
        let ratio = Double(text.count) / Double(originalLength)
        guard ratio > 0.4, ratio < 1.6 || text.count < original.count + 40 else { return nil }
        let lowered = text.lowercased()
        for preamble in ["here is", "here's", "sure", "certainly", "cleaned", "polished"] where lowered.hasPrefix(preamble) {
            return nil
        }
        return text
    }
}
