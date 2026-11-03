import Foundation
import FoundationModels
import os

// MARK: - Guided-generation types

/// Typed meeting summary for Apple's on-device model. Guided generation
/// guarantees this shape, so summaries never fail on malformed JSON.
@Generable
struct AppleFMSummary {
    @Guide(description: "A short, specific meeting title taken from the content")
    var title: String

    @Guide(description: "A plain-text overview of the meeting in one to four sentences")
    var summary: String

    @Guide(description: "Topic sections. Use the section headings the instructions ask for; leave out sections with nothing to say.")
    var sections: [AppleFMSection]

    @Guide(description: "Decisions that were explicitly made. Empty when none were made.")
    var decisions: [String]

    @Guide(description: "Tasks someone explicitly committed to. Empty when nobody committed to anything.")
    var actionItems: [AppleFMActionItem]
}

@Generable
struct AppleFMSection {
    @Guide(description: "Section heading")
    var heading: String

    @Guide(description: "Short factual bullet points from the transcript")
    var bullets: [String]
}

@Generable
struct AppleFMActionItem {
    @Guide(description: "The task, starting with a verb")
    var title: String

    @Guide(description: "Name of the person who committed to it, exactly as in the transcript, or an empty string")
    var assignee: String

    @Guide(description: "Deadline as stated in the transcript, or an empty string")
    var deadline: String

    @Guide(description: "The words from the transcript where the commitment was made, or an empty string")
    var sourceQuote: String
}

/// Typed result of the pipeline's facts step (`SummaryPrompts.factsSystemPrompt`).
@Generable
struct AppleFMMeetingFacts {
    @Guide(description: "A specific meeting title of at most 8 words naming the main topic")
    var title: String

    @Guide(description: "Things that were explicitly decided. Empty when none.")
    var decisions: [String]

    @Guide(description: "Tasks someone committed to or was asked to do. Empty when none.")
    var actionItems: [AppleFMActionItem]

