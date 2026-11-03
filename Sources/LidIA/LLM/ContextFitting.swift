import Foundation

// MARK: - TextChunker

/// Splits long text into pieces no longer than `maxCharacters`, preferring
/// paragraph, then line, then sentence, then word boundaries.
enum TextChunker {
    static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(1, maxCharacters)
        guard text.count > limit else { return text.isEmpty ? [] : [text] }

        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }

        for piece in splitPreservingBoundaries(text, limit: limit) {
            if current.count + piece.count > limit {
                flush()
            }
            current += piece
        }
        flush()
        return result
    }

    /// Breaks text into units that each fit within `limit`, keeping their
    /// trailing separators so joining them reproduces the text.
    private static func splitPreservingBoundaries(_ text: String, limit: Int) -> [String] {
        let separators = ["\n\n", "\n", ". ", " "]
        return split(text, limit: limit, separators: separators[...])
    }

    private static func split(_ text: String, limit: Int, separators: ArraySlice<String>) -> [String] {
        guard text.count > limit else { return [text] }
        guard let separator = separators.first else {
            // No boundary left: hard split.
            var pieces: [String] = []
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
                pieces.append(String(text[index..<end]))
                index = end
            }
            return pieces
        }
        let parts = text.components(separatedBy: separator)
        var pieces: [String] = []
        for (offset, part) in parts.enumerated() {
            let unit = offset < parts.count - 1 ? part + separator : part
            if unit.count > limit {
                pieces += split(unit, limit: limit, separators: separators.dropFirst())
            } else if !unit.isEmpty {
                pieces.append(unit)
            }
        }
        return pieces
    }
}

// MARK: - ContextFitter

/// Makes a request fit a model's context window by condensing the longest
/// message with map-reduce: split it into chunks, condense each chunk into
/// dense notes, and repeat until it fits. Used by on-device clients whose
/// context is small (Apple Intelligence: 4K tokens on macOS 26.0–26.3) or
/// capped by LidIA policy (MLX tiers).
struct ContextFitter: Sendable {
    /// Total context window in tokens.
    let contextTokens: Int
    /// Tokens kept free for the model's answer.
    let reservedOutputTokens: Int
    /// Counts tokens for a string (exact where the model offers it).
    let countTokens: @Sendable (String) async throws -> Int
    /// Condenses one chunk into notes. Arguments: chunk, index, total chunks.
    let condense: @Sendable (String, Int, Int) async throws -> String

    /// Per-message framing overhead (role markers, template tokens).
    static let perMessageOverhead = 8
    /// Tokens reserved for the condense instructions in each map call.
    static let condenseInstructionTokens = 200
    static let maxRounds = 4

    /// Instructions for the condense (map) step.
    static let condenseInstructions = """
        You condense one part of a longer meeting record into dense notes. \
        Keep every person's name, decision, number, date, commitment and action item \
        with its owner, in the order they appear. Do not add anything that is not in the text. \
        Write plain sentences or short bullet lines. No preamble.
        """

    func fit(_ messages: [LLMChatMessage]) async throws -> [LLMChatMessage] {
        let budget = contextTokens - reservedOutputTokens
        var counts: [Int] = []
        for message in messages {
            counts.append(try await countTokens(message.content) + Self.perMessageOverhead)
        }
        let total = counts.reduce(0, +)
        guard total > budget else { return messages }

        guard let longest = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return messages }
        let others = total - counts[longest]
        let allowance = budget - others - Self.perMessageOverhead
        guard allowance >= 128 else {
            throw LLMError.contextLengthExceeded
        }

        var fitted = messages
        let condensed = try await condenseToFit(messages[longest].content, targetTokens: allowance)
        fitted[longest] = LLMChatMessage(role: messages[longest].role, content: condensed)
        return fitted
    }

    /// Condenses `text` until it is at most `targetTokens` long.
    func condenseToFit(_ text: String, targetTokens: Int) async throws -> String {
        var current = text
        for _ in 0..<Self.maxRounds {
            let tokens = try await countTokens(current)
            if tokens <= targetTokens { return current }

            // Each map call must fit: chunk + instructions + the notes it writes.
            let chunkTokens = max(256, (contextTokens - Self.condenseInstructionTokens) * 2 / 3)
            let charsPerToken = max(1.0, Double(current.count) / Double(max(tokens, 1)))
            let maxChars = Int(Double(chunkTokens) * charsPerToken * 0.9)
            let chunks = TextChunker.chunks(current, maxCharacters: maxChars)
            guard chunks.count > 0 else { return current }

            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                notes.append(try await condense(chunk, index, chunks.count))
            }
            let next = notes.joined(separator: "\n\n")
            // Stop if condensing no longer shrinks the text.
            if next.count >= current.count { break }
            current = next
        }

        // Last resort: keep the start, which the model still sees in order.
        let tokens = try await countTokens(current)
        guard tokens > targetTokens else { return current }
        let ratio = Double(targetTokens) / Double(tokens)
        let keep = max(0, Int(Double(current.count) * ratio * 0.95))
        return String(current.prefix(keep))
    }
}

// MARK: - Token estimate

enum TokenEstimate {
    /// Conservative estimate when no tokenizer is available: ~3 characters
    /// per token covers English and Spanish with margin.
    static func estimate(_ text: String) -> Int {
        max(1, (text.count + 2) / 3)
    }
}
