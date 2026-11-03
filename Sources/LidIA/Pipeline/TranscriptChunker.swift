import Foundation

// MARK: - Token estimation

/// Cheap, provider-agnostic token estimate. Real tokenizers average ~4 characters
/// per token for English and somewhat fewer for Spanish; we take the larger of a
/// character-based and a word-based estimate so we err on the side of smaller chunks.
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let byChars = (text.count + 3) / 4
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        let byWords = Int((Double(words) * 1.35).rounded(.up))
        return max(byChars, byWords)
    }
}

// MARK: - Budget

/// How much transcript text fits in one LLM request for a given provider.
struct SummarizationBudget: Sendable, Equatable {
    /// Total context window the request is allowed to use.
    let contextTokens: Int
    /// Tokens held back for the system prompt (templates are long) and the JSON output.
    let reservedTokens: Int

    /// Transcript tokens that fit in one request.
    var inputTokens: Int { max(512, contextTokens - reservedTokens) }

    /// Apple's on-device model and other small/unknown local runtimes.
    static let conservative = SummarizationBudget(contextTokens: 4096, reservedTokens: 2560)
    /// Explicit `num_ctx` we send to Ollama for pipeline requests.
    static let ollama = SummarizationBudget(contextTokens: PipelineOllamaClient.defaultContextTokens, reservedTokens: 4096)
    /// Local MLX models (the MLX client generates up to 16k tokens; most models take 32k context).
    static let mlx = SummarizationBudget(contextTokens: 16384, reservedTokens: 4096)
    /// Hosted providers with large context windows. Capped so single requests stay fast.
    static let cloud = SummarizationBudget(contextTokens: 32768, reservedTokens: 4096)
    /// Hosted providers with small free-tier limits (e.g. Cerebras 8k).
    static let smallCloud = SummarizationBudget(contextTokens: 8192, reservedTokens: 3072)

    /// Infers a budget from the concrete client. Unknown clients (including Apple's
    /// on-device model and test mocks) get the conservative 4k budget.
    static func infer(for client: any LLMClient) -> SummarizationBudget {
        switch client {
        case is PipelineOllamaClient, is OllamaClient:
            return .ollama
        case is MLXLocalClient:
            return .mlx
        case is AnthropicClient, is CLIChatClient:
            return .cloud
        case let openAI as OpenAIClient:
            let host = openAI.baseURL.host?.lowercased() ?? ""
            if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
                return .conservative // LM Studio defaults to a 4k context
            }
            if host.contains("cerebras") {
                return .smallCloud
            }
            return .cloud
        default:
            return .conservative
        }
    }
}

// MARK: - Chunker

/// Splits a transcript into pieces that each fit a token budget.
///
/// Pure and deterministic. Splits on line (speaker-turn) boundaries first, then on
/// sentence boundaries, then on words. When a speaker turn has to be split, the
/// `Label:` prefix is repeated on every piece so the model never loses attribution.
enum TranscriptChunker {
    static func chunk(_ text: String, maxTokens: Int, overlapTokens: Int = 0) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let budget = max(16, maxTokens)
        if TokenEstimator.estimate(trimmed) <= budget { return [trimmed] }

        // 1. Break into units that individually fit the budget.
        var units: [String] = []
        for line in trimmed.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if TokenEstimator.estimate(line) <= budget {
                units.append(line)
            } else {
                units.append(contentsOf: splitLongLine(line, budget: budget))
            }
        }

        // 2. Greedily pack units into chunks, with optional trailing overlap.
        let overlap = max(0, min(overlapTokens, budget / 4))
        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0

        for unit in units {
            let unitTokens = TokenEstimator.estimate(unit) + 1
            if currentTokens + unitTokens > budget, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                // Carry the tail of the previous chunk as context.
                var carried: [String] = []
                var carriedTokens = 0
                if overlap > 0 {
                    for previous in current.reversed() {
                        let t = TokenEstimator.estimate(previous) + 1
                        if carriedTokens + t > overlap { break }
                        carried.insert(previous, at: 0)
                        carriedTokens += t
                    }
                }
                if carriedTokens + unitTokens > budget {
                    carried = []
                    carriedTokens = 0
                }
                current = carried
                currentTokens = carriedTokens
            }
            current.append(unit)
            currentTokens += unitTokens
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    /// Extracts a leading speaker label such as `Me:` or `**Sarah:**`.
    static func speakerLabel(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var label = String(line[..<colon])
        var after = line.index(after: colon)
        // Markdown bold labels: **Name:**
        if label.hasPrefix("**") {
            if line[after...].hasPrefix("**") {
                after = line.index(after, offsetBy: 2)
            }
            label = label.replacingOccurrences(of: "*", with: "")
        }
        let words = label.split(separator: " ")
        guard !label.isEmpty, label.count <= 40, words.count <= 4 else { return nil }
        return String(line[..<after])
    }

    private static func splitLongLine(_ line: String, budget: Int) -> [String] {
        let prefix = speakerLabel(of: line)
        let body = prefix.map { String(line.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? line
        let labelPrefix = prefix.map { $0 + " " } ?? ""
        let pieceBudget = max(8, budget - TokenEstimator.estimate(labelPrefix) - 1)

        // Sentence-level split, then word-level for any sentence that is still too long.
        var sentences: [String] = []
        body.enumerateSubstrings(in: body.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty { sentences = [body] }

        var pieces: [String] = []
        for sentence in sentences {
            if TokenEstimator.estimate(sentence) <= pieceBudget {
                pieces.append(sentence)
                continue
            }
            var current: [Substring] = []
            for word in sentence.split(separator: " ") {
                let candidate = (current + [word]).joined(separator: " ")
                if TokenEstimator.estimate(candidate) > pieceBudget, !current.isEmpty {
                    pieces.append(current.joined(separator: " "))
                    current = [word]
                } else {
                    current.append(word)
                }
            }
            if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
        }

        // Re-pack sentences so we don't produce one unit per sentence.
        var packed: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : current + " " + piece
            if TokenEstimator.estimate(candidate) > pieceBudget, !current.isEmpty {
                packed.append(current)
                current = piece
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { packed.append(current) }
        return packed.map { labelPrefix + $0 }
    }
}
