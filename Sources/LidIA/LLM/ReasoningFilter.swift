import Foundation

/// Removes model reasoning ("thinking") from output, both whole and while
/// streaming, so users only see the answer.
///
/// Handles:
/// - `<think> … </think>` (Qwen 3 / 3.5).
/// - `<|channel>thought … <channel|>` (Gemma 4 thinking channel). Gemma 4
///   E2B/E4B emit no block when thinking is off.
/// - Legacy Qwen 3 thinking models whose chat template opens `<think>` in the
///   prompt, so the output contains only the closing tag.
struct ReasoningFilter {
    struct Block: Sendable {
        let open: String
        let close: String
    }

    static let blocks: [Block] = [
        Block(open: "<think>", close: "</think>"),
        Block(open: "<|channel>thought", close: "<channel|>"),
    ]

    private enum State {
        /// Haven't seen enough output to know whether it starts with reasoning.
        case undecided
        /// Inside a reasoning block; drop text until `close`.
        case inBlock(close: String, implicit: Bool)
        /// Emitting answer text.
        case passthrough
    }

    private var state: State
    private var buffer = ""

    /// - Parameter expectsImplicitThinking: true for models that start
    ///   thinking without an opening tag (legacy Qwen 3 thinking models).
    init(expectsImplicitThinking: Bool = false) {
        state = expectsImplicitThinking ? .inBlock(close: "</think>", implicit: true) : .undecided
    }

    init(family: ModelFamily?) {
        self.init(expectsImplicitThinking: family == .qwen3)
    }

    /// Feeds a chunk; returns the answer text that is safe to show now.
    mutating func consume(_ chunk: String) -> String {
        buffer += chunk
        var output = ""
        while true {
            switch state {
            case .passthrough:
                output += buffer
                buffer = ""
                return output

            case .undecided:
                let trimmed = String(buffer.drop(while: \.isWhitespace))
                if let block = Self.blocks.first(where: { trimmed.hasPrefix($0.open) }) {
                    buffer = String(trimmed.dropFirst(block.open.count))
                    state = .inBlock(close: block.close, implicit: false)
                    continue
                }
                if trimmed.isEmpty || Self.blocks.contains(where: { $0.open.hasPrefix(trimmed) }) {
                    // Could still become an opening tag; wait for more.
                    return output
                }
                state = .passthrough
                continue

            case .inBlock(let close, _):
                guard let range = buffer.range(of: close) else { return output }
                buffer = String(buffer[range.upperBound...].drop(while: \.isWhitespace))
                state = .undecided
                continue
            }
        }
    }

    /// Flushes anything held back at the end of generation.
    mutating func finish() -> String {
        defer { buffer = "" }
        switch state {
        case .passthrough:
            return buffer
        case .undecided:
            return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case .inBlock(_, let implicit):
            // An explicit block that never closed is all reasoning. For
            // implicit thinking the model may simply not think, so keep the
            // text but drop a leading plain-text "thinking" preamble.
            return implicit ? Self.stripPlainThinking(buffer) : ""
        }
    }

    /// Strips reasoning from a complete response.
    static func strip(_ text: String, family: ModelFamily? = nil) -> String {
        var filter = ReasoningFilter(family: family)
        let body = filter.consume(text) + filter.finish()
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Some models narrate reasoning without tags ("Thinking Process: …")
    /// before a JSON answer; keep the JSON.
    static func stripPlainThinking(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Thinking Process") || trimmed.hasPrefix("**Thinking"),
           let jsonStart = trimmed.firstIndex(of: "{") {
            return String(trimmed[jsonStart...])
        }
        return trimmed
    }
}
