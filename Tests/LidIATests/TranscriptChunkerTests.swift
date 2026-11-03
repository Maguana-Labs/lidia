import Foundation
import Testing
@testable import LidIA

@Suite("TranscriptChunker")
struct TranscriptChunkerTests {
    private func longTranscript(turns: Int) -> String {
        (0..<turns).map { i in
            let label = i.isMultiple(of: 2) ? "Me" : "Them"
            return "\(label): this is turn number \(i) where we talk about the roadmap and pricing details turn\(i)end"
        }.joined(separator: "\n")
    }

    @Test func emptyTextProducesNoChunks() {
        #expect(TranscriptChunker.chunk("", maxTokens: 100).isEmpty)
        #expect(TranscriptChunker.chunk("   \n  ", maxTokens: 100).isEmpty)
    }

    @Test func shortTextIsASingleChunk() {
        let text = "Me: hello\nThem: hi there"
        #expect(TranscriptChunker.chunk(text, maxTokens: 1000) == [text])
    }

    @Test func everyChunkFitsTheBudget() {
        let text = longTranscript(turns: 120)
        let chunks = TranscriptChunker.chunk(text, maxTokens: 200)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(TokenEstimator.estimate(chunk) <= 200)
        }
    }

    @Test func chunksCoverEveryLineInOrderWithoutOverlap() {
        let text = longTranscript(turns: 80)
        let chunks = TranscriptChunker.chunk(text, maxTokens: 150)
        let rejoined = chunks.joined(separator: "\n")
        #expect(rejoined == text)
    }

    @Test func splitsOnTurnBoundaries() {
        let text = longTranscript(turns: 40)
        for chunk in TranscriptChunker.chunk(text, maxTokens: 120) {
            for line in chunk.split(separator: "\n") {
                #expect(line.hasPrefix("Me:") || line.hasPrefix("Them:"))
                #expect(line.hasSuffix("end"))
            }
        }
    }

    @Test func longSingleTurnRepeatsSpeakerLabel() {
        let sentence = "We should revisit the pricing tiers before the launch next quarter."
        let monologue = "Them: " + Array(repeating: sentence, count: 60).joined(separator: " ")
        let chunks = TranscriptChunker.chunk(monologue, maxTokens: 100)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.hasPrefix("Them: "))
            #expect(TokenEstimator.estimate(chunk) <= 100)
        }
        // No words lost.
        let originalWords = monologue.split(separator: " ").count
        let chunkWords = chunks.map { $0.split(separator: " ").count - 1 }.reduce(0, +) + 1
        #expect(chunkWords == originalWords)
    }

    @Test func wordSplitHandlesTextWithoutSentences() {
        let blob = Array(repeating: "word", count: 2000).joined(separator: " ")
        let chunks = TranscriptChunker.chunk(blob, maxTokens: 64)
        #expect(chunks.count > 10)
        #expect(chunks.allSatisfy { TokenEstimator.estimate($0) <= 64 })
        #expect(chunks.map { $0.split(separator: " ").count }.reduce(0, +) == 2000)
    }

    @Test func overlapCarriesPreviousTurn() {
        let text = longTranscript(turns: 60)
        let chunks = TranscriptChunker.chunk(text, maxTokens: 150, overlapTokens: 30)
        #expect(chunks.count > 1)
        for i in 1..<chunks.count {
            let previousLast = chunks[i - 1].split(separator: "\n").last!
            #expect(chunks[i].split(separator: "\n").first! == previousLast)
        }
    }

    @Test func speakerLabelDetection() {
        #expect(TranscriptChunker.speakerLabel(of: "Me: hi") == "Me:")
        #expect(TranscriptChunker.speakerLabel(of: "**Sarah Lee:** hi") == "**Sarah Lee:**")
        #expect(TranscriptChunker.speakerLabel(of: "no label here") == nil)
        #expect(TranscriptChunker.speakerLabel(of: "this is a long sentence that has a colon: later") == nil)
    }

    @Test func tokenEstimateGrowsWithText() {
        #expect(TokenEstimator.estimate("") == 0)
        #expect(TokenEstimator.estimate("hello world") >= 2)
        #expect(TokenEstimator.estimate(String(repeating: "abcd ", count: 100)) > TokenEstimator.estimate("abcd"))
    }

    @Test func budgetInference() {
        #expect(SummarizationBudget.infer(for: ScriptedLLMClient()) == .conservative)
        #expect(SummarizationBudget.infer(for: OllamaClient()) == .ollama)
        #expect(SummarizationBudget.infer(for: AnthropicClient(apiKey: "x")) == .cloud)
        #expect(SummarizationBudget.infer(for: OpenAIClient(apiKey: "x", baseURL: URL(string: "http://localhost:1234/v1")!)) == .conservative)
        #expect(SummarizationBudget.conservative.inputTokens < SummarizationBudget.ollama.inputTokens)
    }
}

