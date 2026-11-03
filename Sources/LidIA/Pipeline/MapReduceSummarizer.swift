import Foundation

/// Summarises transcripts of any length.
///
/// Short transcripts go straight to `LLMClient.summarizeMeeting`. Long ones are split
/// with `TranscriptChunker`, each part is condensed into notes ("map"), and the notes are
/// summarised together ("reduce"). If the combined notes are still too long they are
/// condensed again (up to `maxReduceDepth` rounds). If they still don't fit, the middle
/// is truncated and a warning is reported: a request never exceeds the budget.
@MainActor
struct MapReduceSummarizer {
    let client: any LLMClient
    let model: String
    let budget: SummarizationBudget
    /// Called with a detail string and a 0...1 fraction as parts complete.
    var onProgress: (@MainActor (String, Double) -> Void)?
    /// Called with a user-facing message when coverage had to be reduced (truncation).
    var onWarning: (@MainActor (String) -> Void)?

    /// Upper bound on condense rounds. Each round normally halves the notes or better,
    /// so this covers any realistic meeting; the loop also stops early when a round
    /// no longer shrinks the text.
    static let maxReduceDepth = 8
    /// Tokens held back for the map prompt itself.
    static let mapPromptTokens = 400

    struct Result: Sendable {
        let response: MeetingSummaryResponse
        /// The densest text that still covers the whole meeting and fits one request:
        /// the transcript itself when it fits, else the condensed notes.
        let coverageText: String
        /// Number of transcript parts in the map step (1 when no chunking was needed).
        let partCount: Int
        /// True when the condensed notes still didn't fit and had to be truncated.
        var truncated = false
    }

    func summarize(
        transcript: String,
        legend: String?,
        template: MeetingTemplate?,
        attendees: [String]?
    ) async throws -> Result {
        let legendBlock = legend.map { $0 + "\n\n" } ?? ""
        let legendTokens = TokenEstimator.estimate(legendBlock)

        if TokenEstimator.estimate(transcript) + legendTokens <= budget.inputTokens {
            onProgress?(String(localized: "Summarizing"), 0.1)
            let response = try await client.summarizeMeeting(
                transcript: legendBlock + transcript,
                model: model,
                template: template,
                attendees: attendees
            )
            onProgress?(String(localized: "Summarizing"), 1)
            return Result(response: response, coverageText: transcript, partCount: 1)
        }

        let (combined, partCount, truncated) = try await condenseToFit(
            transcript: transcript,
            legendBlock: legendBlock,
            legendTokens: legendTokens,
            reduceBudget: budget.inputTokens - Self.reduceHeaderTokens
        )
        onProgress?(String(localized: "Combining \(partCount) parts"), Double(partCount) / Double(partCount + 1))
        let response = try await client.summarizeMeeting(
            transcript: Self.reduceHeader(partCount: partCount) + combined,
            model: model,
            template: template,
            attendees: attendees
        )
        onProgress?(String(localized: "Summarizing"), 1)
        return Result(response: response, coverageText: combined, partCount: partCount, truncated: truncated)
    }

    static let truncationMarker = "\n\n[… part of the middle of the meeting was omitted to fit the model's context …]\n\n"

    /// Keeps the start and the end of `text` (where context and wrap-up/action items
    /// usually are) and drops the middle so the result fits `maxTokens`.
    static func truncateToFit(_ text: String, maxTokens: Int) -> String {
        guard TokenEstimator.estimate(text) > maxTokens else { return text }
        guard TokenEstimator.estimate(truncationMarker) < maxTokens else { return "" }
        var keep = min(text.count, maxTokens * 4)
        while keep > 0 {
            let head = keep / 2
            let candidate = String(text.prefix(head)) + truncationMarker + String(text.suffix(keep - head))
            if TokenEstimator.estimate(candidate) <= maxTokens { return candidate }
            keep = keep * 9 / 10
        }
        return truncationMarker.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompts

    static func mapPrompt(part: Int, of total: Int) -> String {
        """
        You are condensing part \(part) of \(total) of a long meeting transcript so it can be \
        summarised later together with the other parts.

        Write compact markdown notes covering EVERYTHING substantive in this part:
        - Topics discussed, with the key facts, numbers, names and reasoning
        - Decisions made (prefix with "Decision:")
        - Commitments / action items with owner and deadline if stated (prefix with "Action:")
        - Open questions or disagreements

        Rules:
        - Keep speaker labels exactly as written in the transcript (e.g. "Me", "Them", names). Never guess names.
        - Never invent anything that is not in the text.
        - No preamble, no conclusion. Bullets only. At most about 250 words.
        """
    }

    static let condensePrompt = """
        These are consecutive notes from parts of one long meeting. Condense them into \
        shorter markdown bullets while keeping every decision ("Decision:"), every action \
        item ("Action:") with owner and deadline, key numbers and speaker labels. \
        Do not invent anything. Bullets only.
        """

    static func reduceHeader(partCount: Int) -> String {
        """
        NOTE: This meeting was too long to process at once. Below are condensed notes \
        covering all \(partCount) consecutive parts of the meeting, in order. Treat them as \
        the complete meeting record. Lines starting "Decision:" are decisions and lines \
        starting "Action:" are action items.


        """
    }

    static var reduceHeaderTokens: Int { TokenEstimator.estimate(reduceHeader(partCount: 99)) }

    /// Removes `<think>…</think>` reasoning blocks some local models emit.
    nonisolated static func stripThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = result.range(of: "</think>") {
            result = String(result[close.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
