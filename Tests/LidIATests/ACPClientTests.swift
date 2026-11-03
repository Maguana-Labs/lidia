import Foundation
import os
import Testing
@testable import LidIA

/// Decodes the JSON line an `ACPAction.send` carries.
private func sent(_ action: ACPAction) -> [String: Any]? {
    guard case .send(let data) = action else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Suite("ACP client: protocol")
struct ACPTurnTests {
    private func turn(model: String = CLIVendor.defaultModelID) -> ACPTurn {
        ACPTurn(vendor: .grok, workingDirectory: "/tmp/empty", prompt: "Reply with OK", model: model, effort: "low")
    }

    @Test("initialize offers no filesystem or terminal")
    func initialize() {
        var turn = turn()
        let message = sent(turn.start()[0])
        #expect(message?["method"] as? String == "initialize")
        let params = message?["params"] as? [String: Any]
        #expect(params?["protocolVersion"] as? Int == 1)
        let caps = params?["clientCapabilities"] as? [String: Any]
        #expect(caps?["terminal"] as? Bool == false)
        #expect((caps?["fs"] as? [String: Any])?["readTextFile"] as? Bool == false)
    }

    @Test("Real Grok traffic before sign-in: session/new fails with auth required → sign-in error")
    func grokSignedOut() {
        var turn = turn()
        _ = turn.start()
        let afterInit = turn.consume(CLISamples.grokACPInitialize)
        let newSession = sent(afterInit[0])
        #expect(newSession?["method"] as? String == "session/new")
        let params = newSession?["params"] as? [String: Any]
        #expect(params?["cwd"] as? String == "/tmp/empty")
        #expect((params?["mcpServers"] as? [Any])?.isEmpty == true)
        #expect(turn.consume(CLISamples.grokACPSetupNotice).isEmpty)
        #expect(turn.consume(CLISamples.grokACPAuthRequired) == [.failed(.notSignedIn(.grok))])
    }

    @Test("A full turn: config options, streamed chunks, permission refused, end_turn")
    func fullTurn() {
        var turn = turn(model: "grok-4.5")
        _ = turn.start()
        _ = turn.consume(CLISamples.grokACPInitialize)
        let configs = turn.consume(line(["jsonrpc": "2.0", "id": 2, "result": [
            "sessionId": "s1",
            "configOptions": [
                ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "grok-4.6",
                 "options": [["value": "grok-4.6", "name": "Grok 4.6"], ["value": "grok-4.5", "name": "Grok 4.5"]]],
                ["id": "effort", "name": "Effort", "category": "thought_level", "type": "select", "currentValue": "high",
                 "options": [["group": "g", "name": "Levels", "options": [["value": "low", "name": "Low"], ["value": "high", "name": "High"]]]]],
            ],
        ]]))
        let setValues = configs.compactMap { sent($0) }.map { ($0["params"] as? [String: Any])?["value"] as? String }
        #expect(configs.count == 2)
        #expect(Set(setValues.compactMap { $0 }) == ["grok-4.5", "low"])
        #expect(turn.phase == .configuring)

        #expect(turn.consume(line(["jsonrpc": "2.0", "id": 3, "result": ["configOptions": []]])).isEmpty)
        // The effort change is refused: keep the default and go on.
        let prompt = turn.consume(line(["jsonrpc": "2.0", "id": 4, "error": ["code": -32602, "message": "bad value"]]))
        let promptMessage = sent(prompt[0])
        #expect(promptMessage?["method"] as? String == "session/prompt")
        let blocks = (promptMessage?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        #expect(blocks?.first?["text"] as? String == "Reply with OK")
        #expect(turn.phase == .prompting)

        let chunk = turn.consume(line(["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": "s1", "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "OK"]],
        ]]))
        #expect(chunk == [.text("OK")])
        #expect(turn.consume(line(["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": "s1", "update": ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "hmm"]],
        ]])).isEmpty)

        let permission = turn.consume(line(["jsonrpc": "2.0", "id": 99, "method": "session/request_permission", "params": [
            "sessionId": "s1", "toolCall": ["toolCallId": "t1"],
            "options": [["optionId": "ok", "name": "Allow", "kind": "allow_once"], ["optionId": "nope", "name": "Reject", "kind": "reject_once"]],
        ]]))
        let reply = sent(permission[0])
        #expect(reply?["id"] as? Int == 99)
        let outcome = (reply?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "selected")
        #expect(outcome?["optionId"] as? String == "nope")

        let fsRequest = turn.consume(line(["jsonrpc": "2.0", "id": 100, "method": "fs/read_text_file", "params": ["path": "/etc/hosts"]]))
        #expect((sent(fsRequest[0])?["error"] as? [String: Any])?["code"] as? Int == -32601)

        #expect(turn.consume(line(["jsonrpc": "2.0", "id": 5, "result": ["stopReason": "end_turn"]])) == [.finished(stopReason: "end_turn")])
    }

    @Test("A permission request with no reject option is cancelled, never allowed")
    func permissionWithoutReject() {
        var turn = turn()
        let reply = sent(turn.consume(line(["jsonrpc": "2.0", "id": 7, "method": "session/request_permission", "params": [
            "sessionId": "s1", "toolCall": ["toolCallId": "t"], "options": [["optionId": "go", "name": "Allow", "kind": "allow_always"]],
        ]]))[0])
        let outcome = (reply?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
        #expect(outcome?["optionId"] == nil)
    }

    @Test("A tool call cancels the turn and fails it")
    func toolCallCancels() {
        var turn = turn()
        _ = turn.start()
        _ = turn.consume(CLISamples.grokACPInitialize)
        _ = turn.consume(line(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "s1"]]))
        let actions = turn.consume(line(["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": "s1", "update": ["sessionUpdate": "tool_call", "toolCallId": "t", "title": "Read", "kind": "read", "status": "pending"],
        ]]))
        let cancel = sent(actions[0])
        #expect(cancel?["method"] as? String == "session/cancel")
        #expect(cancel?["id"] == nil)
        let end = turn.consume(line(["jsonrpc": "2.0", "id": 3, "result": ["stopReason": "cancelled"]]))
        guard case .failed(.failed(.grok, let message))? = end.first else {
            Issue.record("Expected a failure, got \(end)")
            return
        }
        #expect(message.contains("tool"))
    }
}

