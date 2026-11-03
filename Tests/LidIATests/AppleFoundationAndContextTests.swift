import Testing
import Foundation
@testable import LidIA

@Suite("On-device context fitting and Apple Foundation Models helpers")
struct AppleFoundationAndContextTests {

    // MARK: - TextChunker

    @Test("Short text is a single chunk")
    func shortText() {
        #expect(TextChunker.chunks("hello world", maxCharacters: 100) == ["hello world"])
        #expect(TextChunker.chunks("", maxCharacters: 100).isEmpty)
    }

    @Test("Chunks never exceed the limit and keep all words")
    func chunksRespectLimit() {
        let paragraph = (0..<40).map { "Sentence number \($0) has some words." }.joined(separator: " ")
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let chunks = TextChunker.chunks(text, maxCharacters: 300)
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.count <= 300 })
        let originalWords = text.split(whereSeparator: \.isWhitespace)
        let chunkWords = chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace)
        #expect(originalWords == chunkWords)
    }

    @Test("A single huge word is hard-split")
    func hugeWord() {
        let text = String(repeating: "x", count: 1000)
        let chunks = TextChunker.chunks(text, maxCharacters: 128)
        #expect(chunks.allSatisfy { $0.count <= 128 })
        #expect(chunks.joined() == text)
    }

    // MARK: - ContextFitter

    private func fitter(context: Int, reserved: Int, calls: CallCounter) -> ContextFitter {
        ContextFitter(
            contextTokens: context,
            reservedOutputTokens: reserved,
            countTokens: { TokenEstimate.estimate($0) },
            condense: { chunk, _, _ in
                await calls.increment()
                // Condense to about a fifth of the chunk.
                return String(chunk.prefix(max(1, chunk.count / 5)))
            }
        )
    }

    @Test("Messages that fit are untouched")
    func fitsUntouched() async throws {
        let calls = CallCounter()
        let messages = [
            LLMChatMessage(role: "system", content: "Summarise."),
            LLMChatMessage(role: "user", content: "A short transcript."),
        ]
        let fitted = try await fitter(context: 4096, reserved: 1000, calls: calls).fit(messages)
        #expect(fitted.map(\.content) == messages.map(\.content))
        #expect(await calls.value == 0)
    }

    @Test("A one-hour transcript is condensed to fit a 4K window")
    func longTranscriptCondensed() async throws {
        let calls = CallCounter()
        let line = "**Ana:** We agreed to ship the beta on Friday and Luis owns the release notes."
        let transcript = Array(repeating: line, count: 600).joined(separator: "\n")  // ~48K chars
        let messages = [
            LLMChatMessage(role: "system", content: "You are a meeting note assistant."),
            LLMChatMessage(role: "user", content: transcript),
        ]
        let fitted = try await fitter(context: 4096, reserved: 1200, calls: calls).fit(messages)
        let total = fitted.map { TokenEstimate.estimate($0.content) + ContextFitter.perMessageOverhead }.reduce(0, +)
        #expect(total <= 4096 - 1200)
        #expect(fitted[0].content == messages[0].content)
        #expect(await calls.value > 1)
    }

    @Test("When the other messages already fill the window, it fails clearly")
    func impossibleFit() async {
        let calls = CallCounter()
        let messages = [
            LLMChatMessage(role: "system", content: String(repeating: "a", count: 12_000)),
            LLMChatMessage(role: "user", content: String(repeating: "b", count: 12_000)),
        ]
        do {
            _ = try await fitter(context: 4096, reserved: 1200, calls: calls).fit(messages)
            Issue.record("Expected contextLengthExceeded")
        } catch let error as LLMError {
            guard case .contextLengthExceeded = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    // MARK: - Apple FM helpers

    @Test("System messages become instructions; history is folded into the prompt")
    func splitMessages() {
        let (instructions, prompt) = AppleFoundationClient.split([
            LLMChatMessage(role: "system", content: "Be brief."),
            LLMChatMessage(role: "user", content: "Hi"),
            LLMChatMessage(role: "assistant", content: "Hello"),
            LLMChatMessage(role: "user", content: "What did we decide?"),
        ])
        #expect(instructions == "Be brief.")
        #expect(prompt.contains("User: Hi"))
        #expect(prompt.contains("Assistant: Hello"))
        #expect(prompt.hasSuffix("User: What did we decide?"))
    }

    @Test("Meeting summary prompts are detected for guided generation")
    func detectsSummaryPrompt() {
        let summaryPrompt = MeetingTemplate.general.systemPrompt
        #expect(AppleFoundationClient.isMeetingSummaryRequest([LLMChatMessage(role: "system", content: summaryPrompt)]))
        #expect(!AppleFoundationClient.isMeetingSummaryRequest([LLMChatMessage(role: "system", content: "Return {\"template\": \"...\"}")]))
    }

    @Test("Guided summary encodes to JSON the pipeline decodes")
    func guidedSummaryJSON() throws {
        let summary = AppleFMSummary(
            title: "Beta launch",
            summary: "The team agreed to ship the beta.",
            sections: [AppleFMSection(heading: "Launch", bullets: ["Beta ships Friday"])],
            decisions: ["Ship the beta on Friday"],
            actionItems: [
                AppleFMActionItem(title: "Write release notes", assignee: "Luis", deadline: "Friday", sourceQuote: "I'll do the notes"),
                AppleFMActionItem(title: "Book a room", assignee: "", deadline: "", sourceQuote: ""),
            ]
        )
        let json = try summary.meetingSummaryJSON()
        let decoded = try JSONDecoder().decode(MeetingSummaryResponse.self, from: Data(json.utf8))
        #expect(decoded.title == "Beta launch")
        #expect(decoded.decisions == ["Ship the beta on Friday"])
        #expect(decoded.actionItems.count == 2)
        #expect(decoded.actionItems[0].assignee == "Luis")
        #expect(decoded.actionItems[1].assignee == nil)
        #expect(decoded.toStructured()?.sections.first?.bullets.first?.text == "Beta ships Friday")
    }

    @Test("Fences are stripped from JSON answers")
    func stripFences() {
        #expect(AppleFoundationClient.stripFences("```json\n{\"a\":1}\n```") == "{\"a\":1}")
        #expect(AppleFoundationClient.stripFences("{\"a\":1}") == "{\"a\":1}")
    }
}

actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