@Suite("Ollama context size")
struct PipelineOllamaClientTests {
    @Test func requestAlwaysCarriesNumCtx() throws {
        let request = PipelineOllamaClient.makeRequest(
            messages: [.init(role: "user", content: "hi")],
            model: "llama3",
            format: .json,
            contextTokens: 16384
        )
        #expect(request.options.num_ctx == 16384)
        #expect(request.format == "json")
        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(json.contains("\"num_ctx\":16384"))

        let plain = PipelineOllamaClient.makeRequest(messages: [], model: "m", format: nil, contextTokens: 8192)
        #expect(plain.options.num_ctx == 8192)
        #expect(plain.format == nil)
    }

    @Test func factoryUpgradesOllamaClient() {
        let upgraded = PipelineClientFactory.pipelineClient(for: OllamaClient(baseURL: URL(string: "http://example.local:11434")!))
        let ollama = upgraded as? PipelineOllamaClient
        #expect(ollama != nil)
        #expect(ollama?.baseURL.absoluteString == "http://example.local:11434")
        #expect(ollama?.contextTokens == PipelineOllamaClient.defaultContextTokens)

        let mock = ScriptedLLMClient()
        #expect(PipelineClientFactory.pipelineClient(for: mock) is ScriptedLLMClient)
    }
}

@Suite("Speaker formatting")
struct SpeakerTranscriptFormatterTests {
    @Test func meThemTurns() {
        let words = makeWords([(true, "hi there"), (false, "hello how are you"), (true, "good thanks")])
        let text = SpeakerTranscriptFormatter.format(words)
        #expect(text == "Me: hi there\nThem: hello how are you\nMe: good thanks")
        #expect(SpeakerTranscriptFormatter.legend(for: words, attendees: ["Ana"])?.contains("\"Me\" is the user") == true)
    }

    @Test func speakerNamesWinOverMeThem() {
        var words = makeWords([(false, "hello there")])
        for i in words.indices { words[i].speakerName = "Sarah" }
        words += makeWords([(true, "hi Sarah")])
        #expect(SpeakerTranscriptFormatter.format(words) == "Sarah: hello there\nMe: hi Sarah")
    }

    @Test func unlabelledWordsStayUnlabelledAndBreakOnPauses() {
        var words = makeWords([(nil, "first part")])
        words.append(TranscriptWord(word: "later", start: 30, end: 30.3, confidence: 1, speaker: nil, speakerName: nil, isLocalSpeaker: nil))
        let text = SpeakerTranscriptFormatter.format(words)
        #expect(text == "first part\nlater")
        #expect(SpeakerTranscriptFormatter.legend(for: words, attendees: nil) == nil)
    }

    @Test func diarizedSpeakers() {
        let words = [
            TranscriptWord(word: "a", start: 0, end: 0.2, confidence: 1, speaker: 0),
            TranscriptWord(word: "b", start: 0.3, end: 0.4, confidence: 1, speaker: 1),
        ]
        #expect(SpeakerTranscriptFormatter.format(words) == "Speaker 1: a\nSpeaker 2: b")
    }
}

@Suite("StructuredSummary fromUserNotes")
struct StructuredSummaryUserNotesTests {
    @Test func decodesAsFalseWhenAbsent() throws {
        let json = #"{"title":"t","sections":[{"heading":"h","bullets":[{"text":"x","source_quote":null}]}],"decisions":[],"actionItems":[{"title":"a"}]}"#
        let summary = try JSONDecoder().decode(StructuredSummary.self, from: Data(json.utf8))
        #expect(summary.sections[0].bullets[0].fromUserNotes == false)
        #expect(summary.actionItems[0].fromUserNotes == false)
    }

    @Test func roundTripsTrue() throws {
        let summary = StructuredSummary(
            title: "t",
            sections: [.init(heading: "h", bullets: [.init(text: "mine", fromUserNotes: true), .init(text: "ai")])],
            decisions: [],
            actionItems: [.init(title: "a", fromUserNotes: true)]
        )
        let decoded = try JSONDecoder().decode(StructuredSummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded.sections[0].bullets.map(\.fromUserNotes) == [true, false])
        #expect(decoded.actionItems[0].fromUserNotes)
        #expect(decoded.markdownSummary == "### h\n- mine\n  - ai")
    }
}

@Suite("Note outline")
struct NoteOutlineParserTests {
    @Test func parsesHeadingsAndBullets() {
        let notes = """
            # Pricing
            - raise price 10%
            * annual discount

            Next steps:
            1. send deck
            [ ] follow up with legal
            loose line
            """
        let outline = NoteOutlineParser.parse(notes)
        #expect(outline.sections.count == 2)
        #expect(outline.sections[0].heading == "Pricing")
        #expect(outline.sections[0].points == ["raise price 10%", "annual discount"])
        #expect(outline.sections[1].heading == "Next steps")
        #expect(outline.sections[1].points == ["send deck", "follow up with legal", "loose line"])
    }

    @Test func plainNotesHaveNoHeading() {
        let outline = NoteOutlineParser.parse("one\ntwo")
        #expect(outline.sections == [.init(heading: nil, points: ["one", "two"])])
        #expect(NoteOutlineParser.parse("  \n").isEmpty)
    }
}
