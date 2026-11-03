import Foundation
import os
import Testing
@testable import LidIA

/// Output captured from the real CLIs on 2026-11-03.
enum CLISamples {
    /// `echo "Reply with OK" | codex exec --ephemeral --skip-git-repo-check --ignore-user-config
    /// --ignore-rules -s read-only -C <empty> --color never --json -c model_reasoning_effort="low" -`
    /// (codex-cli 0.166.0-alpha.5.1, signed in with ChatGPT).
    static let codexOK = """
        {"type":"thread.started","thread_id":"01a1a22b-9114-7d31-8c40-ae5106e83b13"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}
        {"type":"turn.completed","usage":{"input_tokens":14100,"cached_input_tokens":12288,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
        """

    /// `codex debug models`, first entries.
    static let codexModels = """
        {"models": [{"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list"}, {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list"}, {"slug": "gpt-6.1-terra", "display_name": "GPT-6.1 Terra", "visibility": "list"}, {"slug": "gpt-6-sol", "display_name": "GPT-6-Sol", "visibility": "list"}, {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide"}, {"slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "visibility": "list"}]}
        """

    /// `grok models` before `grok login`.
    static let grokModelsSignedOut = """
        You are not authenticated.

        Default model: grok-4.6

        Available models:
          * grok-4.6 (default)
          - grok-4.5
        """

