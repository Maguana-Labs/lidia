import Foundation
import os

// MARK: - Streaming markdown summary

extension MapReduceSummarizer {
    struct MarkdownResult: Sendable {
        /// The cleaned markdown summary, exactly what the user saw stream.
        let markdown: String
        /// See `Result.coverageText`.
        let coverageText: String
        let partCount: Int
        var truncated = false
        /// Seconds from the summary request to its first visible token.
        var timeToFirstToken: TimeInterval?
    }

    /// Summarises the transcript as markdown, streaming visible text to `onText`
    /// as the model writes it. Long transcripts are condensed first (map), then
    /// the final pass over the notes streams.
    ///
    /// `onReset` is called before a retry so the UI drops partial text.
    func summarizeMarkdown(
        transcript: String,
        legend: String?,
        systemPrompt: String,
        onText: @escaping @MainActor (String) -> Void,
        onReset: @escaping @MainActor () -> Void
    ) async throws -> MarkdownResult {
        let requestStart = Date()
        let legendBlock = legend.map { $0 + "\n\n" } ?? ""
        let legendTokens = TokenEstimator.estimate(legendBlock)
        let promptTokens = TokenEstimator.estimate(systemPrompt)
        let available = budget.inputTokens - max(0, promptTokens - 1200)

        if TokenEstimator.estimate(transcript) + legendTokens <= available {
            onProgress?(String(localized: "Summarizing"), 0.1)
            let (markdown, ttft) = try await streamFinal(
                started: requestStart,
                system: systemPrompt,
                user: legendBlock + transcript,
                onText: onText,
                onReset: onReset
            )
            onProgress?(String(localized: "Summarizing"), 1)
            return MarkdownResult(markdown: markdown, coverageText: transcript, partCount: 1, timeToFirstToken: ttft)
        }

        let (combined, partCount, truncated) = try await condenseToFit(
            transcript: transcript,
            legendBlock: legendBlock,
            legendTokens: legendTokens,
            reduceBudget: available - Self.reduceHeaderTokens
        )
        onProgress?(String(localized: "Combining \(partCount) parts"), Double(partCount) / Double(partCount + 1))
        let (markdown, ttft) = try await streamFinal(
            started: requestStart,
            system: systemPrompt,
            user: Self.reduceHeader(partCount: partCount) + combined,
            onText: onText,
            onReset: onReset
        )
        onProgress?(String(localized: "Summarizing"), 1)
        return MarkdownResult(
            markdown: markdown,
            coverageText: combined,
            partCount: partCount,
            truncated: truncated,
            timeToFirstToken: ttft
        )
    }

    /// Map + condense rounds shared by the JSON and markdown paths.
    func condenseToFit(
        transcript: String,
        legendBlock: String,
        legendTokens: Int,
        reduceBudget: Int
    ) async throws -> (combined: String, partCount: Int, truncated: Bool) {
        let partBudget = max(256, budget.inputTokens - legendTokens - Self.mapPromptTokens)
        var parts = TranscriptChunker.chunk(transcript, maxTokens: partBudget, overlapTokens: 80)
        var truncatedInput = false
        if parts.count > PipelineLimits.maxMapParts {
            // A small context would need too many calls (each one is slow on
            // Apple Intelligence): keep the start and end of the meeting instead.
            let keepTokens = max(partBudget, (partBudget - 80) * PipelineLimits.maxMapParts * 85 / 100)
            let fitted = Self.truncateToFit(transcript, maxTokens: keepTokens)
            parts = TranscriptChunker.chunk(fitted, maxTokens: partBudget, overlapTokens: 80)
            if parts.count > PipelineLimits.maxMapParts {
                // Still too many: keep the opening and the closing parts.
                let half = PipelineLimits.maxMapParts / 2
                parts = Array(parts.prefix(half)) + Array(parts.suffix(PipelineLimits.maxMapParts - half))
            }
            truncatedInput = true
            onWarning?(String(localized: "This meeting is too long for the selected model to read in full. Part of the middle was left out of the summary; a downloaded on-device model covers it all."))
        }
        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let label = String(localized: "Summarizing part \(index + 1) of \(parts.count)")
            onProgress?(label, Double(index) / Double(parts.count + 1))
            let condensed = try await client.chat(
                messages: [
                    .init(role: "system", content: Self.mapPrompt(part: index + 1, of: parts.count)),
                    .init(role: "user", content: legendBlock + part),
                ],
                model: model,
                format: nil
            )
            notes.append("### Part \(index + 1) of \(parts.count)\n" + Self.stripThinking(condensed))
        }