/// `ACPRunner` against a shell script that plays an ACP agent.
@Suite("ACP client: process")
struct ACPRunnerTests {
    private func agent(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-acp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-agent")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Streams the answer, refuses permission, then stops the agent")
    func roundTrip() async throws {
        let fake = try agent("""
            read init
            echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}'
            read new
            printf '%s\\n' "$new" > "$0.new"
            echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}'
            read prompt
            printf '%s\\n' "$prompt" > "$0.prompt"
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "}}}}'
            echo '{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t"},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}'
            read reply
            printf '%s\\n' "$reply" > "$0.reply"
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world"}}}}'
            echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
            sleep 30
            """)
        let spec = ACPAgentSpec(vendor: .grok, executable: fake, arguments: [])
        let text = OSAllocatedUnfairLock(initialState: "")
        let start = Date()
        try await ACPRunner.run(spec: spec, prompt: "Summarise", model: "default", effort: "low", timeout: .seconds(20)) { chunk in
            text.withLock { $0 += chunk }
        }
        #expect(text.withLock { $0 } == "Hello world")
        #expect(Date().timeIntervalSince(start) < 8)
        let reply = try String(contentsOf: URL(fileURLWithPath: fake.path + ".reply"), encoding: .utf8)
        #expect(reply.contains("\"optionId\":\"no\""))
        let prompt = try String(contentsOf: URL(fileURLWithPath: fake.path + ".prompt"), encoding: .utf8)
        #expect(prompt.contains("Summarise"))
        let newSession = try String(contentsOf: URL(fileURLWithPath: fake.path + ".new"), encoding: .utf8)
        #expect(newSession.contains("lidia-acp-"))
    }

    @Test("An agent that never answers times out and is killed")
    func timeout() async throws {
        let fake = try agent("sleep 30\n")
        let start = Date()
        do {
            try await ACPRunner.run(spec: ACPAgentSpec(vendor: .grok, executable: fake, arguments: []),
                                    prompt: "x", model: "default", effort: "low", timeout: .seconds(1)) { _ in }
            Issue.record("Expected a timeout")
        } catch let error as CLIClientError {
            #expect(error == .timedOut(.grok, seconds: 1))
        }
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test("CLIChatClient uses ACP when an agent is given")
    func transport() {
        let spec = ACPAgentSpec(vendor: .grok, executable: URL(fileURLWithPath: "/x/grok"), arguments: ["agent", "stdio"])
        #expect(CLIChatClient(vendor: .grok, acp: spec).transport() == .acp(spec))
        let codex = URL(fileURLWithPath: "/x/codex")
        #expect(CLIChatClient(vendor: .codex, executable: codex).transport() == .headless(codex))
    }
}

/// LIVE, free: the ACP handshake with the real Grok CLI (no prompt is sent
/// before sign-in). Off unless `LIDIA_LIVE_GROK_ACP=1`. After `grok login`
/// it sends one tiny prompt: run it with `LIDIA_LIVE_GROK_PROMPT=1` too.
@Suite("ACP client: live Grok")
struct ACPLiveGrokTests {
    @Test("grok agent stdio over ACP", .enabled(if: ProcessInfo.processInfo.environment["LIDIA_LIVE_GROK_ACP"] == "1"))
    func liveGrok() async throws {
        guard let spec = ACPAgentSpec.find(for: .grok) else {
            Issue.record("Grok CLI not installed")
            return
        }
        let text = OSAllocatedUnfairLock(initialState: "")
        do {
            try await ACPRunner.run(spec: spec, prompt: "Reply with OK", model: "default", effort: "low", timeout: .seconds(90)) { chunk in
                text.withLock { $0 += chunk }
            }
            print("LIVE grok reply: \(text.withLock { $0 })")
            #expect(text.withLock { $0 }.uppercased().contains("OK"))
        } catch let error as CLIClientError {
            print("LIVE grok: \(error.localizedDescription)")
            #expect(error == .notSignedIn(.grok), "Only a sign-in error is expected before grok login")
        }
    }
}
