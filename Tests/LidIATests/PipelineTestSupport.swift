import Foundation
import SwiftData
@testable import LidIA

/// Mock `LLMClient` that recognises each pipeline prompt and returns scripted output.
/// `summarizeMeeting` / `refineTranscript` use the protocol's default implementations,
/// which call `chat`, so the real prompt-building code is exercised.
actor ScriptedLLMClient: LLMClient {
    enum Kind: String, Sendable {
        case refine, summarize, facts, map, condense, merge, notesActions, destinations, verify, other
    }

    /// What the streamed markdown summary returns.
    static let defaultSummaryMarkdown = """
        ### Overview
        - Discussed pricing

        ### Next Steps
        - Me: Send deck
        """

    static let defaultFactsJSON = """
        {"title": "Pricing sync", "decisions": ["Ship it"],
         "action_items": [{"title": "Send deck", "assignee": "Me", "deadline": null}]}
        """

    struct Call: Sendable {
        let kind: Kind
        let system: String
        let user: String
    }

    static let defaultSummaryJSON = """
        {"title": "Pricing sync",
         "summary_sections": [{"heading": "Overview", "bullets": [{"text": "Discussed pricing", "source_quote": null}]}],
         "decisions": ["Ship it"],
         "actionItems": [{"title": "Send deck", "assignee": "Me", "deadline": null, "source_quote": null}]}
        """

    private(set) var calls: [Call] = []
    private let failing: Set<Kind>
    private let summaryJSON: String
    private let summaryMarkdown: String
    private let factsJSON: String
    private let mergeJSON: String
    private let notesActionsJSON: String
    private let hook: ChatHook?
    /// Simulates a model that doesn't condense: the condense step echoes its input.
    private let condenseReturnsInput: Bool

    init(
        summaryJSON: String = ScriptedLLMClient.defaultSummaryJSON,
        mergeJSON: String = #"{"details": [], "other_sections": []}"#,
        notesActionsJSON: String = #"{"action_items": []}"#,
        summaryMarkdown: String = ScriptedLLMClient.defaultSummaryMarkdown,
        factsJSON: String = ScriptedLLMClient.defaultFactsJSON,
        failing: Set<Kind> = [],
        hook: ChatHook? = nil,
        condenseReturnsInput: Bool = false
    ) {
        self.summaryJSON = summaryJSON
        self.summaryMarkdown = summaryMarkdown
        self.factsJSON = factsJSON
        self.mergeJSON = mergeJSON
        self.notesActionsJSON = notesActionsJSON
        self.failing = failing
        self.hook = hook
        self.condenseReturnsInput = condenseReturnsInput
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        let system = messages.first(where: { $0.role == "system" })?.content ?? ""
        let user = messages.last(where: { $0.role == "user" })?.content ?? ""
        let kind = Self.classify(system: system, user: user, format: format)
        calls.append(Call(kind: kind, system: system, user: user))
        if let hook {
            // Simulates the user (or sync) changing the meeting while this LLM call runs.
            await hook.fire(kind)
        }
        if failing.contains(kind) {
            throw LLMError.httpError(statusCode: 400, message: "scripted \(kind.rawValue) failure")
        }
        switch kind {
        case .refine:
            return user
        case .summarize:
            return format == .json ? summaryJSON : summaryMarkdown
        case .facts:
            return factsJSON
        case .map:
            // Echo the last line of the part so tests can check coverage.
            let last = user.split(separator: "\n").last.map(String.init) ?? ""
            return "- " + last
        case .condense:
            return condenseReturnsInput ? user : "- " + String(user.suffix(80))
        case .merge:
            return mergeJSON
        case .notesActions:
            return notesActionsJSON
        case .destinations:
            return "[]"
        case .verify:
            return #"{"items": []}"#
        case .other:
            return ""
        }
    }

    func listModels() async throws -> [String] { ["mock"] }

    func calls(_ kind: Kind) -> [Call] {
        calls.filter { $0.kind == kind }
    }

    static func classify(system: String, user: String, format: LLMResponseFormat?) -> Kind {
        if system.hasPrefix("You are a transcript editor") { return .refine }
        if system.hasPrefix(SummaryPrompts.markdownSummaryMarker) { return .summarize }
        if system.hasPrefix(SummaryPrompts.factsMarker) { return .facts }
        if system.hasPrefix(ActionItemVerifier.marker) { return .verify }
        if system.contains("You are condensing part") { return .map }
        if system.hasPrefix("These are consecutive notes") { return .condense }
        if system.hasPrefix("You enhance the notes") { return .merge }
        if system.hasPrefix("You are analyzing meeting notes") { return .notesActions }
        if user.hasPrefix("For each action item below") { return .destinations }
        if case .json = format { return .summarize }
        return .other
    }
}

/// Collects warnings reported through a `@MainActor` callback.
@MainActor
final class WarningSink {
    var messages: [String] = []
}

/// Runs main-actor code while a scripted LLM call is in flight, once per kind.
@MainActor
final class ChatHook {
    private var actions: [ScriptedLLMClient.Kind: () -> Void] = [:]

    func on(_ kind: ScriptedLLMClient.Kind, _ action: @escaping () -> Void) {
        actions[kind] = action
    }

    func fire(_ kind: ScriptedLLMClient.Kind) {
        actions.removeValue(forKey: kind)?()
    }
}

@MainActor
func makeInMemoryContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: config)
    return ModelContext(container)
}

/// Builds timed words for "Label: text" turns. `true` = mic (Me), `false` = system (Them).
func makeWords(_ turns: [(local: Bool?, text: String)]) -> [TranscriptWord] {
    var words: [TranscriptWord] = []
    var t: TimeInterval = 0
    for turn in turns {
        for w in turn.text.split(separator: " ") {
            words.append(TranscriptWord(word: String(w), start: t, end: t + 0.3, confidence: 0.9, speaker: nil, speakerName: nil, isLocalSpeaker: turn.local))
            t += 0.35
        }
    }
    return words
}
