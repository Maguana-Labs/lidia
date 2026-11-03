import Foundation
import SwiftData
import os

/// Errors the pipeline reports to callers. Messages are shown to the user as
/// `Meeting.processingError`.
enum PipelineError: LocalizedError, Equatable {
    case emptyTranscript
    /// The meeting was deleted while the pipeline waited on the model. Nothing is written.
    case meetingDeleted

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return String(localized: "No speech was captured in this recording, so there is nothing to summarize. Check that LidIA has microphone and screen-audio permission, then record again. You can still type notes and use Regenerate.")
        case .meetingDeleted:
            return String(localized: "The meeting was deleted while it was being processed.")
        }
    }
}

/// Post-meeting processing: speaker-labelled transcript → cleanup → summary (map-reduce
/// for long meetings, merged with the user's notes) → action items.
///
/// Guarantees:
/// - The meeting always ends `.complete` or `.failed` with a `processingError`, never stuck in `.processing`.
/// - A failed cleanup step falls back to the raw transcript instead of failing the meeting.
/// - Action items the user created or touched are never deleted; only untouched AI items are replaced.
/// - Live per-stage progress is published on `ProcessingProgressCenter.shared`.
@MainActor
@Observable
final class MeetingPipeline {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "MeetingPipeline")

    private let llmClient: any LLMClient
    /// Client and model for the small structured step (title, decisions, action items).
    private let factsClient: any LLMClient
    private let factsModel: String?
    /// Run the LLM transcript cleanup pass before summarising. Off by default: it
    /// rewrites the whole transcript and delays the summary by minutes on local
    /// models (see docs/research/2026-11-summary-benchmark.md).
    let refineWithLLM: Bool
    let modelContext: ModelContext
    let budget: SummarizationBudget
    private let progressCenter: ProcessingProgressCenter

    /// Legacy single-line status. Prefer `ProcessingProgressCenter.shared.progress(for:)`.
    var processingStatus: String = ""

    /// Replaces `PipelineLimits.summaryTimeout` (tests).
    @ObservationIgnored
    var summaryTimeoutOverride: TimeInterval?

    /// Action items the latest `process` run inserted and removed, by meeting ID.
    /// Regenerate's undo uses this so it only reverts the pipeline's own changes and
    /// never deletes items the user, MCP inbox or sync added in the meantime.
    struct ActionItemChanges: Sendable, Equatable {
        var inserted: Set<UUID> = []
        var removed: Set<UUID> = []
    }

    @ObservationIgnored
    var actionItemChanges: [UUID: ActionItemChanges] = [:]

    init(
        llmClient: any LLMClient,
        modelContext: ModelContext,
        budget: SummarizationBudget? = nil,
        progressCenter: ProcessingProgressCenter? = nil,
        factsClient: (any LLMClient)? = nil,
        factsModel: String? = nil,
        refineWithLLM: Bool = false
    ) {
        let client = PipelineClientFactory.pipelineClient(for: llmClient)
        self.llmClient = client
        self.factsClient = factsClient.map { PipelineClientFactory.pipelineClient(for: $0) } ?? client
        self.factsModel = factsModel
        self.refineWithLLM = refineWithLLM
        self.modelContext = modelContext
        self.budget = budget ?? .resolved(for: client)
        self.progressCenter = progressCenter ?? .shared
    }

    nonisolated static func buildRawText(from words: [TranscriptWord]) -> String {
        words.map(\.word).joined(separator: " ")
    }

    /// Transcript with "Me:" / "Them:" / speaker-name turns, as sent to the LLM.
    nonisolated static func buildLabeledTranscript(from words: [TranscriptWord]) -> String {
        SpeakerTranscriptFormatter.format(words)
    }

    // MARK: - Process

    func process(
        meeting: Meeting,
        model: String,
        template: MeetingTemplate? = nil,
        vocabulary: [AppSettings.VocabularyEntry] = [],
        preserveUserEdits: Bool = true,
        userName: String = ""
    ) async throws {
        // Every LLM call below can take minutes, and the meeting can be deleted meanwhile
        // (sync, MCP inbox). It is re-fetched by ID after each await before it is touched.
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        func ensureLive() throws {
            guard LiveModel.meetingExists(meetingID, in: home) else {
                progressCenter.end(meetingID: meetingID)
                processingStatus = "Cancelled"
                throw PipelineError.meetingDeleted
            }
        }

        let progress = progressCenter.start(meetingID: meetingID)
        actionItemChanges[meetingID] = ActionItemChanges()

        let labeled = Self.buildLabeledTranscript(from: meeting.rawTranscript)
        let editedTranscript = preserveUserEdits
            ? (meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        let outline = NoteOutlineParser.parse(meeting.notes)
        let hasTranscript = !labeled.isEmpty || !editedTranscript.isEmpty

        guard hasTranscript || !outline.isEmpty else {
            let error = PipelineError.emptyTranscript
            meeting.status = .failed
            meeting.processingError = error.localizedDescription
            try? modelContext.save()
            progress.fail(.transcribing, message: error.localizedDescription)
            progressCenter.end(meetingID: meeting.id)
            processingStatus = "Failed"
            throw error
        }

        guard !model.isEmpty else {
            meeting.processingError = String(localized: "No model selected. Open Settings and choose a model, or click Fetch Models.")
            meeting.status = .failed
            try? modelContext.save()
            progress.fail(nil, message: meeting.processingError ?? "")
            progressCenter.end(meetingID: meeting.id)
            processingStatus = "Failed"
            return
        }

        meeting.status = .processing
        meeting.processingError = nil
        meeting.templateID = template?.id
        try? modelContext.save()

        // Stage: speakers + transcript cleanup (never fatal).
        // The LLM cleanup pass rewrote the whole transcript before the summary could
        // start (minutes on a local model for a one-hour meeting), so it is off by
        // default: custom vocabulary is applied deterministically instead, and the
        // summary model reads the speaker-labelled transcript directly.
        progress.begin(.speakers, detail: String(localized: "Cleaning up transcript"))
        processingStatus = "Refining transcript..."
        if !editedTranscript.isEmpty {
            meeting.refinedTranscript = editedTranscript
        } else if !labeled.isEmpty {
            let corrected = VocabularyCorrector.apply(vocabulary, to: labeled)
            let refined: String
            if refineWithLLM {
                refined = await refine(
                    corrected,
                    model: model,
                    attendees: meeting.calendarAttendees,
                    vocabulary: vocabulary,
                    progress: progress
                )
                try ensureLive()
            } else {
                refined = corrected
            }
            meeting.refinedTranscript = refined
            if !preserveUserEdits {
                meeting.userEditedTranscript = nil
            }
        }
        try? modelContext.save()
        progress.complete(.speakers)

        // Stage: summary (fatal on failure — there is nothing useful to show without it).
        progress.begin(.summarizing)
        processingStatus = "Generating summary..."
        let transcriptForSummary = hasTranscript
            ? effectiveTranscript(for: meeting, preserveUserEdits: preserveUserEdits)
            : meeting.notes
        let legend = hasTranscript
            ? SpeakerTranscriptFormatter.legend(for: meeting.rawTranscript, attendees: meeting.calendarAttendees, userName: userName)
            : "NOTE: There is no recording for this meeting. The text below is the user's own notes."
        let summarizer = MapReduceSummarizer(
            client: llmClient,
            model: model,
            budget: budget,
            onProgress: { detail, fraction in progress.update(detail: detail, fraction: fraction) },
            onWarning: { message in progress.warn(message) }
        )
        // The user's confirmed spellings (TAPR, company and people's names) go into
        // every prompt that writes text the user sees.
        let glossary = PersonalGlossary.promptBlock(vocabulary)
        let markdownPrompt = SummaryPrompts.markdownSystemPrompt(
            template: template,
            attendees: meeting.calendarAttendees,
            wordCount: transcriptForSummary.split(separator: " ").count,
            glossary: glossary,
            userName: userName
        )

        // Cloud providers serve concurrent requests, so the structured facts are
        // extracted from the transcript while the summary streams. Local models share
        // one GPU (MLX serialises requests), so there the facts are read from the
        // finished summary, which is short and quick to process.
        let factsClient = self.factsClient
        let factsModel = self.factsModel ?? model
        var concurrentFacts: Task<MeetingFacts?, Never>?
        if markdownPrompt != nil,
           PipelineClientFactory.canRunConcurrently(factsClient),
           TokenEstimator.estimate(transcriptForSummary) <= budget.inputTokens {
            let notes = transcriptForSummary
            concurrentFacts = Task {
                await MeetingFactsExtractor.extract(client: factsClient, model: factsModel, notes: notes, glossary: glossary, userName: userName)
            }
        }

        let response: MeetingSummaryResponse
        let coverageText: String
        var streamedMarkdown: String?
        do {
            if let markdownPrompt {
                let center = progressCenter
                center.resetSummaryText(meetingID: meetingID)
                let started = Date()
                let deadline = summaryTimeoutOverride ?? PipelineLimits.summaryTimeout(transcriptTokens: TokenEstimator.estimate(transcriptForSummary))
                let result = try await withDeadline(seconds: deadline, step: String(localized: "summary")) {
                    try await Self.summarizeMarkdownFittingContext(
                        summarizer: summarizer,
                        transcript: transcriptForSummary,
                        legend: legend,
                        systemPrompt: markdownPrompt,
                        onText: { center.appendSummaryText($0, meetingID: meetingID) },
                        onReset: { center.resetSummaryText(meetingID: meetingID) }
                    )
                }
                let total = Date().timeIntervalSince(started)
                Self.logger.info("Summary streamed: first token \(result.timeToFirstToken ?? -1, privacy: .public)s, total \(total, privacy: .public)s, \(result.partCount, privacy: .public) part(s)")
                try ensureLive()
                streamedMarkdown = result.markdown
                coverageText = result.coverageText

                progress.update(detail: String(localized: "Finding the title and action items"))
                var facts = await concurrentFacts?.value
                if facts == nil {
                    let notes = result.markdown
                    facts = try? await withDeadline(seconds: PipelineLimits.auxiliaryTimeout, step: String(localized: "title step")) {
                        await MeetingFactsExtractor.extract(client: factsClient, model: factsModel, notes: notes, glossary: glossary, userName: userName)
                    }
                }
                try ensureLive()
                response = Self.response(markdown: result.markdown, facts: facts)
            } else {
                // Custom free-form template: its prompt defines the output, so keep the JSON path.
                let attendees = meeting.calendarAttendees
                let deadline = summaryTimeoutOverride ?? PipelineLimits.summaryTimeout(transcriptTokens: TokenEstimator.estimate(transcriptForSummary))
                let result = try await withDeadline(seconds: deadline, step: String(localized: "summary")) {
                    try await summarizer.summarize(
                        transcript: transcriptForSummary,
                        legend: legend,
                        template: template,
                        attendees: attendees
                    )
                }
                response = result.response
                coverageText = result.coverageText
            }
        } catch {
            concurrentFacts?.cancel()
            try ensureLive()
            progressCenter.resetSummaryText(meetingID: meetingID)
            meeting.processingError = String(localized: "Summary generation failed: \(error.localizedDescription)")
            meeting.status = .failed
            try? modelContext.save()
            progress.fail(.summarizing, message: meeting.processingError ?? "")
            progressCenter.end(meetingID: meeting.id)
            processingStatus = "Failed"
            throw error
        }

        var structured = response.toStructured()

        if hasTranscript, !outline.isEmpty {
            progress.update(detail: String(localized: "Merging your notes"))
            var merger = NotesMerger(client: llmClient, model: model, budget: budget)
            merger.glossary = glossary
            let aiSummary = structured ?? Self.structuredFromFlat(response)
            let merged = await merger.merge(
                outline: outline,
                record: coverageText,
                aiSummary: aiSummary,
                title: response.title
            )
            try ensureLive()
            structured = merged.summary
            streamedMarkdown = nil // the merged notes replace the streamed text
            if !merged.enhanced {
                progress.warn(String(localized: "Couldn't add AI detail to your notes; showing your notes followed by the AI summary."))
            }
        }

        // An untitled or placeholder-titled recording ("New Note") gets the
        // notes' title, marked as AI-written; a title the user typed stays.
        if meeting.title.isEmpty || (NoteAutoTitle.isPlaceholder(meeting.title) && !IntentStore.shared.isUserTitled(meeting.id)) {
            meeting.title = response.title
            IntentStore.shared.setAITitle(response.title, contentLength: meeting.notes.count, for: meeting.id)
        }
        if preserveUserEdits,
           let editedSummary = meeting.userEditedSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !editedSummary.isEmpty {
            // Keep the user's edited summary text.
        } else {
            // The streamed markdown is saved verbatim (nesting included), so the
            // stored summary is exactly what the user watched being written.
            meeting.summary = streamedMarkdown ?? structured?.markdownSummary ?? response.flatSummary
            if !preserveUserEdits {
                meeting.userEditedSummary = nil
            }
        }
        if let structured {
            meeting.structuredSummary = try? JSONEncoder().encode(structured)
        }
        try? modelContext.save()
        progressCenter.resetSummaryText(meetingID: meetingID)
        progress.complete(.summarizing)

        // Stage: action items (never fatal once a summary exists).
        progress.begin(.actionItems)
        processingStatus = "Extracting action items..."
        // Check each item against the transcript: owner and direction right,
        // and flagged when nothing backs it (never silently dropped).
        let verification = await ActionItemVerifier.verify(
            response.actionItems,
            words: meeting.rawTranscript,
            transcript: meeting.refinedTranscript,
            attendees: meeting.calendarAttendees ?? [],
            userName: userName,
            client: factsClient,
            model: factsModel
        )
        try ensureLive()
        var added = replaceAIActionItems(in: meeting, with: verification.items)
        verification.record(added, meetingDate: meeting.date, in: IntentStore.shared)
        if !outline.isEmpty {
            processingStatus = "Processing notes..."
            added += await extractNoteActionItems(meeting: meeting, model: model, glossary: glossary)
            try ensureLive()
        }
        if !added.isEmpty {
            processingStatus = "Detecting action destinations..."
            let addedItems = added
            try? await withDeadline(seconds: PipelineLimits.auxiliaryTimeout, step: String(localized: "destination step")) {
                await self.detectDestinations(items: addedItems, model: model, in: home)
            }
            try ensureLive()
        }
        progress.complete(.actionItems)

        meeting.status = .complete
        meeting.processingError = nil
        try modelContext.save()
        progress.finish()
        progressCenter.end(meetingID: meeting.id)
        processingStatus = "Done"
    }

    /// Streams the summary; if the model still reports that the request didn't
    /// fit its context (token estimates are approximate, and Apple
    /// Intelligence counts its own instructions and answer), retries once with
    /// half the input budget, which condenses the transcript first.
    static func summarizeMarkdownFittingContext(
        summarizer: MapReduceSummarizer,
        transcript: String,
        legend: String?,
        systemPrompt: String,
        onText: @escaping @MainActor (String) -> Void,
        onReset: @escaping @MainActor () -> Void
    ) async throws -> MapReduceSummarizer.MarkdownResult {
        do {
            return try await summarizer.summarizeMarkdown(
                transcript: transcript, legend: legend, systemPrompt: systemPrompt,
                onText: onText, onReset: onReset
            )
        } catch LLMError.contextLengthExceeded {
            logger.warning("Summary didn't fit the model's context; retrying with a smaller budget")
            onReset()
            let budget = summarizer.budget
            let smaller = SummarizationBudget(
                contextTokens: budget.contextTokens,
                reservedTokens: budget.reservedTokens + budget.inputTokens / 2
            )
            let retry = MapReduceSummarizer(
                client: summarizer.client,
                model: summarizer.model,
                budget: smaller,
                onProgress: summarizer.onProgress,
                onWarning: summarizer.onWarning
            )
            return try await retry.summarizeMarkdown(
                transcript: transcript, legend: legend, systemPrompt: systemPrompt,
                onText: onText, onReset: onReset
            )
        }
    }

    /// Builds the pipeline's response from the streamed markdown and the
    /// (optional) extracted facts. Action items come from the summary's "Next
    /// Steps" section when it has one, so the list matches what the user read;
    /// otherwise from the facts step.
    nonisolated static func response(markdown: String, facts: MeetingFacts?) -> MeetingSummaryResponse {
        let sections = SummaryMarkdownParser.sections(in: markdown)
        let nextSteps = SummaryMarkdownParser.nextSteps(in: markdown)
        var decisions = SummaryMarkdownParser.decisions(in: markdown)
        for decision in facts?.decisions ?? []
        where !decisions.contains(where: { $0.caseInsensitiveCompare(decision) == .orderedSame }) {
            decisions.append(decision)
        }
        let actionItems = nextSteps.isEmpty ? (facts?.actionItems ?? []) : nextSteps
        let title = facts?.title
            ?? SummaryMarkdownParser.firstHeading(in: markdown)
            ?? String(localized: "Meeting notes")
        return MeetingSummaryResponse(
            title: title,
            summary: markdown,
            summarySections: sections.isEmpty ? nil : sections,
            decisions: decisions,
            actionItems: actionItems
        )
    }

    // MARK: - Transcript cleanup

    /// Cleans the labelled transcript chunk by chunk. Any failure, or a suspiciously short
    /// result (the model summarised instead of cleaning), falls back to the labelled text.
    private func refine(
        _ labeled: String,
        model: String,
        attendees: [String]?,
        vocabulary: [AppSettings.VocabularyEntry],
        progress: MeetingProcessingProgress
    ) async -> String {
        // Output is about as long as input, so both must fit the context window.
        let chunkTokens = min(3800, max(256, (budget.contextTokens - 800) / 2))
        let chunks = TranscriptChunker.chunk(labeled, maxTokens: chunkTokens)
        var refinedParts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if chunks.count > 1 {
                progress.update(
                    detail: String(localized: "Cleaning up transcript part \(index + 1) of \(chunks.count)"),
                    fraction: Double(index) / Double(chunks.count)
                )
            }
            do {
                let refined = try await llmClient.refineTranscript(
                    rawText: chunk,
                    model: model,
                    attendees: attendees,
                    vocabulary: vocabulary
                )
                let cleaned = MapReduceSummarizer.stripThinking(refined)
                guard Self.isPlausibleRefinement(original: chunk, refined: cleaned) else {
                    Self.logger.warning("Refined chunk \(index) looked truncated; keeping original text")
                    refinedParts.append(chunk)
                    continue
                }
                refinedParts.append(cleaned)
            } catch {
                Self.logger.warning("Transcript cleanup failed, using raw transcript: \(error.localizedDescription)")
                progress.warn(String(localized: "Transcript cleanup failed; the summary uses the raw transcript."))
                // Keep what was refined so far and use the raw text for the rest.
                refinedParts.append(contentsOf: chunks[index...])
                break
            }
        }
        return refinedParts.joined(separator: "\n")
    }

    /// A cleanup pass should keep roughly the same amount of text.
    nonisolated static func isPlausibleRefinement(original: String, refined: String) -> Bool {
        let refinedTrimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refinedTrimmed.isEmpty else { return false }
        // Too short: the model summarised. Too long: a runaway answer (seen on
        // Apple Intelligence, which turned 2.5K words into 7.7K).
        let ratio = Double(refinedTrimmed.count) / Double(max(1, original.count))
        return ratio >= 0.5 && ratio <= 1.6
    }

    private func effectiveTranscript(for meeting: Meeting, preserveUserEdits: Bool) -> String {
        guard preserveUserEdits else { return meeting.refinedTranscript }
        let edited = meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? meeting.refinedTranscript : edited
    }

    /// Builds sections from a legacy flat markdown summary so it can sit under the user's notes.
    nonisolated static func structuredFromFlat(_ response: MeetingSummaryResponse) -> StructuredSummary? {
        let flat = response.flatSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        var sections: [StructuredSummary.SummarySection] = []
        var heading = String(localized: "Summary")
        var bullets: [StructuredSummary.SummaryBullet] = []
        for raw in flat.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                if !bullets.isEmpty { sections.append(.init(heading: heading, bullets: bullets)) }
                heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                bullets = []
            } else {
                let text = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
                bullets.append(.init(text: text))
            }
        }
        if !bullets.isEmpty { sections.append(.init(heading: heading, bullets: bullets)) }
        return StructuredSummary(
            title: response.title,
            sections: sections,
            decisions: response.decisions,
            actionItems: response.actionItems.map {
                .init(title: $0.title, assignee: $0.assignee, deadline: $0.deadline, sourceQuote: $0.sourceQuote)
            }
        )
    }

    // MARK: - Action items

    /// Deletes untouched AI items, keeps everything the user owns, and adds the new AI
    /// items that don't duplicate a kept one. Returns the newly added items.
    @discardableResult
    func replaceAIActionItems(
        in meeting: Meeting,
        with newItems: [MeetingSummaryResponse.ActionItemResponse]
    ) -> [ActionItem] {
        let replaceable = meeting.actionItems.filter(\.isUntouchedAIItem)
        for item in replaceable {
            meeting.actionItems.removeAll { $0.id == item.id }
            modelContext.delete(item)
        }

        var seen = Set(meeting.actionItems.map { ActionItem.normalizedTitle($0.title) })
        var added: [ActionItem] = []
        for item in newItems {
            let key = ActionItem.normalizedTitle(item.title)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            let actionItem = ActionItem(title: item.title, assignee: item.assignee, deadline: item.deadline)
            actionItem.sourceQuote = item.sourceQuote
            // Stamp now, before any await: a user edit made while later LLM calls run
            // must count as the user's, not become the "untouched AI" fingerprint.
            actionItem.markAsAIGenerated()
            meeting.actionItems.append(actionItem)
            added.append(actionItem)
        }
        actionItemChanges[meeting.id, default: ActionItemChanges()].removed.formUnion(replaceable.map(\.id))
        actionItemChanges[meeting.id, default: ActionItemChanges()].inserted.formUnion(added.map(\.id))
        return added
    }

    private func detectDestinations(items: [ActionItem], model: String, in context: ModelContext) async {
        let itemIDs = items.map(\.id)
        let itemList = items.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let prompt = """
        For each action item below, suggest a destination:
        - "clickup" for tasks, tickets, bugs, feature requests
        - "notion" for documentation, notes, meeting records
        - "reminder" for personal follow-ups, reminders
        - "n8n" for complex workflows requiring automation
        - "none" if no specific destination fits

        Respond with ONLY a JSON array of strings, one per item, in order.
        Example: ["clickup", "reminder", "none"]

        Action items:
        \(itemList)
        """

        do {
            let response = try await llmClient.chat(
                messages: [LLMChatMessage(role: "user", content: prompt)],
                model: model,
                format: .json
            )
            let cleaned = MapReduceSummarizer.stripThinking(response)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = cleaned.data(using: .utf8),
               let destinations = try? JSONDecoder().decode([String].self, from: data) {
                let validDestinations: Set<String> = ["clickup", "notion", "reminder", "n8n", "none"]
                for (index, itemID) in itemIDs.enumerated() where index < destinations.count {
                    // Re-fetched: the user or the MCP inbox may have deleted it meanwhile.
                    guard let item = LiveModel.actionItem(itemID, in: context) else { continue }
                    let dest = destinations[index].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if validDestinations.contains(dest) {
                        item.suggestedDestination = dest
                    }
                }
            }
        } catch {
            // Non-fatal: items just won't have suggestions
        }
    }

    /// Extracts action items the user wrote in their notes. Non-fatal.
    private func extractNoteActionItems(meeting: Meeting, model: String, glossary: String = "") async -> [ActionItem] {
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        do {
            let response = try await llmClient.chat(
                messages: [
                    .init(role: "system", content: """
                        You are analyzing meeting notes written by the user during a meeting. \
                        Extract any action items, TODOs, follow-ups, or commitments mentioned in the notes.

                        Respond with ONLY a JSON object:
                        {"action_items": [{"title": "...", "assignee": null, "deadline": null}]}

                        Rules:
                        - Only extract clear action items (not vague observations)
                        - assignee and deadline can be null if not specified
                        - Return an empty array if nothing found
                        """ + (glossary.isEmpty ? "" : "\n- " + glossary)),
                    .init(role: "user", content: """
                        Meeting: \(meeting.title)

                        User's notes:
                        \(meeting.notes)
                        """),
                ],
                model: model,
                format: .json
            )

            let cleaned = MapReduceSummarizer.stripThinking(response)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard LiveModel.meetingExists(meetingID, in: home),
                  let data = cleaned.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(NotesExtractionResult.self, from: data) else { return [] }

            var seen = Set(meeting.actionItems.map { ActionItem.normalizedTitle($0.title) })
            var added: [ActionItem] = []
            for item in parsed.action_items {
                let key = ActionItem.normalizedTitle(item.title)
                let isDuplicate = key.isEmpty || seen.contains(key) || meeting.actionItems.contains { existing in
                    existing.title.localizedCaseInsensitiveContains(String(item.title.prefix(20)))
                }
                guard !isDuplicate else { continue }
                seen.insert(key)
                let actionItem = ActionItem(title: item.title, assignee: item.assignee, deadline: item.deadline)
                actionItem.sourceQuote = "From notes"
                actionItem.markAsAIGenerated() // stamp at creation; see replaceAIActionItems
                meeting.actionItems.append(actionItem)
                added.append(actionItem)
            }
            actionItemChanges[meeting.id, default: ActionItemChanges()].inserted.formUnion(added.map(\.id))
            return added
        } catch {
            return []
        }
    }
}

private struct NotesExtractionResult: Decodable {
    struct NoteActionItem: Decodable {
        let title: String
        let assignee: String?
        let deadline: String?
    }
    let action_items: [NoteActionItem]
}
