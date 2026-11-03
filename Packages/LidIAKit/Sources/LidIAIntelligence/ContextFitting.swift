import Foundation

// Ported from Sources/LidIA/LLM/ContextFitting.swift (macOS). Keep the two in step.

// MARK: - TokenEstimate

public enum TokenEstimate {
    /// Conservative estimate when no tokenizer is available: ~3 characters
    /// per token covers English and Spanish with margin.
    public static func estimate(_ text: String) -> Int {
        max(1, (text.count + 2) / 3)
    }
}

// MARK: - TextChunker

/// Splits long text into pieces no longer than `maxCharacters`, preferring
/// paragraph, then line, then sentence, then word boundaries.
public enum TextChunker {
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(1, maxCharacters)
        guard text.count > limit else { return text.isEmpty ? [] : [text] }

        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }

        for piece in split(text, limit: limit, separators: ["\n\n", "\n", ". ", " "][...]) {
            if current.count + piece.count > limit {
                flush()
            }
            current += piece
        }
        flush()
        return result
    }

    private static func split(_ text: String, limit: Int, separators: ArraySlice<String>) -> [String] {
        guard text.count > limit else { return [text] }
        guard let separator = separators.first else {
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

/// Makes a long text fit a small context window with map-reduce: split it
/// into chunks, condense each chunk into dense notes, and repeat until it
/// fits. Apple's on-device model has a 4,096-token window on 26.0–26.3, so a
/// 30-minute meeting never fits whole; sending it anyway ends in
/// "context length exceeded" (the Mac hit exactly that before this existed).
public struct ContextFitter: Sendable {
    /// Total context window in tokens.
    public let contextTokens: Int
    /// Counts tokens for a string (exact where the model offers it).
    public let countTokens: @Sendable (String) async throws -> Int
    /// Condenses one chunk into notes. Arguments: chunk, index, total chunks.
    public let condense: @Sendable (String, Int, Int) async throws -> String

    /// Tokens reserved for the condense instructions in each map call.
    public static let condenseInstructionTokens = 200
    public static let maxRounds = 4
    /// Most map calls in one round; above this each chunk is cut instead.
    /// Mirrors `PipelineLimits.maxMapParts` on the Mac.
    public static let maxMapParts = 24

    public static let condenseInstructions = """
        You condense one part of a longer meeting record into dense notes. \
        Keep every person's name, decision, number, date, commitment and action item \
        with its owner, in the order they appear. Do not add anything that is not in the text. \
        Write plain sentences or short bullet lines. No preamble.
        """

    public init(
        contextTokens: Int,
        countTokens: @escaping @Sendable (String) async throws -> Int,
        condense: @escaping @Sendable (String, Int, Int) async throws -> String
    ) {
        self.contextTokens = contextTokens
        self.countTokens = countTokens
        self.condense = condense
    }

    /// Condenses `text` until it is at most `targetTokens` long. Returns the
    /// text and how many map calls it took (0 when it already fit).
    public func condenseToFit(_ text: String, targetTokens: Int) async throws -> (text: String, parts: Int) {
        var current = text
        var parts = 0
        for _ in 0..<Self.maxRounds {
            let tokens = try await countTokens(current)
            if tokens <= targetTokens { return (current, parts) }

            // Each map call must fit: chunk + instructions + the notes it writes.
            let chunkTokens = max(256, (contextTokens - Self.condenseInstructionTokens) * 2 / 3)
            let charsPerToken = max(1.0, Double(current.count) / Double(max(tokens, 1)))
            var maxChars = Int(Double(chunkTokens) * charsPerToken * 0.9)
            var chunks = TextChunker.chunks(current, maxCharacters: maxChars)
            if chunks.count > Self.maxMapParts {
                // Too many calls: make each part cover more by trimming it.
                maxChars = max(maxChars, current.count / Self.maxMapParts + 1)
                chunks = TextChunker.chunks(current, maxCharacters: maxChars).map {
                    String($0.prefix(Int(Double(chunkTokens) * charsPerToken * 0.9)))
                }
            }
            guard !chunks.isEmpty else { return (current, parts) }

            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                notes.append(try await condense(chunk, index, chunks.count))
                parts += 1
            }
            let next = notes.joined(separator: "\n\n")
            if next.count >= current.count { break }
            current = next
        }

        // Last resort: keep the start, which the model still sees in order.
        let tokens = try await countTokens(current)
        guard tokens > targetTokens else { return (current, parts) }
        let ratio = Double(targetTokens) / Double(tokens)
        let keep = max(0, Int(Double(current.count) * ratio * 0.95))
        return (String(current.prefix(keep)), parts)
    }
}
