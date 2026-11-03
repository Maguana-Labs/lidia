import Foundation

/// The model families LidIA writes prompts for.
enum AgentModelFamily: String, Codable, Sendable, CaseIterable {
    case claude
    case apple
    /// Qwen, and other open-weight models without a profile of their own.
    case qwen
    case lfm
    case openAICompatible
    /// Agents that run behind a CLI (Codex, Grok): they get JSON actions and
    /// are told not to use their own shell or file tools.
    case cliAgent

    /// Picks the family from the client's type and the model ID. Pure, for tests.
    static func detect(clientTypeName: String, modelID: String) -> AgentModelFamily {
        let type = clientTypeName.lowercased()
        let model = modelID.lowercased()
        // Case-sensitive "CLI": "LLMClient" and "LocalClient" contain "cli".
        if clientTypeName.contains("CLI") || type.contains("codex") || type.contains("grok") || model.hasPrefix("codex") {
            return .cliAgent
        }
        if type.contains("anthropic") || model.hasPrefix("claude") { return .claude }
        if type.contains("applefoundation") || model == AppleFoundationClient.modelID { return .apple }
        if type.contains("openai") { return .openAICompatible }
        if model.contains("lfm") || model.contains("liquid") { return .lfm }
        return .qwen
    }
}

/// What a run is for. Each task adds one or two lines to the prompt.
enum AgentTaskKind: String, Codable, Sendable {
    /// Ask / chat: answer questions about the user's meetings.
    case ask
    /// The voice assistant: the answer is spoken.
    case voice
    /// Kanban "Comment to AI": turn a comment into one proposal.
    case comment
    /// Prepare one action item's next step (a draft, a calendar change).
    case intent
}

/// How tools reach the model.
enum AgentToolFormat: Sendable, Equatable {
    /// Through the provider's tool API: the prompt doesn't list them.
    case native
    /// Through the JSON action format: the prompt lists them compactly.
    case jsonActions
}

/// Inputs to a system prompt. Everything here is visible in the transcript.
struct AgentPromptContext: Sendable {
    var task: AgentTaskKind
    var toolFormat: AgentToolFormat
    var tools: [AgentToolSpec]
    var maxSteps: Int
    var date: Date = .now
    var userName: String = ""
    /// The meeting the user is looking at, as a line ("[id] Title, date").
    var focusMeeting: String?
    /// The user's own standing instructions (SOUL.md / MEMORY.md), capped.
    var userInstructions: String = ""
}

/// Compact system prompts per model family, in one place and versioned.
///
/// Rules for editing them (they were learned the hard way):
/// - Under ~800 tokens each, including the JSON-action tool list.
/// - No example content (sample meetings, names, answers): small models copy
///   examples into answers. Describe formats with placeholders only.
/// - Nothing hidden: meeting data reaches the model only through tool results,
///   which the transcript records.
/// Bump `version` whenever a prompt changes, so transcripts say which one ran.
enum AgentPromptProfiles {
    static let version = "2026-11-03.3"

    static func profileID(_ family: AgentModelFamily) -> String { "\(family.rawValue)" }

    static func system(for family: AgentModelFamily, context: AgentPromptContext) -> String {
        var sections: [String] = [core(context)]
        if let task = taskLines(context.task) { sections.append(task) }
        if let tweak = familyLines(family) { sections.append(tweak) }
        if context.toolFormat == .jsonActions {
            sections.append(jsonActionFormat(tools: context.tools, family: family))
        }
        if let focus = context.focusMeeting {
            sections.append("The user is looking at this meeting: \(focus)")
        }
        let instructions = context.userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            sections.append("The user's standing instructions:\n\(instructions.agentTruncated(1_200))")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Pieces

    private static func core(_ context: AgentPromptContext) -> String {
        let name = context.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "" : " The user is \(name)."
        return """
        You are LidIA, the assistant in the user's meeting-notes app on their Mac. Today is \(AgentDates.day(context.date)) (\(weekday(context.date))).\(who)
        You see the user's meetings and action items only through your tools.
        - For meetings, people, decisions or tasks, call a tool first, even if you think you know. Answer only from tool results; if they lack it, say so.
        - Search results are fragments: read a meeting with get_meeting before saying what was said or agreed.
        - Never invent names, dates, numbers or commitments. Name the meetings you used, with dates.
        - Changes need the user's confirmation in the app; say so. propose_dispatch only drafts.
        - At most \(max(1, context.maxSteps - 1)) tool calls, then answer with what you have.
        - Be brief and plain. No emojis. Reply in the user's language.
        """
    }

    private static func taskLines(_ task: AgentTaskKind) -> String? {
        switch task {
        case .ask:
            return "Cite each fact with its meeting's [id] right after it. Bullets only for lists, tables only to compare."
        case .voice:
            return "Your reply is spoken: one to three short sentences, no markdown, lists or ids. If a change waits for confirmation, ask the user to say yes."
        case .comment:
            return "The user commented on an action item. Make one proposal: propose_dispatch, or update_action_item_status to change its status. Then say what you proposed in one sentence."
        case .intent:
            return """
            Prepare the next step for one action item. The facts below come from the meeting; use find_evidence only if you need what was said.
            - Message or document: call draft_message once, written by the user to the recipients, ready to send. Short, specific, in the meeting's language. Sign with the user's first name.
            - Calendar: call find_free_slots, then propose_event_change for the best slot.
            - Links: only URLs from web search results. Never write a URL you didn't get from a search; write [add a link] instead.
            Then reply "done".
            """
        }
    }

    private static func familyLines(_ family: AgentModelFamily) -> String? {
        switch family {
        case .claude:
            return "Prefer one well-aimed tool call over several broad ones."
        case .apple:
            return "Keep tool queries to one or two key words."
        case .qwen, .lfm:
            return "Copy ids exactly as tools return them."
        case .openAICompatible:
            return nil
        case .cliAgent:
            return "Use only the tools below, never your own shell, file or web tools."
        }
    }

    private static func jsonActionFormat(tools: [AgentToolSpec], family: AgentModelFamily) -> String {
        """
        To use a tool, reply with only this JSON object, nothing else:
        {"tool": "<tool name>", "<argument name>": <value>}
        ? marks optional arguments. The next message has the result. To answer, reply in plain text, not JSON.
        Tools:
        \(tools.map(\.compactLine).joined(separator: "\n"))
        """
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
