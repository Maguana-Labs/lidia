import Foundation

/// What the notes pipeline produced for one meeting.
public struct MeetingNotesResult: Sendable, Hashable {
    public var title: String
    public var markdown: String
    public var decisions: [String]
    public var actionItems: [ExtractedActionItem]
    /// How many condense (map) calls the transcript needed; 0 when it fit.
    public var condensedParts: Int
}

/// Transcript → markdown notes → title, decisions and action items.
///
/// The same steps as the Mac's pipeline (streamed markdown notes, then a
/// small facts step), sized for a small context: the transcript is condensed
/// with map-reduce until it fits next to the prompt and the answer budget.
public struct MeetingNotesPipeline: Sendable {
    public enum Phase: Sendable, Equatable {
        case condensing(part: Int, of: Int)
        case writing
        case extracting
    }

    /// Answer budget for the notes, as on the Mac (`summaryOutputTokens`).
    public static let notesOutputTokens = 1200
    /// Framing tokens per request (role markers, template).
    static let overheadTokens = 48

    public let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    /// Overall time for the notes step: 10 minutes plus 20 seconds per 1,000
    /// transcript tokens, at most 40 minutes (the Mac's `PipelineLimits`).
    public static func timeout(transcriptTokens: Int) -> TimeInterval {
        min(40 * 60, 10 * 60 + Double(transcriptTokens) / 1000 * 20)
    }

    public func run(
        transcript: String,
        attendees: [String]? = nil,
        onPhase: @escaping @Sendable (Phase) async -> Void = { _ in },
        onText: @escaping @Sendable (String) async -> Void = { _ in },
        onReset: @escaping @Sendable () async -> Void = {}
    ) async throws -> MeetingNotesResult {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        let system = MeetingPrompts.notesSystemPrompt(attendees: attendees, wordCount: words)
        let transcriptTokens = try await generator.countTokens(transcript)
        let deadline = Self.timeout(transcriptTokens: transcriptTokens)

        let (markdown, parts) = try await withTimeout(seconds: deadline, step: "notes") {
            try await writeNotes(transcript: transcript, system: system, onPhase: onPhase, onText: onText, onReset: onReset)
        }

        await onPhase(.extracting)
        var facts: MeetingFacts?
        do {
            facts = try await withTimeout(seconds: 180, step: "action items") {
                try await generator.extractFacts(notes: markdown)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            facts = nil
        }

        let parsedSteps = NotesMarkdown.nextSteps(in: markdown)
        let parsedDecisions = NotesMarkdown.decisions(in: markdown)
        var title = facts?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty || title.lowercased().contains("meeting summary") {
            title = NotesMarkdown.firstHeading(in: markdown) ?? ""
        }
        let items = (facts?.actionItems.isEmpty == false) ? facts!.actionItems : parsedSteps
        let decisions = (facts?.decisions.isEmpty == false) ? facts!.decisions : parsedDecisions
        return MeetingNotesResult(
            title: title,
            markdown: markdown,
            decisions: decisions,
            actionItems: items,
            condensedParts: parts
        )
    }

    private func writeNotes(
        transcript: String,
        system: String,
        onPhase: @escaping @Sendable (Phase) async -> Void,
        onText: @escaping @Sendable (String) async -> Void,
        onReset: @escaping @Sendable () async -> Void
    ) async throws -> (String, Int) {
        let systemTokens = try await generator.countTokens(system)
        var budget = generator.contextTokens - Self.notesOutputTokens - systemTokens - Self.overheadTokens
        var lastError: Error?

        // Second attempt shrinks the input: token counts are estimates on 26.0–26.3.
        for attempt in 0..<2 {
            guard budget >= 256 else { throw GeneratorError.contextLengthExceeded }
            let fitted = try await fit(transcript: transcript, budget: budget, onPhase: onPhase)
            await onPhase(.writing)
            var cleaner = MarkdownStreamCleaner()
            var markdown = ""
            do {
                for try await delta in generator.stream(
                    instructions: system,
                    prompt: fitted.prompt,
                    maxTokens: Self.notesOutputTokens,
                    temperature: 0.2
                ) {
                    let visible = cleaner.consume(delta)
                    if !visible.isEmpty {
                        markdown += visible
                        await onText(visible)
                    }
                }
                let tail = cleaner.finish()
                if !tail.isEmpty {
                    markdown += tail
                    await onText(tail)
                }
                let cleaned = NotesMarkdown.clean(markdown)
                guard !cleaned.isEmpty else { throw GeneratorError.badResponse("the notes were empty") }
                return (cleaned, fitted.parts)
            } catch GeneratorError.contextLengthExceeded where attempt == 0 {
                lastError = GeneratorError.contextLengthExceeded
                budget = Int(Double(budget) * 0.65)
                await onReset()
                continue
            }
        }
        throw lastError ?? GeneratorError.contextLengthExceeded
    }

    private func fit(
        transcript: String,
        budget: Int,
        onPhase: @escaping @Sendable (Phase) async -> Void
    ) async throws -> (prompt: String, parts: Int) {
        let tokens = try await generator.countTokens(transcript)
        if tokens <= budget { return (transcript, 0) }

        let header = MeetingPrompts.reduceHeader(partCount: 99)
        let target = budget - TokenEstimate.estimate(header)
        let generator = generator
        let fitter = ContextFitter(
            contextTokens: generator.contextTokens,
            countTokens: { try await generator.countTokens($0) },
            condense: { chunk, index, total in
                await onPhase(.condensing(part: index + 1, of: total))
                return try await generator.respond(
                    instructions: ContextFitter.condenseInstructions,
                    prompt: chunk,
                    maxTokens: max(256, generator.contextTokens / 4),
                    temperature: 0.2
                )
            }
        )
        let (condensed, parts) = try await fitter.condenseToFit(transcript, targetTokens: target)
        return (MeetingPrompts.reduceHeader(partCount: max(parts, 1)) + condensed, parts)
    }
}

/// Runs `operation`, cancelling it and throwing `GeneratorError.timedOut` after `seconds`.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    step: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw GeneratorError.timedOut(step: step)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
