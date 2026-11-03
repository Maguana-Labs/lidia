import Foundation
import Testing
@testable import LidIA

@Suite("Anthropic client")
struct AnthropicClientTests {

    @Test("Request streams, sets effort and the default fallback on current models")
    func requestBodyForOpus() throws {
        let body = AnthropicClient.requestBody(
            messages: [.init(role: "system", content: "Be brief."), .init(role: "user", content: "Hi")],
            model: "claude-opus-5-5",
            format: .json,
            effort: "medium"
        )
        #expect(body["stream"] as? Bool == true)
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["output_config"] as? [String: String])?["effort"] == "medium")
        #expect((body["system"] as? String)?.contains("Respond ONLY with valid JSON") == true)
        #expect((body["messages"] as? [[String: Any]])?.count == 1)
        #expect(body["temperature"] == nil)
        #expect(body["thinking"] == nil)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test("Older models get neither effort nor fallbacks")
    func requestBodyForOlderModels() {
        let body = AnthropicClient.requestBody(
            messages: [.init(role: "user", content: "Hi")],
            model: "claude-haiku-4-5",
            format: nil,
            effort: "low"
        )
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(body["system"] == nil)
    }

    @Test("Parser yields text deltas and skips thinking")
    func parserText() throws {
        var parser = AnthropicSSEParser()
        #expect(try parser.consume(line: "event: content_block_delta") == .none)
        #expect(try parser.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#) == .none)
        #expect(try parser.consume(line: #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#) == .text("Hello"))
        #expect(try parser.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) == .none)
        try parser.finish()
    }

    @Test("Refusals and stream errors become errors")
    func parserRefusalAndError() throws {
        var parser = AnthropicSSEParser()
        _ = try parser.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        #expect(throws: LLMError.self) { try parser.finish() }

        var failing = AnthropicSSEParser()
        #expect(throws: LLMError.self) {
            try failing.consume(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }
}
