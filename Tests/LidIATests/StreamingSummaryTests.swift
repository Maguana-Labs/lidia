import Foundation
import SwiftData
import Testing
@testable import LidIA

/// Streams a fixed markdown summary in chunks and records what the progress
/// center showed partway through.
actor StreamProbeClient: LLMClient {
    let chunks: [String]
    let center: ProcessingProgressCenter
    var meetingID: UUID?
    private(set) var midStreamText: String?
    private(set) var factsCalls = 0
    private(set) var streamCalls = 0
    /// Fail the first stream after one chunk with a retryable error.
    let failFirstStream: Bool

    init(chunks: [String], center: ProcessingProgressCenter, failFirstStream: Bool = false) {
        self.chunks = chunks
        self.center = center
        self.failFirstStream = failFirstStream
    }

    func setMeetingID(_ id: UUID) { meetingID = id }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        let system = messages.first { $0.role == "system" }?.content ?? ""
        if system.hasPrefix(SummaryPrompts.factsMarker) {
            factsCalls += 1
            return #"{"title": "Launch plan", "decisions": [], "action_items": []}"#
        }
        if case .json = format { return "[]" }
        return ""
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        streamCalls += 1
        let attempt = streamCalls
        let chunks = self.chunks
        let fail = failFirstStream && attempt == 1
        return AsyncThrowingStream { continuation in
            Task {
                for (index, chunk) in chunks.enumerated() {
                    continuation.yield(chunk)
                    // Let the consumer run, then look at what the UI would show.
                    try? await Task.sleep(for: .milliseconds(20))
                    if fail {
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                        return
                    }
                    if index == 1 { await self.recordMidStream() }
                }
                continuation.finish()
            }
        }
    }

    private func recordMidStream() async {
        guard let meetingID else { return }
        let center = self.center
        // Wait (bounded) for the consumer to publish the first two chunks.
        for _ in 0..<300 {
            let text = await MainActor.run { center.streamingSummary[meetingID] }
            if let text, text.contains("QA signs off") {
                midStreamText = text
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func listModels() async throws -> [String] { ["probe"] }
}

@MainActor
@Suite("Streaming summary")
struct StreamingSummaryTests {
    private let markdownChunks = [
        "```markdown\n### Launch",
        " timeline\n- Ship on **June 3**\n  - QA signs off first\n",
        "- Decided: no beta\n\n### Next Steps\n- Ana: book the venue (by Friday)\n- Team: draft the post\n```",
    ]

    @Test func summaryTextStreamsToProgressCenterAndIsSavedVerbatim() async throws {
        let context = try makeInMemoryContext()
        let center = ProcessingProgressCenter()
        let words = makeWords([(true, "we ship on june third after qa"), (false, "ana will book the venue by friday")])
        let meeting = Meeting(title: "", rawTranscript: words, status: .processing)
        context.insert(meeting)
        let client = StreamProbeClient(chunks: markdownChunks, center: center)
        await client.setMeetingID(meeting.id)
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: center)

        try await pipeline.process(meeting: meeting, model: "m")

        // Partial text was visible while the model was still writing, without the fence.
        let mid = try #require(await client.midStreamText)
        #expect(mid.hasPrefix("### Launch timeline"))
        #expect(!mid.contains("```"))
        #expect(!mid.contains("Next Steps"))
        // Cleared once the summary is saved.
        #expect(center.streamingSummary[meeting.id] == nil)

        #expect(meeting.status == .complete)
        #expect(meeting.summary.hasPrefix("### Launch timeline\n- Ship on **June 3**\n  - QA signs off first"))
        #expect(!meeting.summary.contains("```"))
        #expect(meeting.title == "Launch plan")
        let items = meeting.actionItems.sorted { $0.title < $1.title }
        #expect(items.map(\.title) == ["Book the venue", "Draft the post"])
        #expect(items.first?.assignee == "Ana")
        #expect(items.first?.deadline == "by Friday")
        let structured = try #require(meeting.structuredSummary.flatMap { try? JSONDecoder().decode(StructuredSummary.self, from: $0) })
        #expect(structured.sections.first?.heading == "Launch timeline")
        #expect(structured.decisions == ["no beta"])
        // Local client: facts are read from the finished summary, once.
        #expect(await client.factsCalls == 1)
    }

    @Test func retryResetsPartialText() async throws {
        let center = ProcessingProgressCenter()
        let client = StreamProbeClient(chunks: markdownChunks, center: center, failFirstStream: true)
        var received: [String] = []
        var resets = 0
        let summarizer = MapReduceSummarizer(client: client, model: "m", budget: .cloud)
        let result = try await summarizer.summarizeMarkdown(
            transcript: "Me: hello there",
            legend: nil,
            systemPrompt: "You write meeting notes in markdown.",
            onText: { received.append($0) },
            onReset: { resets += 1; received.removeAll() }
        )
        #expect(resets == 1)
        #expect(await client.streamCalls == 2)
        // After the reset, the UI holds exactly the second attempt, fence-free.
        #expect(received.joined() == result.markdown)
        #expect(result.markdown.hasPrefix("### Launch timeline"))
        #expect(result.markdown.hasSuffix("- Team: draft the post"))
        #expect(result.timeToFirstToken != nil)
    }

    @Test func customFreeFormTemplateKeepsJSONPath() async throws {
        let context = try makeInMemoryContext()
        let words = makeWords([(true, "let's raise the price by ten percent"), (false, "agreed I will send the deck tomorrow")])
        let meeting = Meeting(title: "", rawTranscript: words, status: .processing)
        context.insert(meeting)
        let client = ScriptedLLMClient()
        let custom = MeetingTemplate(name: "Mine", systemPrompt: "Return JSON with title, decisions and actionItems.")
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())
        try await pipeline.process(meeting: meeting, model: "m", template: custom)
        let call = try #require(await client.calls(.summarize).first)
        // The JSON summary prompt (brief variant for this short transcript), not the markdown one.
        #expect(!call.system.hasPrefix(SummaryPrompts.markdownSummaryMarker))
        #expect(call.system.contains("JSON"))
        #expect(meeting.title == "Pricing sync")
    }

    // MARK: Parsing

    @Test func nextStepsParseOwnerTaskAndDeadline() {
        let markdown = """
        ### Pricing
        - Raise list price 10%
        ### Next Steps
        - **Alex**: send the revised deck to Acme (by Monday)
          - include the EU numbers
        - Team: review churn data
        - Note: nothing else agreed
        """
        let items = SummaryMarkdownParser.nextSteps(in: markdown)
        #expect(items.map(\.title) == ["Send the revised deck to Acme", "Review churn data", "Note: nothing else agreed"])
        #expect(items[0].assignee == "Alex")
        #expect(items[0].deadline == "by Monday")
        #expect(items[1].assignee == nil)
    }

    @Test func sectionsKeepHeadingsAndFlattenNestedBullets() {
        let sections = SummaryMarkdownParser.sections(in: "Here are the notes:\n## A\n- one\n  - two\n**B**\n- three")
        #expect(sections.map(\.heading) == ["A", "B"])
        #expect(sections[0].bullets.map(\.text) == ["one", "two"])
    }

    @Test func factsParseToleratesFencesAndNulls() throws {
        let facts = try #require(MeetingFactsExtractor.parse("""
        ```json
        {"title": " Budget review ", "decisions": ["Cap at 40k"], "action_items": [{"title": "Send invoice", "assignee": "null", "deadline": ""}]}
        ```
        """))
        #expect(facts.title == "Budget review")
        #expect(facts.decisions == ["Cap at 40k"])
        #expect(facts.actionItems.first?.assignee == nil)
        #expect(facts.actionItems.first?.deadline == nil)
        #expect(MeetingFactsExtractor.parse("not json") == nil)
    }

    @Test func streamCleanerDropsLeadingFenceOnly() {
        var cleaner = MarkdownStreamCleaner()
        let out = cleaner.consume("``") + cleaner.consume("`md\n### A") + cleaner.consume("\n- b\n``") + cleaner.consume("`") + cleaner.finish()
        #expect(out == "### A\n- b")
        var plain = MarkdownStreamCleaner()
        #expect(plain.consume("### A") + plain.consume(" `code`") + plain.consume(" ok") + plain.finish() == "### A `code` ok")
        var tail = MarkdownStreamCleaner()
        #expect(tail.consume("x `y`") + tail.finish() == "x `y`")
    }

    // MARK: Routing

    @Test func vocabularyIsAppliedWithoutAnLLM() {
        let vocabulary = [AppSettings.VocabularyEntry(heardAs: "taper", replaceTo: "TAPR")]
        let fixed = VocabularyCorrector.apply(vocabulary, to: "Them: the Taper call; tapers are fine")
        #expect(fixed == "Them: the TAPR call; tapers are fine")
    }

    @Test func onlyHostedProvidersRunFactsConcurrently() {
        #expect(PipelineClientFactory.canRunConcurrently(AnthropicClient(apiKey: "k")))
        #expect(PipelineClientFactory.canRunConcurrently(OpenAIClient(apiKey: "k")))
        #expect(!PipelineClientFactory.canRunConcurrently(
            OpenAIClient(apiKey: "k", baseURL: URL(string: "http://localhost:1234/v1")!)
        ))
        #expect(!PipelineClientFactory.canRunConcurrently(ScriptedLLMClient()))
    }

    @Test func glossaryReachesTheSummaryAndFactsPrompts() async throws {
        let context = try makeInMemoryContext()
        let words = makeWords([(true, "the taper review is next week with north wind"), (false, "I will send the taper report")])
        let meeting = Meeting(title: "", rawTranscript: words, status: .processing, notes: "send report")
        context.insert(meeting)
        let client = ScriptedLLMClient()
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: ProcessingProgressCenter())
        let vocabulary = [AppSettings.VocabularyEntry(heardAs: "taper", replaceTo: "TAPR"),
                          AppSettings.VocabularyEntry(heardAs: "north wind", replaceTo: "Northwind")]

        try await pipeline.process(meeting: meeting, model: "m", vocabulary: vocabulary)

        let block = PersonalGlossary.promptBlock(vocabulary)
        #expect(block.contains("TAPR") && block.contains("Northwind"))
        #expect(try #require(await client.calls(.summarize).first).system.contains(block))
        #expect(try #require(await client.calls(.facts).first).system.contains(block))
        #expect(try #require(await client.calls(.notesActions).first).system.contains(block))
        // The transcript itself is corrected without an LLM.
        #expect(meeting.refinedTranscript.contains("TAPR review"))
    }

    @Test func claudeEffortIsMediumForSummariesAndLowForSmallSteps() {
        let summary: [LLMChatMessage] = [.init(role: "system", content: SummaryPrompts.markdownSummaryMarker + "."), .init(role: "user", content: "t")]
        let facts: [LLMChatMessage] = [.init(role: "system", content: SummaryPrompts.factsSystemPrompt), .init(role: "user", content: "n")]
        let prep: [LLMChatMessage] = [.init(role: "user", content: "You are a meeting prep assistant. …")]
        #expect(AnthropicClient.effort(for: summary, streaming: true) == "medium")
        #expect(AnthropicClient.effort(for: facts, streaming: false) == "low")
        #expect(AnthropicClient.effort(for: prep, streaming: false) == "low")
        #expect(AnthropicClient.effort(for: [.init(role: "user", content: "hi")], streaming: true) == "low")
    }

    @Test func mlxBudgetFollowsTheModelsContextCap() {
        #expect(SummarizationBudget.mlxBudget(modelID: "mlx-community/Qwen3.6-35B-A3B-4bit").contextTokens == 131_072)
        #expect(SummarizationBudget.mlxBudget(modelID: "unknown/model").contextTokens == MLXLocalClient.defaultContextCap)
    }
}
