import Foundation

/// A language model the notes pipeline and Ask can use: Apple's on-device
/// model by default, or a cloud model with the user's own key.
public protocol TextGenerator: Sendable {
    /// Shown in the UI ("Apple Intelligence", "Claude Sonnet").
    var displayName: String { get }
    /// True when the text never leaves the device.
    var isOnDevice: Bool { get }
    /// Context window in tokens.
    var contextTokens: Int { get }

    func countTokens(_ text: String) async throws -> Int

    /// One complete answer.
    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String

    /// Streams the answer as deltas (new text only).
    func stream(instructions: String, prompt: String, maxTokens: Int, temperature: Double) -> AsyncThrowingStream<String, Error>

    /// Title, decisions and action items from finished notes.
    func extractFacts(notes: String) async throws -> MeetingFacts
}

/// The structured result of the facts step.
public struct MeetingFacts: Sendable, Hashable {
    public var title: String
    public var decisions: [String]
    public var actionItems: [ExtractedActionItem]

    public init(title: String, decisions: [String], actionItems: [ExtractedActionItem]) {
        self.title = title
        self.decisions = decisions
        self.actionItems = actionItems
    }
}

public enum GeneratorError: LocalizedError, Equatable {
    case unavailable(String)
    case contextLengthExceeded
    case declined
    case badResponse(String)
    case timedOut(step: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .contextLengthExceeded: "The meeting is too long for the model's context, even after condensing."
        case .declined: "The model declined to process this content. Try another model in Settings."
        case .badResponse(let detail): "The model returned something unexpected: \(detail)"
        case .timedOut(let step): "The \(step) took too long and was stopped. Your transcript is saved; try again."
        }
    }
}

public extension TextGenerator {
    /// JSON-prompt facts, for models without guided generation.
    func extractFacts(notes: String) async throws -> MeetingFacts {
        let raw = try await respond(
            instructions: MeetingPrompts.factsSystemPrompt,
            prompt: notes,
            maxTokens: 600,
            temperature: 0.2
        )
        return try MeetingFactsDecoder.decode(raw)
    }
}

/// Decodes the facts JSON (`MeetingPrompts.factsSystemPrompt`), tolerating fences.
public enum MeetingFactsDecoder {
    private struct Payload: Decodable {
        struct Item: Decodable {
            var title: String
            var assignee: String?
            var deadline: String?
        }
        var title: String?
        var decisions: [String]?
        var action_items: [Item]?
    }

    public static func decode(_ raw: String) throws -> MeetingFacts {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw GeneratorError.badResponse("facts were not valid JSON")
        }
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        }
        return MeetingFacts(
            title: payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            decisions: payload.decisions ?? [],
            actionItems: (payload.action_items ?? []).compactMap { item in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return ExtractedActionItem(title: title, assignee: clean(item.assignee), deadline: clean(item.deadline))
            }
        )
    }
}

/// Turns cumulative stream snapshots into deltas in O(new text). Ported from the Mac.
public struct StreamSnapshotDelta: Sendable {
    private var sentUTF8 = 0

    public init() {}

    public mutating func next(_ snapshot: String) -> String {
        let utf8 = snapshot.utf8
        let count = utf8.count
        guard count >= sentUTF8 else {
            sentUTF8 = count
            return snapshot
        }
        guard count > sentUTF8 else { return "" }
        let start = utf8.index(utf8.startIndex, offsetBy: sentUTF8)
        sentUTF8 = count
        return String(decoding: utf8[start...], as: UTF8.self)
    }
}
