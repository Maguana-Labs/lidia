import Foundation

/// Classifies an action item's owner, destination and deadline.
///
/// Evaluated as a "decision model" in docs/research/2026-11-summary-benchmark.md
/// §5. The prompt is shared by the pipeline's destination suggestion and the
/// benchmark, so what was measured is what ships.
enum ActionRouting {
    static let destinations = ["reminder", "clickup", "notion", "n8n", "none"]

    static let systemPrompt = """
        You route action items from meeting notes. The user is the person who took the notes \
        ("Me" in transcripts). Respond with ONLY a JSON object:
        {"owner": "...", "owner_is_user": true|false, "destination": "...", "deadline": "..." or null}

        - "owner": who must do it, exactly as written in the item, or "unknown".
        - "owner_is_user": true only if the user ("Me", "I", or the user's name) must do it.
        - "destination", one of:
          "reminder" — a personal follow-up the user must remember (send, call, check, reply)
          "clickup" — team work to track: a task, ticket, bug, feature or deliverable
          "notion" — writing or updating a document, spec, notes or page
          "n8n" — something that should run automatically or repeatedly (sync, workflow)
          "none" — nothing to track, or someone else's task the user doesn't follow up on
        - "deadline": the deadline exactly as stated in the item, or null. Never invent one.
        """

    /// Dedicated "decision model" pass over a whole transcript (evaluated, not
    /// shipped: see docs/research/2026-11-summary-benchmark.md §5).
    static let extractionPrompt = """
        You find action items in a meeting transcript. "Me" is the user who recorded it. \
        Respond with ONLY a JSON object:
        {"has_action_items": true|false, "evidence": "...", "items": [{"title": "...", "owner": "..." or null, "deadline": "..." or null, "destination": "reminder|clickup|notion|n8n|none"}]}

        - An action item is something a person said they will do, or was asked to do and accepted. \
        Ideas, wishes and "we should think about" are not action items.
        - "evidence": at most 12 words from the transcript showing the clearest commitment, or "".
        - "title": the task, starting with a verb. "owner": the person's name or "Me", exactly as in the \
        transcript, or null. "deadline": as stated, or null. Never invent owners or dates.
        - "destination": "reminder" for the user's own follow-ups, "clickup" for team tasks or tickets, \
        "notion" for documents, "n8n" for recurring automations, "none" for other people's tasks.
        """

    static func userPrompt(meetingTitle: String, item: String) -> String {
        "Meeting: \(meetingTitle)\nAction item: \(item)"
    }

    struct Decision: Sendable, Equatable {
        var owner: String?
        var ownerIsUser: Bool
        var destination: String
        var deadline: String?
    }

    static func parse(_ raw: String) -> Decision? {
        var text = MapReduceSummarizer.stripThinking(raw)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let destination = (object["destination"] as? String ?? "none").lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard destinations.contains(destination) else { return nil }
        func clean(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || ["null", "unknown", "none"].contains(trimmed.lowercased()) ? nil : trimmed
        }
        return Decision(
            owner: clean(object["owner"]),
            ownerIsUser: object["owner_is_user"] as? Bool ?? false,
            destination: destination,
            deadline: clean(object["deadline"])
        )
    }
}
