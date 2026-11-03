import Foundation
import SQLite3
import SwiftData
import Testing
@testable import LidIA

@MainActor
@Suite("Pipeline reliability")
struct PipelineReliabilityTests {
    private func makeMeeting(in context: ModelContext, words: [TranscriptWord], notes: String = "", status: MeetingStatus = .processing) -> Meeting {
        let meeting = Meeting(title: "", rawTranscript: words, status: status, notes: notes)
        context.insert(meeting)
        try? context.save()
        return meeting
    }

    private var shortConversation: [TranscriptWord] {
        makeWords([(true, "let's raise the price by ten percent"), (false, "agreed I will send the deck tomorrow")])
    }

    // MARK: Graceful degradation

    @Test func emptyTranscriptFailsWithClearErrorInsteadOfStaying() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: [])
        let center = ProcessingProgressCenter()
        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: center)

        await #expect(throws: PipelineError.emptyTranscript) {
            try await pipeline.process(meeting: meeting, model: "m")
        }
        #expect(meeting.status == .failed)
        #expect(meeting.processingError?.contains("No speech was captured") == true)
        #expect(center.progress(for: meeting.id) == nil)
    }

    @Test func refineFailureStillSummarisesRawTranscript() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation)
        let client = ScriptedLLMClient(failing: [.refine])
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        #expect(meeting.status == .complete)
        #expect(meeting.processingError == nil)
        #expect(meeting.refinedTranscript.hasPrefix("Me: let's raise the price"))
        #expect(meeting.summary.contains("Discussed pricing"))
        #expect(meeting.title == "Pricing sync")
        #expect(meeting.actionItems.map(\.title) == ["Send deck"])
        #expect(meeting.actionItems.allSatisfy { $0.isUntouchedAIItem })
    }

    @Test func summaryFailureMarksFailedAndThrows() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation)
        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(failing: [.summarize]), modelContext: context, progressCenter: ProcessingProgressCenter())

        await #expect(throws: (any Error).self) {
            try await pipeline.process(meeting: meeting, model: "m")
        }
        #expect(meeting.status == .failed)
        #expect(meeting.processingError?.hasPrefix("Summary generation failed") == true)
    }

    @Test func speakerLabelsReachTheModel() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation)
        let client = ScriptedLLMClient()
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        let summarize = try #require(await client.calls(.summarize).first)
        #expect(summarize.user.contains("Me: let's raise the price"))
        #expect(summarize.user.contains("Them: agreed I will send the deck"))
        #expect(summarize.user.contains("SPEAKER LABELS"))
    }

    // MARK: Long meetings

    @Test func longMeetingIsSummarisedMapReduceAndFullyCovered() async throws {
        let context = try makeInMemoryContext()
        var turns: [(local: Bool?, text: String)] = []
        for i in 0..<200 {
            turns.append((i.isMultiple(of: 2), "turn \(i) we covered the roadmap budget hiring and pricing for next quarter marker\(i)x"))
        }
        let meeting = makeMeeting(in: context, words: makeWords(turns))
        let client = ScriptedLLMClient()
        let budget = SummarizationBudget(contextTokens: 1200, reservedTokens: 700)
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, budget: budget, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        #expect(meeting.status == .complete)
        let maps = await client.calls(.map)
        #expect(maps.count > 1)
        // Every map request fits the budget.
        for call in maps {
            #expect(TokenEstimator.estimate(call.user) <= budget.inputTokens)
        }
        // The first and last turns were both sent to the model.
        #expect(maps.contains { $0.user.contains("marker0x") })
        #expect(maps.contains { $0.user.contains("marker199x") })
        // The final summary call is the reduce step and fits the budget.
        let summarize = try #require(await client.calls(.summarize).last)
        #expect(summarize.user.contains("too long to process at once"))
        #expect(summarize.user.contains("marker199x"))
        #expect(TokenEstimator.estimate(summarize.user) <= budget.inputTokens + 100)
        // The LLM cleanup pass is off by default; the transcript keeps every turn.
        #expect(await client.calls(.refine).isEmpty)
        #expect(meeting.refinedTranscript.contains("marker199x"))
    }

    @Test func optionalLLMRefineStillRunsPerChunk() async throws {
        let context = try makeInMemoryContext()
        var turns: [(local: Bool?, text: String)] = []
        for i in 0..<200 {
            turns.append((i.isMultiple(of: 2), "turn \(i) we covered the roadmap budget hiring and pricing for next quarter marker\(i)x"))
        }
        let meeting = makeMeeting(in: context, words: makeWords(turns))
        let client = ScriptedLLMClient()
        let budget = SummarizationBudget(contextTokens: 1200, reservedTokens: 700)
        let pipeline = MeetingPipeline(
            llmClient: client, modelContext: context, budget: budget,
            progressCenter: ProcessingProgressCenter(), refineWithLLM: true
        )

        try await pipeline.process(meeting: meeting, model: "m")

        #expect(await client.calls(.refine).count > 1)
        #expect(meeting.refinedTranscript.contains("marker199x"))
    }

    @Test func summaryNeverExceedsBudgetWhenCondensingStalls() async throws {
        var turns: [(local: Bool?, text: String)] = []
        for i in 0..<400 {
            turns.append((i.isMultiple(of: 2), "turn \(i) we covered the roadmap budget hiring and pricing for next quarter marker\(i)x"))
        }
        let transcript = MeetingPipeline.buildLabeledTranscript(from: makeWords(turns))
        let client = ScriptedLLMClient(condenseReturnsInput: true)
        let budget = SummarizationBudget(contextTokens: 1200, reservedTokens: 700)
        let sink = WarningSink()
        let summarizer = MapReduceSummarizer(
            client: client, model: "m", budget: budget,
            onWarning: { sink.messages.append($0) }
        )

        let result = try await summarizer.summarize(transcript: transcript, legend: nil, template: nil, attendees: nil)

        #expect(result.truncated)
        #expect(sink.messages.count == 1)
        // Condensing stopped once it stopped shrinking, well before the depth bound.
        #expect(await client.calls(.condense).count < 100)
        let summarize = try #require(await client.calls(.summarize).last)
        #expect(TokenEstimator.estimate(summarize.user) <= budget.inputTokens)
        #expect(summarize.user.contains("omitted to fit"))
        // Start and end of the meeting survive truncation.
        #expect(summarize.user.contains("Part 1 of"))
        #expect(summarize.user.contains("marker399x"))
        for call in await client.calls(.condense) {
            #expect(TokenEstimator.estimate(call.user) <= budget.inputTokens)
        }
    }

    @Test func truncateToFitAlwaysFits() {
        let text = String(repeating: "word another longer-token ", count: 2000)
        for limit in [20, 64, 300, 1500] {
            let cut = MapReduceSummarizer.truncateToFit(text, maxTokens: limit)
            #expect(TokenEstimator.estimate(cut) <= limit)
        }
        #expect(MapReduceSummarizer.truncateToFit("short", maxTokens: 100) == "short")
    }

    // MARK: Notes-first summaries

    @Test func userNotesAreKeptWithAIDetailUnderneath() async throws {
        let context = try makeInMemoryContext()
        let notes = "# Pricing\n- raise price 10%\n- annual discount"
        let meeting = makeMeeting(in: context, words: shortConversation, notes: notes)
        let merge = """
            {"details": [{"point": 1, "bullets": [{"text": "Them agreed to the increase", "source_quote": "agreed"}]}],
             "other_sections": [{"heading": "Follow-ups", "bullets": [{"text": "Deck goes out tomorrow", "source_quote": null}]}]}
            """
        let client = ScriptedLLMClient(mergeJSON: merge)
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        let data = try #require(meeting.structuredSummary)
        let summary = try JSONDecoder().decode(StructuredSummary.self, from: data)
        #expect(summary.sections.first?.heading == "Pricing")
        let bullets = try #require(summary.sections.first?.bullets)
        #expect(bullets.map(\.text) == ["raise price 10%", "Them agreed to the increase", "annual discount"])
        #expect(bullets.map(\.fromUserNotes) == [true, false, true])
        #expect(summary.sections.last?.heading == "Follow-ups")
        #expect(summary.sections.last?.bullets.allSatisfy { !$0.fromUserNotes } == true)
        #expect(meeting.summary.contains("- raise price 10%\n  - Them agreed to the increase"))
        #expect(summary.decisions == ["Ship it"])
    }

    @Test func notesMergeFailureStillKeepsEveryUserPoint() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation, notes: "raise price\nask legal")
        let client = ScriptedLLMClient(failing: [.merge])
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        #expect(meeting.status == .complete)
        let summary = try JSONDecoder().decode(StructuredSummary.self, from: try #require(meeting.structuredSummary))
        let userPoints = summary.sections.flatMap(\.bullets).filter(\.fromUserNotes).map(\.text)
        #expect(userPoints == ["raise price", "ask legal"])
        // The AI summary follows the notes.
        #expect(summary.sections.contains { $0.heading == "Overview" })
    }

    @Test func notesOnlyMeetingIsSummarised() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: [], notes: "- decided to hire two engineers")
        let client = ScriptedLLMClient()
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        #expect(meeting.status == .complete)
        let summarize = try #require(await client.calls(.summarize).first)
        #expect(summarize.user.contains("decided to hire two engineers"))
    }

    // MARK: Regenerate

    private func seedCompletedMeeting(in context: ModelContext) -> (Meeting, untouched: ActionItem, completed: ActionItem, edited: ActionItem, manual: ActionItem) {
        let meeting = makeMeeting(in: context, words: shortConversation, status: .complete)
        meeting.summary = "Old summary"
        let untouched = ActionItem(title: "Old AI task")
        let completed = ActionItem(title: "AI task done")
        let edited = ActionItem(title: "AI task")
        let manual = ActionItem(title: "My own task")
        for item in [untouched, completed, edited, manual] {
            meeting.actionItems.append(item)
        }
        untouched.markAsAIGenerated()
        completed.markAsAIGenerated()
        edited.markAsAIGenerated()
        completed.isCompleted = true
        edited.title = "Send deck" // user renamed it to what the AI will suggest again
        try? context.save()
        return (meeting, untouched, completed, edited, manual)
    }

    @Test func regenerateKeepsUserTouchedItemsAndReplacesUntouchedOnes() async throws {
        let context = try makeInMemoryContext()
        let (meeting, untouched, completed, edited, manual) = seedCompletedMeeting(in: context)

        let impact = MeetingPipeline.regenerateImpact(for: meeting)
        #expect(impact.replacedAIItems == 1)
        #expect(impact.keptUserItems == 3)
        #expect(impact.requiresConfirmation == false)

        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: ProcessingProgressCenter())
        let snapshot = try await pipeline.regenerate(meeting: meeting, model: "m")

        let ids = Set(meeting.actionItems.map(\.id))
        #expect(!ids.contains(untouched.id))
        #expect(ids.isSuperset(of: [completed.id, edited.id, manual.id]))
        // "Send deck" from the AI is not duplicated because the user's edited item has that title.
        #expect(meeting.actionItems.filter { $0.title == "Send deck" }.count == 1)
        #expect(meeting.actionItems.count == 3)
        #expect(meeting.status == .complete)

        // Undo restores the exact previous set, including the replaced AI item.
        MeetingPipeline.undoRegenerate(snapshot, meeting: meeting, modelContext: context)
        let afterUndo: Set<UUID> = [untouched.id, completed.id, edited.id, manual.id]
        #expect(Set(meeting.actionItems.map(\.id)) == afterUndo)
        let restored = try #require(meeting.actionItems.first { $0.id == untouched.id })
        #expect(restored.isUntouchedAIItem)
        #expect(meeting.summary == "Old summary")
    }

    @Test func regenerateAddsNewAIItemsAndMarksThem() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation, status: .complete)
        let manual = ActionItem(title: "My own task")
        meeting.actionItems.append(manual)

        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: ProcessingProgressCenter())
        try await pipeline.regenerate(meeting: meeting, model: "m")

        #expect(Set(meeting.actionItems.map(\.title)) == ["My own task", "Send deck"])
        let ai = try #require(meeting.actionItems.first { $0.title == "Send deck" })
        #expect(ai.isUntouchedAIItem)
        #expect(manual.isUserOwned)
    }

    @Test func failedRegenerateRestoresCompletedMeeting() async throws {
        let context = try makeInMemoryContext()
        let (meeting, untouched, _, _, _) = seedCompletedMeeting(in: context)
        let before = Set(meeting.actionItems.map(\.id))

        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(failing: [.summarize]), modelContext: context, progressCenter: ProcessingProgressCenter())
        await #expect(throws: (any Error).self) {
            try await pipeline.regenerate(meeting: meeting, model: "m")
        }

        #expect(meeting.status == .complete)
        #expect(meeting.processingError == nil)
        #expect(meeting.summary == "Old summary")
        #expect(Set(meeting.actionItems.map(\.id)) == before)
        #expect(meeting.actionItems.contains { $0.id == untouched.id })
    }

    @Test func undoKeepsItemsTheUserAddedOrTouchedAfterRegenerate() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation, status: .complete)
        meeting.summary = "Old summary"
        let old = ActionItem(title: "Old AI task")
        meeting.actionItems.append(old)
        old.markAsAIGenerated()
        try? context.save()

        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: ProcessingProgressCenter())
        let snapshot = try await pipeline.regenerate(meeting: meeting, model: "m")
        let newAI = try #require(meeting.actionItems.first { $0.title == "Send deck" })
        #expect(snapshot.insertedActionItemIDs == [newAI.id])
        #expect(snapshot.removedActionItemIDs == [old.id])

        // After Regenerate the user completes the new AI item and adds one of their own.
        newAI.isCompleted = true
        let manual = ActionItem(title: "Book the room")
        meeting.actionItems.append(manual)

        MeetingPipeline.undoRegenerate(snapshot, meeting: meeting, modelContext: context)

        let restoredIDs: Set<UUID> = [old.id, newAI.id, manual.id]
        #expect(Set(meeting.actionItems.map(\.id)) == restoredIDs)
        #expect(meeting.summary == "Old summary")
    }

    @Test func undoStillRemovesUntouchedItemsRegenerateAdded() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation, status: .complete)
        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: ProcessingProgressCenter())
        let snapshot = try await pipeline.regenerate(meeting: meeting, model: "m")
        #expect(meeting.actionItems.map(\.title) == ["Send deck"])

        MeetingPipeline.undoRegenerate(snapshot, meeting: meeting, modelContext: context)
        #expect(meeting.actionItems.isEmpty)
    }

    @Test func failedRegenerateKeepsItemsAddedWhileTheLLMRan() async throws {
        let context = try makeInMemoryContext()
        let (meeting, _, _, _, _) = seedCompletedMeeting(in: context)
        let before = Set(meeting.actionItems.map(\.id))
        let hook = ChatHook()
        var typed: ActionItem?
        hook.on(.summarize) {
            // The user types an item (or the MCP inbox / sync delivers one) mid-run.
            let item = ActionItem(title: "Typed during regenerate")
            meeting.actionItems.append(item)
            typed = item
        }
        let client = ScriptedLLMClient(failing: [.summarize], hook: hook)
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())

        await #expect(throws: (any Error).self) {
            try await pipeline.regenerate(meeting: meeting, model: "m")
        }

        let typedID = try #require(typed?.id)
        #expect(meeting.status == .complete)
        #expect(Set(meeting.actionItems.map(\.id)) == before.union([typedID]))
    }

    @Test func overwritingUserEditsRequiresConfirmation() throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation, status: .complete)
        meeting.userEditedSummary = "My edited summary"
        #expect(MeetingPipeline.regenerateImpact(for: meeting, overwriteUserEdits: true).requiresConfirmation)
        #expect(!MeetingPipeline.regenerateImpact(for: meeting, overwriteUserEdits: false).requiresConfirmation)
    }

    @Test func userEditedSummaryIsPreservedByDefault() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation, status: .complete)
        meeting.summary = "My edited summary"
        meeting.userEditedSummary = "My edited summary"

        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: ProcessingProgressCenter())
        try await pipeline.regenerate(meeting: meeting, model: "m")
        #expect(meeting.summary == "My edited summary")
    }

    // MARK: Provenance

    @Test func anyUserChangeMarksItemAsUserOwned() {
        let item = ActionItem(title: "Task")
        #expect(item.isUserOwned) // no fingerprint: user-created
        item.markAsAIGenerated()
        #expect(item.isUntouchedAIItem)
        item.suggestedDestination = "notion" // pipeline-set field does not count
        #expect(item.isUntouchedAIItem)
        item.priority = "high"
        #expect(item.isUserOwned)
        item.priority = "none"
        #expect(item.isUntouchedAIItem)
        item.reminderID = "R1" // exported to Reminders
        #expect(item.isUserOwned)
    }

    @Test func userEditDuringProcessingStaysUserOwned() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation)
        let hook = ChatHook()
        // The destination call runs after the AI item exists; the user renames it meanwhile.
        hook.on(.destinations) {
            meeting.actionItems.first { $0.title == "Send deck" }?.title = "Send the final deck"
        }
        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(hook: hook), modelContext: context, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "m")

        let item = try #require(meeting.actionItems.first { $0.title == "Send the final deck" })
        #expect(item.isUserOwned)
        #expect(MeetingPipeline.regenerateImpact(for: meeting).replacedAIItems == 0)

        // A later Regenerate keeps the edited item.
        try await pipeline.regenerate(meeting: meeting, model: "m")
        #expect(meeting.actionItems.contains { $0.id == item.id })
    }

    // MARK: Progress

    @Test func progressStagesAdvance() {
        let progress = MeetingProcessingProgress(meetingID: UUID())
        #expect(ProcessingStage.allCases.allSatisfy { progress.state(of: $0) == .pending })
        progress.begin(.summarizing)
        #expect(progress.state(of: .transcribing) == .skipped)
        #expect(progress.state(of: .speakers) == .skipped)
        #expect(progress.state(of: .summarizing) == .active)
        progress.update(detail: "part 1 of 2", fraction: 0.5)
        #expect(progress.detail == "part 1 of 2")
        progress.begin(.actionItems)
        #expect(progress.state(of: .summarizing) == .done)
        progress.finish()
        #expect(progress.state(of: .actionItems) == .done)
        #expect(progress.isFinished)
        #expect(progress.overallFraction == 1)
    }

    @Test func successfulProcessingClearsProgress() async throws {
        let context = try makeInMemoryContext()
        let meeting = makeMeeting(in: context, words: shortConversation)
        let center = ProcessingProgressCenter()
        let pipeline = MeetingPipeline(llmClient: ScriptedLLMClient(), modelContext: context, progressCenter: center)
        try await pipeline.process(meeting: meeting, model: "m")
        #expect(center.progress(for: meeting.id) == nil)
    }

    @Test func refinementPlausibilityGuard() {
        #expect(MeetingPipeline.isPlausibleRefinement(original: "a b c d e f", refined: "A b c d e f."))
        #expect(!MeetingPipeline.isPlausibleRefinement(original: String(repeating: "word ", count: 100), refined: "Summary."))
        #expect(!MeetingPipeline.isPlausibleRefinement(original: "abc", refined: "  "))
    }
}