    /// `grok agent stdio` (grok 1.0.70, not signed in): the reply to our
    /// ACP `initialize` (trimmed) and to `session/new`.
    static let grokACPInitialize = """
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"mcpCapabilities":{"http":true,"sse":true}},"authMethods":[{"id":"grok.com","name":"Grok","description":"Sign in with Grok"}]}}
        """
    static let grokACPSetupNotice = """
        {"jsonrpc":"2.0","method":"_x.ai/session/setup","params":{"method":"session/new","phase":"auth","sessionId":null}}
        """
    static let grokACPAuthRequired = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required","data":"no auth method id provided"}}
        """
}

@Suite("Subscription CLIs: parsing")
struct CLIParsingTests {
    @Test("Codex: the final agent message is emitted when the turn completes")
    func codexStream() {
        var parser = CodexEventParser()
        let events = CLISamples.codexOK.split(separator: "\n").flatMap { parser.consume(String($0)) }
        #expect(events == [.text("OK"), .done])
    }

    @Test("Codex: a preamble message is dropped, only the answer is kept")
    func codexPreamble() {
        var parser = CodexEventParser()
        let lines = [
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Let me look."}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"The answer."}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ]
        let events = lines.flatMap { parser.consume($0) }
        #expect(events == [.text("The answer."), .done])
    }

    @Test("Codex: turn.failed and error events become errors")
    func codexErrors() {
        var parser = CodexEventParser()
        #expect(parser.consume(#"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#) == [.error("You've hit your usage limit.")])
        #expect(parser.consume(#"{"type":"error","message":"stream disconnected"}"#) == [.error("stream disconnected")])
        #expect(parser.consume("not json").isEmpty)
    }

    @Test("Error classification: sign-in, rate limits, plan limits, other failures")
    func classification() {
        let grokSignedOut = CLIClientError.classify(.grok, message: "Not signed in. To authenticate without a browser, run: grok login --device-code")
        #expect(grokSignedOut == .notSignedIn(.grok))
        #expect(grokSignedOut.needsSignIn)
        #expect(CLIClientError.classify(.codex, message: "Not logged in") == .notSignedIn(.codex))
        if case .usageLimit = CLIClientError.classify(.codex, message: "You've hit your usage limit. Try again at 4pm.") {} else {
            Issue.record("Expected usageLimit")
        }
        if case .rateLimited = CLIClientError.classify(.grok, message: "429 Too Many Requests") {} else {
            Issue.record("Expected rateLimited")
        }
        if case .failed = CLIClientError.classify(.codex, message: "model not supported") {} else {
            Issue.record("Expected failed")
        }
    }

    @Test("Model lists: codex debug models keeps listed models; grok models parses its text")
    func modelLists() {
        #expect(CLIChatClient.parseCodexModels(CLISamples.codexModels) == ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna"])
        #expect(CLIChatClient.parseGrokModels(CLISamples.grokModelsSignedOut) == ["grok-4.6", "grok-4.5"])
    }

    @Test("Sign-in state from codex login status and grok models")
    func signInParsing() {
        #expect(CLIDetector.parseCodexLoginStatus("Logged in using ChatGPT") == .signedIn)
        #expect(CLIDetector.parseCodexLoginStatus("Logged in using an API key - sk-…") == .apiKey)
        #expect(CLIDetector.parseCodexLoginStatus("Not logged in") == .notSignedIn)
        #expect(CLIDetector.parseGrokSignIn(CLISamples.grokModelsSignedOut, exitCode: 0) == .notSignedIn)
        #expect(CLIDetector.parseGrokSignIn("Default model: grok-4.6", exitCode: 0) == .signedIn)
    }

    @Test("Codex headless: prompt on stdin, never argv; read-only sandbox; no auto-approve")
    func invocations() {
        let prompt = "SECRET TRANSCRIPT"
        let codex = CLIInvocationBuilder.codex(model: "gpt-6.1-sol", effort: "low", workingDirectory: "/tmp/w", prompt: prompt)
        #expect(!codex.arguments.joined(separator: " ").contains(prompt))
        #expect(codex.stdin == Data(prompt.utf8))
        #expect(codex.arguments.starts(with: ["exec", "--ephemeral", "--skip-git-repo-check"]))
        #expect(codex.arguments.contains("read-only"))
        #expect(codex.arguments.contains("--json"))
        #expect(codex.arguments.last == "-")
        #expect(!codex.arguments.contains { $0.contains("dangerously") || $0 == "--approve-for-me" })
        #expect(codex.arguments.contains("model_reasoning_effort=\"low\""))
        #expect(codex.arguments.contains("gpt-6.1-sol"))

        let codexDefault = CLIInvocationBuilder.codex(model: CLIVendor.defaultModelID, effort: "medium", workingDirectory: "/tmp/w", prompt: prompt)
        #expect(!codexDefault.arguments.contains("-m"))

    }

    @Test("The child environment drops API keys so the plan is used")
    func environment() {
        let env = CLIInvocationBuilder.environment(
            for: .codex,
            executable: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
            base: ["OPENAI_API_KEY": "sk-x", "HOME": "/Users/x", "PATH": "/usr/bin"]
        )
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["HOME"] == "/Users/x")
        #expect(env["PATH"]?.contains("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin") == true)
        let grokEnv = CLIInvocationBuilder.environment(for: .grok, executable: URL(fileURLWithPath: "/x/grok"), base: ["XAI_API_KEY": "k"])
        #expect(grokEnv["XAI_API_KEY"] == nil)
    }

    @Test("Prompt rendering keeps system, history and the request, and asks for JSON when needed")
    func promptRendering() {
        let prompt = CLIInvocationBuilder.renderPrompt([
            LLMChatMessage(role: "system", content: "Be brief."),
            LLMChatMessage(role: "user", content: "Hi"),
            LLMChatMessage(role: "assistant", content: "Hello"),
            LLMChatMessage(role: "user", content: "Summarise"),
        ], format: .json)
        #expect(prompt.hasPrefix(CLIInvocationBuilder.preamble))
        #expect(prompt.contains("## Instructions\n\nBe brief."))
        #expect(prompt.contains("User: Hi\n\nAssistant: Hello"))
        #expect(prompt.contains("## Request\n\nSummarise"))
        #expect(prompt.contains("valid JSON only"))
    }
}

/// Runs `CLIChatClient.execute` against small shell scripts standing in for
/// the CLIs: process launch, stdin, JSON streaming, errors, timeout, cancel.
@Suite("Subscription CLIs: process")
struct CLIProcessTests {
    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-cli")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Codex: prompt arrives on stdin, not argv, and the answer streams back")
    func codexRoundTrip() async throws {
        let fake = try script("""
            printf '%s\\n' "$@" > "$0.args"
            cat > "$0.stdin"
            cat <<'JSONL'
            \(CLISamples.codexOK)
            JSONL
            """)
        let collected = OSAllocatedUnfairLock(initialState: "")
        try await CLIChatClient.execute(
            vendor: .codex, executable: fake, model: "default", effort: "low",
            prompt: "Reply with OK", timeout: .seconds(20)
        ) { chunk in collected.withLock { $0 += chunk } }
        #expect(collected.withLock { $0 } == "OK")
        let stdin = try String(contentsOf: URL(fileURLWithPath: fake.path + ".stdin"), encoding: .utf8)
        let args = try String(contentsOf: URL(fileURLWithPath: fake.path + ".args"), encoding: .utf8)
        #expect(stdin == "Reply with OK")
        #expect(!args.contains("Reply with OK"))
        #expect(args.contains("read-only"))
    }

    @Test("A signed-out CLI fails with a sign-in error")
    func signedOut() async throws {
        let fake = try script("""
            cat > /dev/null
            echo '{"type":"error","message":"Not logged in. Run codex login."}'
            exit 1
            """)
        do {
            try await CLIChatClient.execute(vendor: .codex, executable: fake, model: "default", effort: "low", prompt: "x", timeout: .seconds(20)) { _ in }
            Issue.record("Expected an error")
        } catch let error as CLIClientError {
            #expect(error == .notSignedIn(.codex))
        }
    }

    @Test("A non-zero exit without events reports stderr")
    func nonZeroExit() async throws {
        let fake = try script("echo 'boom: model unavailable' >&2\nexit 3\n")
        do {
            try await CLIChatClient.execute(vendor: .codex, executable: fake, model: "default", effort: "low", prompt: "x", timeout: .seconds(20)) { _ in }
            Issue.record("Expected an error")
        } catch let error as CLIClientError {
            guard case .failed(_, let message) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(message.contains("boom"))
        }
    }

    @Test("Timeout kills the child and says so")
    func timeout() async throws {
        let fake = try script("cat > /dev/null\nsleep 30\n")
        let start = Date()
        do {
            try await CLIChatClient.execute(vendor: .codex, executable: fake, model: "default", effort: "low", prompt: "x", timeout: .seconds(1)) { _ in }
            Issue.record("Expected a timeout")
        } catch let error as CLIClientError {
            #expect(error == .timedOut(.codex, seconds: 1))
        }
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test("Cancelling the task kills the child")
    func cancellation() async throws {
        let fake = try script("cat > /dev/null\nsleep 30\n")
        let start = Date()
        let task = Task {
            try await CLIChatClient.execute(vendor: .codex, executable: fake, model: "default", effort: "low", prompt: "x", timeout: .seconds(60)) { _ in }
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let result = await task.result
        if case .success = result { Issue.record("Expected cancellation") }
        if case .failure(let error) = result { #expect(error is CancellationError) }
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test("Calls to one CLI run one at a time")
    func serialised() async throws {
        let lock = SerialAsyncLock()
        let active = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await lock.run {
                        active.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                        try await Task.sleep(for: .milliseconds(30))
                        active.withLock { $0.now -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(active.withLock { $0.peak } == 1)
    }
}

/// LIVE: runs the real, signed-in Codex CLI once through `CLIChatClient`.
/// Off unless `LIDIA_LIVE_CODEX=1`, so `swift test` never spends plan usage.
@Suite("Subscription CLIs: live")
struct CLILiveTests {
    @Test("Codex replies OK", .enabled(if: ProcessInfo.processInfo.environment["LIDIA_LIVE_CODEX"] == "1"))
    func liveCodex() async throws {
        let client = CLIChatClient(vendor: .codex, timeout: .seconds(120))
        let reply = try await client.chat(
            messages: [LLMChatMessage(role: "user", content: "Reply with OK")],
            model: CLIVendor.defaultModelID,
            format: nil
        )
        print("LIVE codex reply: \(reply)")
        #expect(reply.uppercased().contains("OK"))
    }
}