        var combined = notes.joined(separator: "\n\n")
        var depth = 0
        while TokenEstimator.estimate(combined) > reduceBudget, depth < Self.maxReduceDepth {
            depth += 1
            let before = combined
            let groups = TranscriptChunker.chunk(combined, maxTokens: max(256, budget.inputTokens - Self.mapPromptTokens))
            var condensedGroups: [String] = []
            for group in groups {
                try Task.checkCancellation()
                let condensed = try await client.chat(
                    messages: [
                        .init(role: "system", content: Self.condensePrompt),
                        .init(role: "user", content: group),
                    ],
                    model: model,
                    format: nil
                )
                condensedGroups.append(Self.stripThinking(condensed))
            }
            let next = condensedGroups.joined(separator: "\n\n")
            guard TokenEstimator.estimate(next) < TokenEstimator.estimate(before) else {
                combined = before
                break
            }
            combined = next
        }

        var truncated = truncatedInput
        if TokenEstimator.estimate(combined) > reduceBudget {
            combined = Self.truncateToFit(combined, maxTokens: reduceBudget)
            // One warning per meeting about missing coverage is enough.
            if !truncated { warnTooLong() }
            truncated = true
        }
        return (combined, parts.count, truncated)
    }

    private func warnTooLong() {
        onWarning?(String(localized: "This meeting was too long for the selected model's context, even after condensing. Part of the middle of the meeting was left out of the summary; a model with a larger context covers it all."))
    }

    /// Streams one request. Retries once on a retryable error (resetting the
    /// visible text first). Falls back to a plain `chat` call when a client's
    /// stream yields nothing.
    private func streamFinal(
        started: Date,
        system: String,
        user: String,
        onText: @escaping @MainActor (String) -> Void,
        onReset: @escaping @MainActor () -> Void
    ) async throws -> (String, TimeInterval?) {
        let messages: [LLMChatMessage] = [
            .init(role: "system", content: system),
            .init(role: "user", content: user),
        ]
        var attempt = 0
        while true {
            attempt += 1
            var firstTokenAt: Date?
            var collected = ""
            do {
                var reasoning = ReasoningFilter()
                var fence = MarkdownStreamCleaner()
                for try await chunk in await client.chatStream(messages: messages, model: model) {
                    try Task.checkCancellation()
                    let visible = fence.consume(reasoning.consume(chunk))
                    guard !visible.isEmpty else { continue }
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    collected += visible
                    onText(visible)
                }
                let tail = fence.consume(reasoning.finish()) + fence.finish()
                if !tail.isEmpty {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    collected += tail
                    onText(tail)
                }
                if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Some clients don't stream: ask once without streaming.
                    let whole = Self.stripThinking(try await client.chat(messages: messages, model: model, format: nil))
                    let cleaned = SummaryMarkdownParser.clean(whole)
                    guard !cleaned.isEmpty else {
                        throw LLMError.invalidResponse("The model returned an empty summary.")
                    }
                    firstTokenAt = Date()
                    onText(cleaned)
                    collected = cleaned
                }
                let ttft = firstTokenAt.map { $0.timeIntervalSince(started) }
                return (SummaryMarkdownParser.clean(collected), ttft)
            } catch {
                if error is CancellationError || attempt >= 2 || !RetryClassifier.isRetryable(error) {
                    throw error
                }
                onReset()
            }
        }
    }
}

// MARK: - Facts (title, decisions, action items)

struct MeetingFacts: Sendable, Equatable {
    var title: String?
    var decisions: [String]
    var actionItems: [MeetingSummaryResponse.ActionItemResponse]

    static func == (lhs: MeetingFacts, rhs: MeetingFacts) -> Bool {
        lhs.title == rhs.title && lhs.decisions == rhs.decisions
            && lhs.actionItems.map(\.title) == rhs.actionItems.map(\.title)
    }
}

/// The small structured step next to the streamed summary. It reads the
/// finished markdown (short, so even a small model handles it quickly) or, for
/// cloud providers that can run requests concurrently, the transcript itself.
enum MeetingFactsExtractor {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "MeetingFacts")

    private struct Payload: Decodable {
        struct Item: Decodable {
            let title: String
            let assignee: String?
            let deadline: String?
        }
        let title: String?
        let decisions: [String]?
        let action_items: [Item]?
    }

    static func extract(client: any LLMClient, model: String, notes: String, glossary: String = "", userName: String = "") async -> MeetingFacts? {
        do {
            let system = SummaryPrompts.factsSystemPrompt(userName: userName)
            let raw = try await client.chat(
                messages: [
                    .init(role: "system", content: glossary.isEmpty ? system : system + "\n- " + glossary),
                    .init(role: "user", content: notes),
                ],
                model: model,
                format: .json
            )
            return parse(raw)
        } catch {
            logger.warning("Facts extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func parse(_ raw: String) -> MeetingFacts? {
        var text = MapReduceSummarizer.stripThinking(raw)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        }
        return MeetingFacts(
            title: clean(payload.title),
            decisions: (payload.decisions ?? []).compactMap(clean),
            actionItems: (payload.action_items ?? []).compactMap { item in
                guard let title = clean(item.title) else { return nil }
                return .init(title: title, assignee: clean(item.assignee), deadline: clean(item.deadline), sourceQuote: nil)
            }
        )
    }
}