    func json() throws -> String {
        func nonEmpty(_ value: String) -> Any {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? NSNull() : trimmed
        }
        let object: [String: Any] = [
            "title": title,
            "decisions": decisions,
            "action_items": actionItems.map {
                ["title": $0.title, "assignee": nonEmpty($0.assignee), "deadline": nonEmpty($0.deadline)] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension AppleFMSummary {
    /// JSON in the shape `MeetingSummaryResponse` decodes.
    func meetingSummaryJSON() throws -> String {
        func nonEmpty(_ value: String) -> Any {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? NSNull() : trimmed
        }
        let object: [String: Any] = [
            "title": title,
            "summary": summary,
            "summary_sections": sections.map { section in
                [
                    "heading": section.heading,
                    "bullets": section.bullets.map { ["text": $0] },
                ] as [String: Any]
            },
            "decisions": decisions,
            "actionItems": actionItems.map { item in
                [
                    "title": item.title,
                    "assignee": nonEmpty(item.assignee),
                    "deadline": nonEmpty(item.deadline),
                    "source_quote": nonEmpty(item.sourceQuote),
                ] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - AppleFoundationClient

/// `LLMClient` over Apple's on-device foundation model (`SystemLanguageModel`).
///
/// Zero download, works as soon as Apple Intelligence is on. Its context is
/// small (4,096 tokens on macOS 26.0–26.3; read at runtime on 26.4+), so
/// requests that don't fit are condensed with map-reduce first
/// (`ContextFitter`). Meeting summaries use guided generation
/// (`AppleFMSummary`) so the JSON is always valid.
struct AppleFoundationClient: LLMClient {
    static let modelID = "apple-on-device"
    static let displayName = "Apple Intelligence (on-device)"

    private static let logger = Logger(subsystem: "io.lidia.app", category: "AppleFoundationClient")

    // MARK: Availability

    enum Availability: Equatable, Sendable {
        case available
        case appleIntelligenceOff
        case deviceNotEligible
        case modelNotReady
        case unsupportedLanguage
        case unavailable

        var userMessage: String {
            switch self {
            case .available:
                return "Apple Intelligence is ready."
            case .appleIntelligenceOff:
                return "Turn on Apple Intelligence in System Settings to use on-device summaries without a download."
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence. Download an on-device model instead."
            case .modelNotReady:
                return "Apple Intelligence is still getting ready. Try again in a few minutes."
            case .unsupportedLanguage:
                return "Apple Intelligence doesn't support your system language yet. Download an on-device model instead."
            case .unavailable:
                return "Apple Intelligence isn't available."
            }
        }
    }

    static var availability: Availability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unavailable
            }
        }
    }

    /// Context window in tokens: read from the system on 26.4+, else 4,096.
    static var contextSize: Int {
        if #available(macOS 26.4, iOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return 4096
    }

    static func countTokens(_ text: String) async throws -> Int {
        if #available(macOS 26.4, iOS 26.4, *) {
            return try await SystemLanguageModel.default.tokenCount(for: text)
        }
        return TokenEstimate.estimate(text)
    }

    // MARK: LLMClient

    func listModels() async throws -> [String] {
        let availability = Self.availability
        guard availability == .available else {
            throw LLMError.setupRequired(availability.userMessage)
        }
        return [Self.modelID]
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        try ensureAvailable()
        let isSummary = format == .json && Self.isMeetingSummaryRequest(messages)
        let isFacts = format == .json && messages.contains {
            $0.role == "system" && $0.content.hasPrefix(SummaryPrompts.factsMarker)
        }
        // Guided generation sends its schema inside the context too.
        let output = isSummary ? Self.summaryOutputTokens : Self.chatOutputTokens
        let fitted = try await fit(messages, reservedOutputTokens: output + (isSummary || isFacts ? Self.schemaTokens : 0))
        let (instructions, prompt) = Self.split(fitted)
        let session = LanguageModelSession(instructions: instructions)
        // Bounding the answer keeps prompt + answer inside the window (a runaway
        // answer used to end in "Context length exceeded" or never return).
        let options = GenerationOptions(
            temperature: format == .json ? Double(LLMTemperature.structured) : Double(LLMTemperature.chat),
            maximumResponseTokens: output
        )

        do {
            if isSummary {
                let response = try await session.respond(to: prompt, generating: AppleFMSummary.self, options: options)
                return try response.content.meetingSummaryJSON()
            }
            if isFacts {
                let response = try await session.respond(to: prompt, generating: AppleFMMeetingFacts.self, options: options)
                return try response.content.json()
            }
            var jsonPrompt = prompt
            if format == .json {
                jsonPrompt += "\n\nRespond ONLY with valid JSON. No markdown fences."
            }
            let response = try await session.respond(to: jsonPrompt, options: options)
            return format == .json ? Self.stripFences(response.content) : response.content
        } catch {
            throw Self.map(error)
        }
    }

    /// Answer budgets. Summaries need room; everything else is short.
    static let summaryOutputTokens = 1200
    static let chatOutputTokens = 700
    /// Allowance for a guided-generation schema in the context.
    static let schemaTokens = 400

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ensureAvailable()
                    // Streamed meeting summaries are longer and want low temperature.
                    let isSummary = messages.contains {
                        $0.role == "system" && $0.content.hasPrefix(SummaryPrompts.markdownSummaryMarker)
                    }
                    let output = isSummary ? Self.summaryOutputTokens : Self.chatOutputTokens
                    let fitted = try await fit(messages, reservedOutputTokens: output)
                    let (instructions, prompt) = Self.split(fitted)
                    let session = LanguageModelSession(instructions: instructions)
                    let stream = session.streamResponse(
                        to: prompt,
                        options: GenerationOptions(
                            temperature: Double(isSummary ? LLMTemperature.structured : LLMTemperature.chat),
                            maximumResponseTokens: output
                        )
                    )
                    var delta = StreamSnapshotDelta()
                    for try await snapshot in stream {
                        let text = delta.next(snapshot.content)
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    private func ensureAvailable() throws {
        let availability = Self.availability
        guard availability == .available else {
            throw LLMError.setupRequired(availability.userMessage)
        }
    }

    private func fit(_ messages: [LLMChatMessage], reservedOutputTokens: Int) async throws -> [LLMChatMessage] {
        let contextSize = Self.contextSize
        let fitter = ContextFitter(
            contextTokens: contextSize,
            reservedOutputTokens: reservedOutputTokens,
            countTokens: { try await Self.countTokens($0) },
            condense: { chunk, index, total in
                Self.logger.info("Condensing part \(index + 1, privacy: .public) of \(total, privacy: .public) to fit Apple Intelligence's context")
                let session = LanguageModelSession(instructions: ContextFitter.condenseInstructions)
                let options = GenerationOptions(
                    temperature: Double(LLMTemperature.structured),
                    maximumResponseTokens: max(256, contextSize / 4)
                )
                do {
                    return try await session.respond(to: chunk, options: options).content
                } catch {
                    throw Self.map(error)
                }
            }
        )
        return try await fitter.fit(messages)
    }

    /// System messages become the session instructions; the rest become one
    /// prompt (earlier turns are included as a short transcript).
    static func split(_ messages: [LLMChatMessage]) -> (instructions: String, prompt: String) {
        let instructions = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        let turns = messages.filter { $0.role != "system" }
        guard let last = turns.last else { return (instructions, "") }
        let earlier = turns.dropLast()
        if earlier.isEmpty { return (instructions, last.content) }
        let history = earlier.map { message -> String in
            let speaker = message.role == "assistant" ? "Assistant" : "User"
            return "\(speaker): \(message.content)"
        }.joined(separator: "\n")
        return (instructions, "Conversation so far:\n\(history)\n\nUser: \(last.content)")
    }

    /// The meeting-summary prompts (MeetingTemplate) ask for this JSON shape.
    static func isMeetingSummaryRequest(_ messages: [LLMChatMessage]) -> Bool {
        messages.contains { $0.role == "system" && $0.content.contains("actionItems") && $0.content.contains("decisions") }
    }

    static func stripFences(_ text: String) -> String {
        var content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```json") {
            content = String(content.dropFirst(7))
        } else if content.hasPrefix("```") {
            content = String(content.dropFirst(3))
        }
        if content.hasSuffix("```") { content = String(content.dropLast(3)) }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func map(_ error: Error) -> Error {
        if error is LLMError || error is CancellationError { return error }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return LLMError.contextLengthExceeded
            case .guardrailViolation, .refusal:
                return LLMError.invalidResponse("Apple Intelligence declined to process this content. Try an on-device model download or another provider.")
            case .unsupportedLanguageOrLocale:
                return LLMError.setupRequired(Availability.unsupportedLanguage.userMessage)
            case .assetsUnavailable:
                return LLMError.setupRequired(Availability.modelNotReady.userMessage)
            default:
                return LLMError.invalidResponse("Apple Intelligence error: \(generationError.localizedDescription)")
            }
        }
        return error
    }
}

// MARK: - Streaming deltas

/// Turns Apple's cumulative stream snapshots into deltas in O(new text).
///
/// Comparing whole snapshots (`hasPrefix` + `dropFirst(sent.count)`) is
/// O(length) per snapshot, so O(n²) per answer; on a long or runaway answer
/// that kept the app at 100% CPU. This works on UTF-8 offsets instead.
struct StreamSnapshotDelta {
    private var sentUTF8 = 0

    mutating func next(_ snapshot: String) -> String {
        let utf8 = snapshot.utf8
        let count = utf8.count
        guard count >= sentUTF8 else {
            // The model revised earlier text (not expected): resend it whole.
            sentUTF8 = count
            return snapshot
        }
        guard count > sentUTF8 else { return "" }
        let start = utf8.index(utf8.startIndex, offsetBy: sentUTF8)
        sentUTF8 = count
        return String(decoding: utf8[start...], as: UTF8.self)
    }
}
