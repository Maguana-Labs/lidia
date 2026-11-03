import Foundation
import SwiftData
import Testing
@testable import LidIA

/// A client with a small context window, like Apple Intelligence: any request
/// over `contextTokens` (system + user + answer reserve) fails the way Apple's
/// model does.
actor SmallContextClient: LLMClient {
    let contextTokens: Int
    let answerReserve: Int
    private(set) var requestSizes: [Int] = []
    private(set) var streamCalls = 0

    init(contextTokens: Int = 4096, answerReserve: Int = 900) {
        self.contextTokens = contextTokens
        self.answerReserve = answerReserve
    }

    private func check(_ messages: [LLMChatMessage]) throws {
        let size = messages.map { TokenEstimator.estimate($0.content) }.reduce(0, +)
        requestSizes.append(size)
        if size + answerReserve > contextTokens { throw LLMError.contextLengthExceeded }
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        try check(messages)
        let system = messages.first { $0.role == "system" }?.content ?? ""
        if system.hasPrefix(SummaryPrompts.factsMarker) { return #"{"title": "Weekly sync", "decisions": [], "action_items": []}"# }
        if case .json = format { return "[]" }
        return "- condensed notes"
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        streamCalls += 1
        do { try check(messages) } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return AsyncThrowingStream { continuation in
            continuation.yield("### Weekly sync\n")
            continuation.yield("- Roadmap reviewed\n")
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { ["small"] }
}

/// A model that never answers and ignores cancellation.
actor HangingClient: LLMClient {
    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        await Self.neverReturn()
        return ""
    }

    /// Suspends forever without using CPU and without reacting to cancellation.
    static func neverReturn() async {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { _ in } // never yields, never finishes
    }

    func listModels() async throws -> [String] { [] }
}

@MainActor
@Suite("Pipeline bounds")
struct PipelineBoundsTests {
    private func meeting(words: Int, in context: ModelContext) -> Meeting {
        let sentence = "we reviewed the roadmap budget hiring pricing and the launch plan for the quarter"
        var turns: [(local: Bool?, text: String)] = []
        var count = 0
        var index = 0
        while count < words {
            turns.append((index.isMultiple(of: 2), sentence + " marker\(index)x"))
            count += 16
            index += 1
        }
        let meeting = Meeting(title: "", rawTranscript: makeWords(turns), status: .processing)
        context.insert(meeting)
        return meeting
    }

    /// The 08:00 meeting: ~200 words on Apple Intelligence failed with
    /// "Context length exceeded" because the JSON prompt + schema + answer didn't fit.
    @Test func shortMeetingFitsASmallContext() async throws {
        let context = try makeInMemoryContext()
        let meeting = meeting(words: 200, in: context)
        let client = SmallContextClient()
        let budget = SummarizationBudget(contextTokens: 4096, reservedTokens: 2560)
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, budget: budget, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "apple-on-device")

        #expect(meeting.status == .complete)
        #expect(meeting.summary.contains("Roadmap reviewed"))
        #expect(await client.requestSizes.allSatisfy { $0 + 900 <= 4096 })
    }

    /// The 08:03 meeting: a long meeting on a 4K model must finish in a bounded
    /// number of calls, each of which fits.
    @Test func longMeetingOnASmallContextIsBoundedAndFits() async throws {
        let context = try makeInMemoryContext()
        let meeting = meeting(words: 20_000, in: context)
        let client = SmallContextClient()
        let budget = SummarizationBudget(contextTokens: 4096, reservedTokens: 2560)
        let center = ProcessingProgressCenter()
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, budget: budget, progressCenter: center)

        try await pipeline.process(meeting: meeting, model: "apple-on-device")

        #expect(meeting.status == .complete)
        let sizes = await client.requestSizes
        #expect(sizes.allSatisfy { $0 + 900 <= 4096 })
        // Map calls are capped; condense rounds and the final pass add a few more.
        #expect(sizes.count <= PipelineLimits.maxMapParts + 20)
        // The transcript is the speaker-labelled text, not an LLM rewrite of it.
        #expect(meeting.refinedTranscript.contains("marker0x"))
    }

    @Test func contextOverflowIsRetriedWithASmallerBudget() async throws {
        let context = try makeInMemoryContext()
        let meeting = meeting(words: 900, in: context)
        // The pipeline believes it has 4K; the model really fits far less.
        let client = SmallContextClient(contextTokens: 2400, answerReserve: 900)
        let budget = SummarizationBudget(contextTokens: 4096, reservedTokens: 2560)
        let pipeline = MeetingPipeline(llmClient: client, modelContext: context, budget: budget, progressCenter: ProcessingProgressCenter())

        try await pipeline.process(meeting: meeting, model: "apple-on-device")

        #expect(meeting.status == .complete)
        #expect(await client.streamCalls >= 2)
    }

    @Test func hungModelFailsWithAClearMessageAndKeepsTheTranscript() async throws {
        let context = try makeInMemoryContext()
        let meeting = meeting(words: 300, in: context)
        let center = ProcessingProgressCenter()
        let pipeline = MeetingPipeline(llmClient: HangingClient(), modelContext: context, progressCenter: center)
        pipeline.summaryTimeoutOverride = 0.3

        await #expect(throws: PipelineTimeoutError.self) {
            try await pipeline.process(meeting: meeting, model: "m")
        }
        #expect(meeting.status == .failed)
        #expect(meeting.processingError?.contains("took longer than") == true)
        #expect(meeting.refinedTranscript.contains("marker0x"))
        #expect(center.progress(for: meeting.id) == nil)
        #expect(center.streamingSummary[meeting.id] == nil)
    }

    @Test func deadlineReturnsEvenIfWorkIgnoresCancellation() async {
        let start = Date()
        await #expect(throws: PipelineTimeoutError.self) {
            try await withDeadline(seconds: 0.2, step: "test") { () async throws -> Int in
                await HangingClient.neverReturn()
                return 0
            }
        }
        #expect(Date().timeIntervalSince(start) < 5)
        let value = try? await withDeadline(seconds: 5, step: "test") { 42 }
        #expect(value == 42)
    }

    @Test func snapshotDeltasAreIncrementalAndUnicodeSafe() {
        var delta = StreamSnapshotDelta()
        #expect(delta.next("Hola") == "Hola")
        #expect(delta.next("Hola, qué") == ", qué")
        #expect(delta.next("Hola, qué tal 🇪🇸") == " tal 🇪🇸")
        #expect(delta.next("Hola, qué tal 🇪🇸") == "")
    }

    @Test func runawayRefinementIsRejected() {
        let original = String(repeating: "word ", count: 100)
        #expect(!MeetingPipeline.isPlausibleRefinement(original: original, refined: String(repeating: original, count: 3)))
        #expect(MeetingPipeline.isPlausibleRefinement(original: original, refined: original + "extra"))
    }
}