// MARK: - Crash recovery

@MainActor
@Suite("Processing recovery")
struct ProcessingRecoveryTests {
    private func makeQueue() -> DeferredMeetingProcessingQueue {
        let suite = "lidia.tests.queue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return DeferredMeetingProcessingQueue(defaults: defaults)
    }

    @Test func interruptedMeetingsAreEnqueuedAndEmptyOnesFail() async throws {
        let context = try makeInMemoryContext()
        let queue = makeQueue()

        let interrupted = Meeting(title: "A", rawTranscript: makeWords([(true, "hello world")]), status: .processing)
        let interruptedNotesOnly = Meeting(title: "B", status: .processing, notes: "- remember this")
        let empty = Meeting(title: "C", status: .processing)
        let alreadyQueued = Meeting(title: "D", rawTranscript: makeWords([(false, "hi")]), status: .queued)
        let done = Meeting(title: "E", rawTranscript: makeWords([(true, "done")]), status: .complete)
        for m in [interrupted, interruptedNotesOnly, empty, alreadyQueued, done] { context.insert(m) }
        try context.save()

        let report = await ProcessingRecovery.recover(in: context, queue: queue, progressCenter: ProcessingProgressCenter())

        #expect(Set(report.requeued) == [interrupted.id, interruptedNotesOnly.id, alreadyQueued.id])
        #expect(report.failed == [empty.id])
        #expect(interrupted.status == .queued)
        #expect(interruptedNotesOnly.status == .queued)
        #expect(alreadyQueued.status == .queued)
        #expect(empty.status == .failed)
        #expect(empty.processingError == ProcessingRecovery.interruptedNoTranscriptMessage)
        #expect(done.status == .complete)
        #expect(Set(await queue.all()) == [interrupted.id, interruptedNotesOnly.id, alreadyQueued.id])

        // Nothing is left in .processing.
        let processing = try context.fetch(FetchDescriptor<Meeting>()).filter { $0.status == .processing }
        #expect(processing.isEmpty)
    }

