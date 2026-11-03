import Foundation
import os

// MARK: - Chat Types

struct FileAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let content: String

    init(id: UUID = UUID(), name: String, content: String) {
        self.id = id
        self.name = name
        self.content = content
    }
}

struct ChatBarMessage: Identifiable, Codable, Sendable, Equatable {
    enum GroundingConfidence: String, Codable, Sendable {
        case low
        case medium
        case high

        var displayLabel: String {
            switch self {
            case .low: return "Low confidence"
            case .medium: return "Medium confidence"
            case .high: return "High confidence"
            }
        }
    }

    let id: UUID
    let role: Role
    var text: String
    let attachments: [FileAttachment]
    let sourceMeetings: [String]
    let groundingConfidence: GroundingConfidence?
    let modelLabel: String?
    /// What the agent sent for this answer ("View what was sent"). Kept for
    /// this session only; not persisted with the thread.
    var agentTranscript: AgentTranscript?
    /// Changes the agent prepared that wait for the user's confirmation.
    var pendingActions: [AgentPendingAction] = []
    /// The live run behind this answer (steps, reasoning, sources, follow-ups,
    /// approvals). This session only.
    var agentRun: AgentRun?

    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        attachments: [FileAttachment] = [],
        sourceMeetings: [String] = [],
        groundingConfidence: GroundingConfidence? = nil,
        modelLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.sourceMeetings = sourceMeetings
        self.modelLabel = modelLabel
        self.groundingConfidence = groundingConfidence
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, attachments, sourceMeetings, groundingConfidence, modelLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .assistant
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try container.decodeIfPresent([FileAttachment].self, forKey: .attachments) ?? []
        sourceMeetings = try container.decodeIfPresent([String].self, forKey: .sourceMeetings) ?? []
        groundingConfidence = try container.decodeIfPresent(GroundingConfidence.self, forKey: .groundingConfidence)
        modelLabel = try container.decodeIfPresent(String.self, forKey: .modelLabel)
    }
}

// MARK: - System Prompt

/// The chat's system prompt. LidIA is a general assistant first: it answers
/// small talk and general questions from its own knowledge, and grounds
/// answers about the user's meetings in `context`.
enum LidIAChatPrompt {
    static func system(context: String, personalization: String = "", date: Date = Date()) -> String {
        let dateString = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextSection = trimmedContext.isEmpty
            ? "No meeting context matched this message."
            : trimmedContext
        return """
            You are LidIA, the user's assistant inside a meeting notes app. Today is \(dateString).
            \(personalization)
            You can talk about anything. Greetings, general questions, writing help and brainstorming get a normal, friendly answer from your own knowledge.
            When the user asks about their meetings, people, decisions or action items, answer from the meeting context below and name the meetings you used. If the context doesn't cover it, say so in one sentence and never invent meeting details.
            When the user asks about "my" action items, match items assigned to the user (their name in the assignee field, or items without an assignee from meetings they attended).

            Meeting context:
            \(contextSection)

            Response style:
            - Be concise. 1-3 sentences for simple requests. No filler, no preamble.
            - For action requests (create, complete, edit, delete), confirm briefly and stop.
            - Never use emojis. Never output XML tags or JSON tool calls.
            """
    }
}

// MARK: - ChatStream Protocol

@MainActor
protocol ChatStream: AnyObject {
    func send(
        _ message: String,
        history: [LLMChatMessage],
        context: String,
        attachments: [FileAttachment],
        model: String
    ) -> AsyncStream<String>

    func reset()
}

// MARK: - HTTPChatStream

@MainActor
final class HTTPChatStream: ChatStream {
    private let settings: AppSettings
    private let modelManager: ModelManager?

    init(settings: AppSettings, modelManager: ModelManager? = nil) {
        self.settings = settings
        self.modelManager = modelManager
    }

    func send(
        _ message: String,
        history: [LLMChatMessage],
        context: String,
        attachments: [FileAttachment],
        model: String
    ) -> AsyncStream<String> {
        // Build messages array
        var messages: [LLMChatMessage] = []

        let personalization = VoiceToolExecutor.personalizationPrompt(settings: settings)
        let systemPrompt = LidIAChatPrompt.system(context: context, personalization: personalization)
        messages.append(LLMChatMessage(role: "system", content: systemPrompt))

        // Prepend file attachment content as user messages
        for attachment in attachments {
            messages.append(LLMChatMessage(
                role: "user",
                content: "File: \(attachment.name)\n\n\(attachment.content)"
            ))
        }

        // Append conversation history
        messages.append(contentsOf: history)

        // Append the new user message
        messages.append(LLMChatMessage(role: "user", content: message))

        let capturedMessages = messages
        let capturedSettings = settings
        let capturedModelManager = modelManager

        return AsyncStream { continuation in
            Task { @MainActor in
                let primaryClient = makeLLMClient(settings: capturedSettings, modelManager: capturedModelManager, taskType: .ask)
                do {
                    for try await token in await primaryClient.chatStream(messages: capturedMessages, model: model) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                    return
                } catch {
                    // Attempt fallback if configured
                    guard let fallbackProviderEnum = AppSettings.LLMProvider(storedValue: capturedSettings.fallbackProvider),
                          fallbackProviderEnum != capturedSettings.llmProvider else {
                        continuation.yield("[Error: \(error.localizedDescription)]")
                        continuation.finish()
                        return
                    }
                    // Never move a local chat to the cloud without permission.
                    if case .block(let blockError) = fallbackDecision(
                        from: capturedSettings.llmProvider,
                        to: fallbackProviderEnum,
                        settings: capturedSettings
                    ) {
                        let shown = blockError?.localizedDescription ?? error.localizedDescription
                        continuation.yield("[Error: \(shown)]")
                        continuation.finish()
                        return
                    }
                    guard let fallbackClient = makeGatedClient(for: fallbackProviderEnum, settings: capturedSettings, modelManager: capturedModelManager) else {
                        continuation.yield("[Error: \(error.localizedDescription)]")
                        continuation.finish()
                        return
                    }

                    let fallbackModel = capturedSettings.fallbackModel.isEmpty
                        ? defaultModelForProvider(fallbackProviderEnum, settings: capturedSettings)
                        : capturedSettings.fallbackModel

                    fallbackLogger.info("Chat stream falling back to \(fallbackProviderEnum.rawValue)")

                    do {
                        for try await token in await fallbackClient.chatStream(messages: capturedMessages, model: fallbackModel) {
                            continuation.yield(token)
                        }
                    } catch let fallbackError {
                        continuation.yield("[Error: \(fallbackError.localizedDescription)]")
                    }
                    continuation.finish()
                }
            }
        }
    }

    func reset() {
        // No persistent state to clear in the HTTP implementation
    }
}
