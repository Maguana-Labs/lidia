import Testing
import Foundation
@testable import LidIA

@Suite("Reasoning filter")
struct ReasoningFilterTests {

    @Test("Plain answers pass through unchanged")
    func plain() {
        #expect(ReasoningFilter.strip("Here is the summary.") == "Here is the summary.")
        #expect(ReasoningFilter.strip("{\"title\": \"x\"}") == "{\"title\": \"x\"}")
    }

    @Test("Qwen think blocks are removed")
    func qwenThink() {
        #expect(ReasoningFilter.strip("<think>let me see</think>\n\nThe answer.") == "The answer.")
    }

    @Test("Gemma 4 thinking channel is removed")
    func gemmaChannel() {
        let raw = "<|channel>thought\nThe user wants a summary.<channel|>{\"title\":\"Sync\"}"
        #expect(ReasoningFilter.strip(raw) == "{\"title\":\"Sync\"}")
    }

    @Test("An unclosed explicit block is dropped entirely")
    func unclosed() {
        #expect(ReasoningFilter.strip("<think>still thinking when tokens ran out") == "")
    }

    @Test("Legacy implicit thinking keeps text after the closing tag")
    func implicit() {
        #expect(ReasoningFilter.strip("reasoning here</think>{\"a\":1}", family: .qwen3) == "{\"a\":1}")
        // Implicit mode with no tag: keep the text, minus a narrated preamble.
        #expect(ReasoningFilter.strip("Thinking Process: hmm {\"a\":1}", family: .qwen3) == "{\"a\":1}")
    }

    @Test("Streaming: chunks split inside the tags are handled")
    func streamingSplitTags() {
        var filter = ReasoningFilter()
        var out = ""
        for chunk in ["<|chan", "nel>thou", "ght\nplanning", " more<chan", "nel|>", "Hello", " world"] {
            out += filter.consume(chunk)
        }
        out += filter.finish()
        #expect(out == "Hello world")
    }

    @Test("Streaming: plain text streams immediately once it can't be a tag")
    func streamingImmediate() {
        var filter = ReasoningFilter()
        #expect(filter.consume("Hel") == "Hel")
        #expect(filter.consume("lo") == "lo")
        #expect(filter.finish() == "")
    }

    @Test("Streaming: a lone '<' waits for more before deciding")
    func streamingWaits() {
        var filter = ReasoningFilter()
        #expect(filter.consume("<") == "")
        #expect(filter.consume("b>bold") == "<b>bold")
    }

    @Test("Per-family chat sampling")
    func sampling() {
        let gemma = MLXLocalClient.parameters(for: .init(family: .gemma4, contextCap: 32_768, implicitThinking: false), isJSON: false)
        #expect(gemma.temperature == 1.0)
        #expect(gemma.topP == 0.95)
        #expect(gemma.topK == 64)
        let json = MLXLocalClient.parameters(for: .init(family: .gemma4, contextCap: 32_768, implicitThinking: false), isJSON: true)
        #expect(json.temperature == LLMTemperature.structured)
    }

    @Test("Profiles come from the catalogue")
    func profiles() {
        let e4b = MLXLocalClient.profile(for: "mlx-community/gemma-4-e4b-it-4bit")
        #expect(e4b.family == .gemma4)
        #expect(e4b.contextCap == 32_768)
        let unknown = MLXLocalClient.profile(for: "someone/custom-model")
        #expect(unknown.contextCap == MLXLocalClient.defaultContextCap)
    }
}