    @Test func meetingsProcessingInThisLaunchAreLeftAlone() async throws {
        let context = try makeInMemoryContext()
        let queue = makeQueue()
        let live = Meeting(title: "Live", rawTranscript: makeWords([(true, "hi")]), status: .processing)
        context.insert(live)
        try context.save()
        let center = ProcessingProgressCenter()
        center.start(meetingID: live.id)

        let report = await ProcessingRecovery.recover(in: context, queue: queue, progressCenter: center)

        #expect(report.requeued.isEmpty)
        #expect(live.status == .processing)
        #expect(await queue.all().isEmpty)
    }

    @Test func queueApiIsStable() async {
        let queue = makeQueue()
        let a = UUID(), b = UUID()
        await queue.enqueue(a)
        await queue.enqueue(b)
        await queue.enqueue(a)
        #expect(await queue.all() == [a, b])
        await queue.remove(a)
        #expect(await queue.all() == [b])
        await queue.clear()
        #expect(await queue.all().isEmpty)
    }

    @Test func drainAcceptsRecoveredStatuses() {
        #expect(PostProcessingService.drainableStatuses == [.queued, .processing, .recording])
    }
}

// MARK: - Store guardian

@Suite("Store guardian")
struct StoreGuardianTests {
    private func makeStore() throws -> (dir: URL, store: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("default.store")
        try Data("db".utf8).write(to: store)
        try Data("wal".utf8).write(to: dir.appendingPathComponent("default.store-wal"))
        try Data("shm".utf8).write(to: dir.appendingPathComponent("default.store-shm"))
        let support = dir.appendingPathComponent(".default_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: support.appendingPathComponent("blob1"))
        try Data("other".utf8).write(to: dir.appendingPathComponent("unrelated.txt"))
        return (dir, store)
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func storeFilesIncludeSidecarsAndExternalData() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = StoreGuardian.storeFiles(for: store).map(\.lastPathComponent)
        #expect(files == [".default_SUPPORT", "default.store", "default.store-shm", "default.store-wal"])
    }

    @Test func dailyBackupKeepsNewestThree() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for i in 0..<5 {
            let made = try StoreGuardian.makeDailyBackup(storeURL: store, backupsRoot: root, now: start + Double(i) * day)
            #expect(made != nil)
        }
        // Same day again: no new copy.
        #expect(try StoreGuardian.makeDailyBackup(storeURL: store, backupsRoot: root, now: start + 4 * day + 60) == nil)

        let backups = names(in: root)
        #expect(backups.count == 3)
        #expect(backups.allSatisfy { $0.hasPrefix("daily-") })
        let newest = root.appendingPathComponent(backups.last!)
        #expect(names(in: newest) == [".default_SUPPORT", "default.store", "default.store-shm", "default.store-wal"])
        // The live store is untouched.
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test func noBackupWhenThereIsNoStoreYet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try StoreGuardian.makeDailyBackup(storeURL: dir.appendingPathComponent("default.store"), backupsRoot: dir.appendingPathComponent("b"))
        #expect(made == nil)
    }

