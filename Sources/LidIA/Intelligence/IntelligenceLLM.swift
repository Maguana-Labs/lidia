import Foundation

/// The one way the Intelligence features use AI: short, low-effort requests
/// through the app's gated client factory (`makeLLMClient`), so Local-only
/// mode and the cloud switch apply exactly as everywhere else. Everything
/// that can be done without AI (scoring, mining, drafting) is.
@MainActor
enum IntelligenceLLM {
    /// Why AI can't be used right now, or nil when it can.
    static func unavailableReason(settings: AppSettings) -> String? {
        let provider = resolvedProvider(settings: settings, taskType: .chat)
        if let blocked = providerBlockedError(provider, for: .primary, settings: settings) {
            return blocked.localizedDescription
        }
        return effectiveModel(for: .query, settings: settings, taskType: .chat).isEmpty
            ? "Choose an AI model in Settings → AI."
            : nil
    }

    /// One short completion. Uses the streaming call, which asks Claude for
    /// low effort, and stops after `maxCharacters`.
    static func complete(
        system: String,
        user: String,
        settings: AppSettings,
        modelManager: ModelManager? = nil,
        maxCharacters: Int = 1_500
    ) async throws -> String {
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .chat)
        let model = effectiveModel(for: .query, settings: settings, taskType: .chat)
        guard !model.isEmpty else { throw LLMError.setupRequired("Choose an AI model in Settings → AI.") }
        var output = ""
        let stream = await client.chatStream(
            messages: [LLMChatMessage(role: "system", content: system), LLMChatMessage(role: "user", content: user)],
            model: model
        )
        for try await chunk in stream {
            output += chunk
            if output.count >= maxCharacters { break }
        }
        return ReasoningFilter.strip(output)
    }

    /// The first JSON object in a response.
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Project names

    /// A short project name for a group of meetings, or nil. Only titles and
    /// company names are sent, never notes or transcripts.
    static func suggestProjectName(
        titles: [String],
        companies: [String],
        settings: AppSettings,
        modelManager: ModelManager? = nil
    ) async -> String? {
        let system = """
        You name projects for a meeting-notes app. Reply with a JSON object {"name": "..."}: \
        a 1–3 word project name taken from the client, product or initiative the meetings share. \
        No dates, no generic words like "Meetings" or "Calls".
        """
        let user = "Meeting titles:\n" + titles.prefix(12).map { "- " + $0 }.joined(separator: "\n")
            + (companies.isEmpty ? "" : "\nCompanies: " + companies.joined(separator: ", "))
        guard let text = try? await complete(system: system, user: user, settings: settings, modelManager: modelManager, maxCharacters: 300),
              let name = (jsonObject(in: text)?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 40 else { return nil }
        return name
    }
}
