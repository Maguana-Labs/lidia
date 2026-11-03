import Foundation
import SwiftData

/// What the voice pipeline hears back from the agent during one spoken turn.
enum VoiceAgentEvent: Sendable, Equatable {
    case text(String)
    /// Drop unspoken text: it preceded a tool call.
    case reset
    /// The turn's final answer, and a note of what changed (for logs).
    case finished(answer: String, note: String?)
}

/// The voice assistant's brain: the agent harness with LidIA's tools, plus a
/// spoken confirmation step. Changes the model prepares wait until the user
/// says "yes" on the next turn; anything else drops them.
@MainActor
final class VoiceAgent {
    private let endpoint: AgentHarness.Endpoint
    private let settings: AppSettings
    private let modelContext: ModelContext?
    private var pending: [AgentPendingAction] = []
    /// The last run's transcript ("View what was sent" for voice).
    private(set) var lastTranscript: AgentTranscript?

    init(endpoint: AgentHarness.Endpoint, settings: AppSettings, modelContext: ModelContext?) {
        self.endpoint = endpoint
        self.settings = settings
        self.modelContext = modelContext
    }

    /// One spoken turn. The stream is consumed off the main actor by the pipeline.
    nonisolated func respond(to transcript: String, history: [LLMChatMessage]) -> AsyncStream<VoiceAgentEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await self.run(transcript: transcript, history: history, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(transcript: String, history: [LLMChatMessage], continuation: AsyncStream<VoiceAgentEvent>.Continuation) async {
        guard let modelContext else {
            continuation.yield(.finished(answer: "I'm not ready yet. Try again in a moment.", note: nil))
            return
        }
        let destinations = AgentEndpoints.destinations(settings: settings)
        let tools = LidIATools.all(destinations: destinations)
        let context = AgentToolContext(modelContext: modelContext, settings: settings, destinations: destinations)

        // A pending change and a spoken yes: run it, without asking the model.
        if !pending.isEmpty {
            let waiting = pending
            pending = []
            switch Self.reply(to: transcript) {
            case .yes:
                var done: [String] = []
                for action in waiting {
                    let result = await AgentHarness.confirm(action, tools: tools, context: context)
                    done.append(result.state == .confirmed ? (result.resultMessage ?? action.summary) : "Failed: \(action.summary)")
                }
                let spanish = Self.isSpanish(transcript)
                let answer = waiting.count == 1 ? (spanish ? "Hecho." : "Done.") : (spanish ? "Hecho, \(waiting.count) cambios." : "Done, \(waiting.count) changes.")
                continuation.yield(.text(answer))
                continuation.yield(.finished(answer: answer, note: done.joined(separator: "; ")))
                return
            case .no:
                let answer = Self.isSpanish(transcript) ? "Vale, no lo hago." : "Okay, I won't."
                continuation.yield(.text(answer))
                continuation.yield(.finished(answer: answer, note: "Dismissed: " + waiting.map(\.summary).joined(separator: "; ")))
                return
            case .other:
                break // A new request: the old change is dropped.
            }
        }

        let configuration = AgentHarness.Configuration.standard(for: endpoint.family, locality: endpoint.locality)
        let harness = AgentHarness(endpoint: endpoint, tools: tools, configuration: configuration)
        let prompt = AgentPromptContext(
            task: .voice, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps,
            userName: settings.displayName,
            userInstructions: AgentEndpoints.userInstructions(settings: settings)
        )
        let agentHistory = history.suffix(6).compactMap { message -> AgentMessage? in
            switch message.role {
            case "user": .user(VoiceToolExecutor.stripToolMarkers(message.content))
            case "assistant": .assistant(VoiceToolExecutor.stripToolMarkers(message.content))
            default: nil
            }
        }
        let result = await harness.run(prompt: prompt, history: agentHistory, userMessage: transcript, context: context) { event in
            switch event {
            case .text(let text): continuation.yield(.text(text))
            case .resetText: continuation.yield(.reset)
            case .status, .reasoning: break
            }
        }
        lastTranscript = result.transcript
        pending = result.pendingActions
        let note = result.pendingActions.isEmpty ? nil : "Waiting for a spoken yes: " + result.pendingActions.map(\.summary).joined(separator: "; ")
        continuation.yield(.finished(answer: result.answer, note: note))
    }

    enum Reply: Equatable { case yes, no, other }

    /// Whether a short utterance confirms or refuses. Pure, for tests.
    static func reply(to utterance: String) -> Reply {
        let words = AttendeeParser.fold(utterance).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 6 else { return .other }
        let yes: Set<String> = ["yes", "yeah", "yep", "sure", "confirm", "confirmed", "ok", "okay", "si", "claro", "vale", "dale", "hazlo", "correct", "please"]
        let no: Set<String> = ["no", "nope", "cancel", "dont", "stop", "nah", "cancela"]
        if words.contains(where: no.contains) { return .no }
        if words.contains(where: yes.contains) || words.joined(separator: " ").contains("do it") { return .yes }
        return .other
    }

    private static func isSpanish(_ text: String) -> Bool {
        let words = Set(AttendeeParser.fold(text).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["si", "vale", "claro", "dale", "hazlo", "cancela", "no lo"])
    }
}