    @Test @MainActor func failingStoreIsMovedAsideNotDeleted() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        let fresh = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        var attempts = 0
        let result = StoreGuardian.openContainer(
            storeURL: store,
            backupsRoot: root,
            open: { url in
                attempts += 1
                // Fail while the old (corrupt) store is still there.
                if FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return fresh
            },
            openInMemory: { fresh }
        )

        #expect(attempts == 3)
        let notice = try #require(result.notice)
        #expect(!notice.isTemporaryLibrary)
        #expect(notice.message.contains(notice.backupPath))
        // Original files are in the recovered folder, byte for byte.
        let recovered = notice.backupURL
        #expect(recovered.lastPathComponent.hasPrefix("recovered-"))
        #expect(names(in: recovered) == [".default_SUPPORT", "default.store", "default.store-shm", "default.store-wal"])
        #expect(try Data(contentsOf: recovered.appendingPathComponent("default.store")) == Data("db".utf8))
        #expect(try Data(contentsOf: recovered.appendingPathComponent(".default_SUPPORT/_EXTERNAL_DATA/blob1")) == Data("blob".utf8))
        // A daily backup was also taken before opening.
        #expect(names(in: root).contains { $0.hasPrefix("daily-") })
        // Unrelated files are untouched.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("unrelated.txt").path))
    }

    private struct OpaqueOpenError: Error {}

    private func writeHealthySQLite(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        for sidecar in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + sidecar))
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE ZMEETING (Z_PK INTEGER PRIMARY KEY); INSERT INTO ZMEETING VALUES (1);", nil, nil, nil)
        sqlite3_close(db)
    }

    @Test @MainActor func incompatibleStoreIsLeftInPlace() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        let memory = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let before = names(in: dir)

        var attempts = 0
        // NSPersistentStoreIncompatibleVersionHashError: a newer build's library.
        let newerModel = NSError(
            domain: "SwiftData", code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 134_100)]
        )
        let result = StoreGuardian.openContainer(
            storeURL: store,
            backupsRoot: root,
            open: { _ in attempts += 1; throw newerModel },
            openInMemory: { memory }
        )

        #expect(attempts == 2)
        let notice = try #require(result.notice)
        #expect(notice.isTemporaryLibrary)
        #expect(notice.kind == .incompatible)
        #expect(notice.message.contains("couldn't open your library"))
        #expect(notice.backupPath == dir.path)
        // Nothing moved: the store and its sidecars are where they were.
        #expect(names(in: dir).filter { $0 != "backups" } == before)
        #expect(try Data(contentsOf: store) == Data("db".utf8))
        #expect(!names(in: root).contains { $0.hasPrefix("recovered-") })
    }

    @Test @MainActor func opaqueErrorOnHealthyDatabaseIsNotTreatedAsCorruption() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeHealthySQLite(at: store)
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        let memory = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        // SwiftData usually hides the underlying Core Data error.
        #expect(StoreGuardian.classify(OpaqueOpenError(), storeURL: store) == .incompatible)
        let result = StoreGuardian.openContainer(
            storeURL: store, backupsRoot: root,
            open: { _ in throw OpaqueOpenError() },
            openInMemory: { memory }
        )
        #expect(result.notice?.kind == .incompatible)
        #expect(LibraryLocation.isLidIAStore(at: store))
        #expect(!names(in: root).contains { $0.hasPrefix("recovered-") })
    }

    @Test func failedMoveAsideIsRolledBack() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        let before = names(in: dir)
        // The -wal is moved last; failing it must bring the others back.
        let failing = FailingMoveFileManager(failWhenMovingTo: "default.store-wal")

        #expect(throws: (any Error).self) {
            try StoreGuardian.moveStoreAside(storeURL: store, backupsRoot: root, fileManager: failing)
        }
        #expect(names(in: dir).filter { $0 != "backups" } == before)
        #expect(try Data(contentsOf: store) == Data("db".utf8))
        #expect(!names(in: root).contains { $0.hasPrefix("recovered-") })
    }

    @Test func moveAllOrNothingRefusesExistingDestination() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: dest.appendingPathComponent("default.store-wal"))
        let moves = StoreGuardian.storeFiles(for: store).map { (from: $0, to: dest.appendingPathComponent($0.lastPathComponent)) }

        #expect(throws: (any Error).self) {
            try StoreGuardian.moveAllOrNothing(moves)
        }
        // Nothing moved.
        #expect(names(in: dest) == ["default.store-wal"])
        #expect(StoreGuardian.storeFiles(for: store).count == 4)
    }

    @Test func classifiesCorruption() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Garbage bytes: SQLite says "not a database".
        #expect(StoreGuardian.classify(OpaqueOpenError(), storeURL: store) == .corrupt)
        // Explicit SQLITE_CORRUPT nested in the error chain.
        let nested = NSError(domain: "SwiftData", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 134_060, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: "NSSQLiteErrorDomain", code: 11),
            ]),
        ])
        try writeHealthySQLite(at: store)
        #expect(StoreGuardian.classify(nested, storeURL: store) == .corrupt)
        // A missing store with an opaque error is not corruption.
        #expect(StoreGuardian.classify(OpaqueOpenError(), storeURL: dir.appendingPathComponent("missing.store")) == .other)
    }

    @Test @MainActor func healthyStoreOpensWithoutNotice() throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let result = StoreGuardian.openContainer(
            storeURL: store,
            backupsRoot: dir.appendingPathComponent("backups"),
            open: { _ in fresh },
            openInMemory: { fresh }
        )
        #expect(result.notice == nil)
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test @MainActor func noticePersistsUntilDismissed() {
        let defaults = UserDefaults(suiteName: "lidia.tests.notice.\(UUID().uuidString)")!
        let notice = StoreRecoveryNotice(backupPath: "/tmp/x", date: Date(), reason: "corrupt", isTemporaryLibrary: false)
        StoreGuardian.saveNotice(notice, defaults: defaults)
        let health = LibraryHealth(defaults: defaults)
        #expect(health.recoveryNotice == notice)
        health.dismissRecoveryNotice()
        #expect(health.recoveryNotice == nil)
        #expect(LibraryHealth(defaults: defaults).recoveryNotice == nil)
    }
}
