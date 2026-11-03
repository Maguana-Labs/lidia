import Foundation
import os

// MARK: - Vendors

/// A vendor CLI that lets LidIA use the user's paid plan (ChatGPT, SuperGrok)
/// instead of per-token API billing.
///
/// LidIA only ever runs the vendor's official CLI (or its ACP agent) as a
/// subprocess, signed in as the user. It never reads or copies the CLI's
/// stored credentials and never calls the vendors' private backends itself.
enum CLIVendor: String, Sendable, CaseIterable, Identifiable {
    case codex
    case grok

    var id: String { rawValue }

    /// Model value meaning "the CLI's own default". Non-empty on purpose:
    /// callers treat an empty model as "not configured".
    static let defaultModelID = "default"

    static func isDefaultModel(_ model: String) -> Bool {
        model.isEmpty || model == defaultModelID
    }

    var provider: AppSettings.LLMProvider {
        switch self {
        case .codex: .codexCLI
        case .grok: .grokCLI
        }
    }

    /// "Codex", "Grok CLI".
    var toolName: String {
        switch self {
        case .codex: "Codex"
        case .grok: "Grok CLI"
        }
    }

    /// "ChatGPT", "SuperGrok".
    var planName: String {
        switch self {
        case .codex: "ChatGPT"
        case .grok: "SuperGrok"
        }
    }

    var binaryName: String { rawValue }

    /// Where the CLI usually lives, before searching PATH.
    var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .codex:
            return [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.npm-global/bin/codex",
            ]
        case .grok:
            return [
                "\(home)/.grok/bin/grok",
                "\(home)/.local/bin/grok",
                "/opt/homebrew/bin/grok",
                "/usr/local/bin/grok",
            ]
        }
    }

    /// The installed CLI, or nil.
    func resolveExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(binaryName)"
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// The shell command that signs in, as the user would type it.
    func loginCommand(executable: URL) -> String {
        "'\(executable.path.replacingOccurrences(of: "'", with: "'\\''"))' login"
    }

    /// Environment variables that would switch the CLI to per-token API
    /// billing. Removed so the call uses the signed-in plan.
    var apiKeyVariables: [String] {
        switch self {
        case .codex: ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"]
        case .grok: ["XAI_API_KEY", "GROK_API_KEY"]
        }
    }

    /// One call at a time per CLI: each run is a full agent process.
    var lock: SerialAsyncLock {
        switch self {
        case .codex: SerialAsyncLock.codex
        case .grok: SerialAsyncLock.grok
        }
    }
}

/// FIFO async lock (same design as `MLXInferenceLock`).
actor SerialAsyncLock {
    static let codex = SerialAsyncLock()
    static let grok = SerialAsyncLock()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Errors

/// What went wrong with a subscription CLI call, in words the user can act on.
enum CLIClientError: LocalizedError, Equatable {
    case notInstalled(CLIVendor)
    case notSignedIn(CLIVendor)
    case rateLimited(CLIVendor, String)
    case usageLimit(CLIVendor, String)
    case timedOut(CLIVendor, seconds: Int)
    case failed(CLIVendor, String)
    case emptyResponse(CLIVendor)

    var vendor: CLIVendor {
        switch self {
        case .notInstalled(let v), .notSignedIn(let v), .rateLimited(let v, _), .usageLimit(let v, _),
             .timedOut(let v, _), .failed(let v, _), .emptyResponse(let v):
            return v
        }
    }

    /// True when "Sign in…" is the fix.
    var needsSignIn: Bool {
        if case .notSignedIn = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled(let v):
            return v == .codex
                ? "Codex isn't installed. Install the ChatGPT app (it includes Codex) or the Codex CLI."
                : "The Grok CLI isn't installed. Install it from x.ai, then sign in."
        case .notSignedIn(let v):
            return "\(v.toolName) isn't signed in to your \(v.planName) plan. Use Sign in… in Settings → AI, or run `\(v.binaryName) login` in Terminal."
        case .rateLimited(let v, let message):
            return "\(v.planName) plan is rate-limited right now. \(message)"
        case .usageLimit(let v, let message):
            return "Your \(v.planName) plan limit is reached. \(message)"
        case .timedOut(let v, let seconds):
            return "\(v.toolName) didn't answer within \(seconds) seconds."
        case .failed(let v, let message):
            return "\(v.toolName) failed: \(message)"
        case .emptyResponse(let v):
            return "\(v.toolName) returned no text."
        }
    }

    /// Maps a CLI error message (event text, stderr) to a case.
    static func classify(_ vendor: CLIVendor, message: String) -> CLIClientError {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let short = String(trimmed.prefix(300))
        let signInMarkers = [
            "not signed in", "not logged in", "not authenticated", "please sign in", "please log in",
            "login required", "authentication required", "unauthorized", "401", "sign in again", "re-login",
            "\(vendor.binaryName) login",
        ]
        if signInMarkers.contains(where: lower.contains) {
            return .notSignedIn(vendor)
        }
        let usageMarkers = ["usage limit", "plan limit", "limit reached", "quota", "you've hit your", "upgrade to", "credits"]
        if usageMarkers.contains(where: lower.contains) {
            return .usageLimit(vendor, short)
        }
        let rateMarkers = ["rate limit", "rate-limit", "ratelimit", "429", "too many requests", "is_rate_limited"]
        if rateMarkers.contains(where: lower.contains) {
            return .rateLimited(vendor, short)
        }
        return .failed(vendor, short.isEmpty ? "exited without an answer" : short)
    }
}

// MARK: - Codex headless output

/// What one line of headless CLI output means.
enum CLIStreamEvent: Equatable, Sendable {
    /// Answer text to show.
    case text(String)
    case error(String)
    case done
}

/// `codex exec --json` (JSONL `ThreadEvent`s):
/// `thread.started`, `turn.started`, `item.started|updated|completed` with
/// `item.type` `agent_message` / `reasoning` / `command_execution` …,
/// `turn.completed`, `turn.failed {error:{message}}`, `error {message}`.
///
/// Codex doesn't stream message deltas and may write a short preamble
/// message before its answer, so only the last agent message is emitted,
/// when the turn completes.
struct CodexEventParser {
    private var lastAgentMessage: String?
    private var finished = false

    mutating func consume(_ line: String) -> [CLIStreamEvent] {
        guard let object = Self.json(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "item.completed", "item.updated":
            if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
               let text = item["text"] as? String {
                lastAgentMessage = text
            }
            if let item = object["item"] as? [String: Any], item["type"] as? String == "error",
               let message = item["message"] as? String {
                return [.error(message)]
            }
            return []
        case "turn.completed":
            finished = true
            var events: [CLIStreamEvent] = []
            if let text = lastAgentMessage, !text.isEmpty { events.append(.text(text)) }
            events.append(.done)
            return events
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "turn failed"
            return [.error(message)]
        case "error":
            return [.error(object["message"] as? String ?? "error")]
        default:
            return []
        }
    }

    /// The answer if the stream ended without `turn.completed`.
    var pendingText: String? { finished ? nil : lastAgentMessage }

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Invocation

/// A headless CLI run (Codex without the ACP adapter).
struct CLIInvocation: Sendable, Equatable {
    var arguments: [String]
    /// Sent on stdin. The prompt never goes on argv: transcripts are long and
    /// private, and argv is visible to other processes.
    var stdin: Data?
}

enum CLIInvocationBuilder {
    /// Instructions sent ahead of LidIA's own prompt.
    static let preamble = """
        You are the text engine inside LidIA, a meeting notes app. Work only from the text below. \
        Do not run commands, read or write files, browse the web or use any tool. \
        Reply with the answer text only.
        """

    static func codex(model: String, effort: String, workingDirectory: String, prompt: String) -> CLIInvocation {
        var args = [
            "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "-s", "read-only", "-C", workingDirectory, "--color", "never", "--json",
            "-c", "model_reasoning_effort=\"\(effort)\"",
        ]
        if !CLIVendor.isDefaultModel(model) { args += ["-m", model] }
        args.append("-") // read the prompt from stdin
        return CLIInvocation(arguments: args, stdin: Data(prompt.utf8))
    }

    /// One plain-text prompt from a chat transcript.
    static func renderPrompt(_ messages: [LLMChatMessage], format: LLMResponseFormat?) -> String {
        var parts = [preamble]
        let system = messages.filter { $0.role == "system" }.map(\.content)
        if !system.isEmpty {
            parts.append("## Instructions\n\n" + system.joined(separator: "\n\n"))
        }
        let turns = messages.filter { $0.role != "system" }
        if turns.count > 1 {
            let history = turns.dropLast().map { "\($0.role == "assistant" ? "Assistant" : "User"): \($0.content)" }
            parts.append("## Conversation so far\n\n" + history.joined(separator: "\n\n"))
        }
        if let last = turns.last {
            parts.append("## Request\n\n" + last.content)
        }
        if case .json = format {
            parts.append("Respond with valid JSON only. No markdown code fences, no commentary.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The child's environment: the user's, minus anything that would switch
    /// the CLI to API billing, with the usual tool folders on PATH.
    static func environment(for vendor: CLIVendor, executable: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in vendor.apiKeyVariables { env.removeValue(forKey: key) }
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extra where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }
}

// MARK: - Process

/// A running CLI child process with its stdout as lines.
final class CLIProcess: @unchecked Sendable {
    /// Why LidIA stopped the child. `.finished` is a normal end (an ACP
    /// agent that answered and is no longer needed).
    enum StopReason: Sendable { case none, timeout, cancelled, finished }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let state = OSAllocatedUnfairLock(initialState: StopReason.none)
    private let exitStream: AsyncStream<Int32>
    private let exitContinuation: AsyncStream<Int32>.Continuation
    private var stderrTask: Task<String, Never>?
    private let writeQueue = DispatchQueue(label: "io.lidia.cli.stdin")
    private let interactive: Bool

    /// - Parameter interactive: keep stdin open for `send(_:)` (ACP agents).
    init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL, stdin: Data?, interactive: Bool = false) throws {
        self.interactive = interactive
        (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = (stdin == nil && !interactive) ? FileHandle.nullDevice : stdinPipe
        let continuation = exitContinuation
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        try process.run()

        let errHandle = stderrPipe.fileHandleForReading
        stderrTask = Task.detached {
            let data = (try? errHandle.readToEnd()) ?? Data()
            return String(decoding: data.suffix(16_384), as: UTF8.self)
        }
        if let stdin {
            let writer = stdinPipe.fileHandleForWriting
            // Off the caller's thread: a large prompt fills the pipe buffer.
            Task.detached {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
    }

    /// Writes to the child's stdin in order, off the caller's thread.
    func send(_ data: Data) {
        guard interactive else { return }
        let writer = stdinPipe.fileHandleForWriting
        writeQueue.async { try? writer.write(contentsOf: data) }
    }

    var lines: AsyncLineSequence<FileHandle.AsyncBytes> {
        stdoutPipe.fileHandleForReading.bytes.lines
    }

    var stopReason: StopReason { state.withLock { $0 } }

    /// SIGTERM now, SIGKILL two seconds later if it's still running.
    func stop(_ reason: StopReason) {
        let first = state.withLock { current -> Bool in
            guard current == .none else { return false }
            current = reason
            return true
        }
        guard first, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func exitCode() async -> Int32 {
        var code: Int32 = -1
        for await value in exitStream { code = value }
        return code
    }

    /// The child's stderr, waiting at most two seconds: a grandchild that
    /// inherited the pipe can keep it open after the child itself has exited.
    func stderrText() async -> String {
        guard let stderrTask else { return "" }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await stderrTask.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ""
        }
    }
}

// MARK: - Client

/// `LLMClient` backed by a vendor CLI signed in to the user's plan.
///
/// Each request starts the agent once in a fresh, empty temporary folder:
/// - over ACP (`ACPRunner`) when the vendor speaks it: Grok natively
///   (`grok agent stdio`), Codex through Zed's `codex-acp` adapter if
///   installed. Every permission request is refused and a tool call ends
///   the turn;
/// - otherwise headless (`codex exec --json`, read-only sandbox).
/// No auto-approve. Calls are serialised per vendor, time out, and kill the
/// child when cancelled.
final class CLIChatClient: LLMClient {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "CLIChatClient")

    let vendor: CLIVendor
    let timeout: Duration
    private let executableOverride: URL?
    private let acpOverride: ACPAgentSpec?

    /// - Parameters:
    ///   - executable: a headless CLI to run instead of the installed one (tests).
    ///   - acp: an ACP agent to use instead of looking one up (tests).
    init(vendor: CLIVendor, timeout: Duration = .seconds(480), executable: URL? = nil, acp: ACPAgentSpec? = nil) {
        self.vendor = vendor
        self.timeout = timeout
        self.executableOverride = executable
        self.acpOverride = acp
    }

    /// How a request will reach the vendor right now.
    enum Transport: Equatable, Sendable {
        case acp(ACPAgentSpec)
        case headless(URL)
    }

    func transport() -> Transport? {
        if let acpOverride { return .acp(acpOverride) }
        if executableOverride == nil, let spec = ACPAgentSpec.find(for: vendor) { return .acp(spec) }
        // Grok always speaks ACP; only Codex has a headless path.
        guard vendor == .codex, let executable = executableOverride ?? vendor.resolveExecutable() else { return nil }
        return .headless(executable)
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        let collected = OSAllocatedUnfairLock(initialState: "")
        try await run(messages: messages, model: model, format: format, streaming: false) { chunk in
            collected.withLock { $0 += chunk }
        }
        let cleaned = collected.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CLIClientError.emptyResponse(vendor) }
        return cleaned
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages: messages, model: model, format: nil, streaming: true) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        guard let executable = executableOverride ?? vendor.resolveExecutable() else {
            throw CLIClientError.notInstalled(vendor)
        }
        let arguments = vendor == .codex ? ["debug", "models"] : ["models"]
        let output = try await Self.capture(vendor: vendor, executable: executable, arguments: arguments, timeout: .seconds(30))
        let models = vendor == .codex ? Self.parseCodexModels(output.stdout) : Self.parseGrokModels(output.stdout)
        if models.isEmpty, vendor == .grok, output.stdout.lowercased().contains("not authenticated") {
            throw CLIClientError.notSignedIn(vendor)
        }
        return models
    }

    // MARK: Running

    private func run(
        messages: [LLMChatMessage],
        model: String,
        format: LLMResponseFormat?,
        streaming: Bool,
        onText: @escaping @Sendable (String) -> Void
    ) async throws {
        // Transport-level backstop: a path that skipped the gated factory
        // still can't send meeting data off this Mac in Local-only mode.
        if PrivacyGate.isLocalOnly {
            throw LLMError.cloudBlocked(provider: vendor.provider.displayName, reason: "Local-only mode is on, so meeting data stays on this Mac.")
        }
        guard let transport = transport() else {
            throw CLIClientError.notInstalled(vendor)
        }
        let outbound = OutboundRedactor.prepare(messages, for: .cloud)
        let prompt = CLIInvocationBuilder.renderPrompt(outbound, format: format)
        let effort = AnthropicClient.effort(for: messages, streaming: streaming)
        let vendor = self.vendor
        let timeout = self.timeout
        try await vendor.lock.run {
            switch transport {
            case .acp(let spec):
                try await ACPRunner.run(spec: spec, prompt: prompt, model: model, effort: effort, timeout: timeout, onText: onText)
            case .headless(let executable):
                try await Self.execute(
                    vendor: vendor, executable: executable, model: model, effort: effort,
                    prompt: prompt, timeout: timeout, onText: onText
                )
            }
        }
    }

    /// One headless `codex exec --json` run.
    static func execute(
        vendor: CLIVendor,
        executable: URL,
        model: String,
        effort: String,
        prompt: String,
        timeout: Duration,
        onText: @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("lidia-cli-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }

        let invocation = CLIInvocationBuilder.codex(model: model, effort: effort, workingDirectory: workDir.path, prompt: prompt)
        let process = try CLIProcess(
            executable: executable,
            arguments: invocation.arguments,
            environment: CLIInvocationBuilder.environment(for: vendor, executable: executable),
            workingDirectory: workDir,
            stdin: invocation.stdin
        )
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { process.stop(.timeout) }
        }
        defer { timer.cancel() }

        var codex = CodexEventParser()
        var errorMessage: String?
        var produced = false
        try await withTaskCancellationHandler {
            for try await line in process.lines {
                for event in codex.consume(line) {
                    switch event {
                    case .text(let text):
                        produced = true
                        onText(text)
                    case .error(let message):
                        errorMessage = errorMessage ?? message
                    case .done:
                        break
                    }
                }
            }
        } onCancel: {
            process.stop(.cancelled)
        }
        let code = await process.exitCode()
        let stderr = await process.stderrText()

        switch process.stopReason {
        case .cancelled:
            throw CancellationError()
        case .timeout:
            throw CLIClientError.timedOut(vendor, seconds: Int(timeout.components.seconds))
        case .none, .finished:
            break
        }
        try Task.checkCancellation()
        if !produced, let pending = codex.pendingText, !pending.isEmpty, errorMessage == nil, code == 0 {
            onText(pending)
            produced = true
        }
        if let errorMessage {
            logger.info("\(vendor.rawValue, privacy: .public) reported an error (exit \(code))")
            throw CLIClientError.classify(vendor, message: errorMessage + "\n" + stderr)
        }
        if code != 0 {
            logger.info("\(vendor.rawValue, privacy: .public) exited with \(code)")
            throw CLIClientError.classify(vendor, message: stderr.isEmpty ? "exit code \(code)" : stderr)
        }
        if !produced { throw CLIClientError.emptyResponse(vendor) }
    }

    // MARK: Short commands (status, models)

    struct CapturedOutput: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func capture(vendor: CLIVendor, executable: URL, arguments: [String], timeout: Duration) async throws -> CapturedOutput {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("lidia-cli-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }
        let process = try CLIProcess(
            executable: executable,
            arguments: arguments,
            environment: CLIInvocationBuilder.environment(for: vendor, executable: executable),
            workingDirectory: workDir,
            stdin: nil
        )
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { process.stop(.timeout) }
        }
        defer { timer.cancel() }
        var lines: [String] = []
        try await withTaskCancellationHandler {
            for try await line in process.lines { lines.append(line) }
        } onCancel: {
            process.stop(.cancelled)
        }
        let code = await process.exitCode()
        let stderr = await process.stderrText()
        if process.stopReason == .timeout {
            throw CLIClientError.timedOut(vendor, seconds: Int(timeout.components.seconds))
        }
        try Task.checkCancellation()
        return CapturedOutput(stdout: lines.joined(separator: "\n"), stderr: stderr, exitCode: code)
    }

    /// `codex debug models`: `{"models":[{"slug":…,"visibility":"list"|"hide"}]}`.
    static func parseCodexModels(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String else { return nil }
            if let visibility = model["visibility"] as? String, visibility != "list" { return nil }
            return slug
        }
    }

    /// `grok models`: lines like `  * grok-4.6 (default)` and `  - grok-4.5`.
    static func parseGrokModels(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("* ") || line.hasPrefix("- ") else { return nil }
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return rest.split(separator: " ").first.map(String.init)
        }
    }
}

// MARK: - Detection

/// Whether a subscription CLI is installed and signed in, for Settings.
struct CLIStatus: Sendable, Equatable {
    enum SignIn: Sendable, Equatable {
        case signedIn
        /// Codex signed in with an API key: calls would bill the key, not the plan.
        case apiKey
        case notSignedIn
        case unknown(String)
    }

    let executable: URL?
    let version: String?
    let signIn: SignIn
    /// How LidIA talks to it: "ACP" or "codex exec".
    var transport: String? = nil

    var isInstalled: Bool { executable != nil }
    var isReady: Bool { isInstalled && signIn == .signedIn }
}

enum CLIDetector {
    static func detect(_ vendor: CLIVendor) async -> CLIStatus {
        guard let executable = vendor.resolveExecutable() else {
            return CLIStatus(executable: nil, version: nil, signIn: .notSignedIn)
        }
        let version = try? await CLIChatClient.capture(vendor: vendor, executable: executable, arguments: ["--version"], timeout: .seconds(10))
        let versionLine = version?.stdout.split(separator: "\n").first.map(String.init)
        let signIn: CLIStatus.SignIn
        switch vendor {
        case .codex:
            if let output = try? await CLIChatClient.capture(vendor: vendor, executable: executable, arguments: ["login", "status"], timeout: .seconds(15)) {
                signIn = parseCodexLoginStatus(output.stdout + "\n" + output.stderr)
            } else {
                signIn = .unknown("Couldn't ask Codex.")
            }
        case .grok:
            if let output = try? await CLIChatClient.capture(vendor: vendor, executable: executable, arguments: ["models"], timeout: .seconds(20)) {
                signIn = parseGrokSignIn(output.stdout + "\n" + output.stderr, exitCode: output.exitCode)
            } else {
                signIn = .unknown("Couldn't ask the Grok CLI.")
            }
        }
        let transport: String?
        switch CLIChatClient(vendor: vendor).transport() {
        case .acp: transport = "ACP"
        case .headless: transport = "codex exec"
        case nil: transport = nil
        }
        return CLIStatus(executable: executable, version: versionLine, signIn: signIn, transport: transport)
    }

    /// `codex login status`: "Logged in using ChatGPT" / "Logged in using an API key" / "Not logged in".
    static func parseCodexLoginStatus(_ text: String) -> CLIStatus.SignIn {
        let lower = text.lowercased()
        if lower.contains("not logged in") { return .notSignedIn }
        if lower.contains("logged in using chatgpt") { return .signedIn }
        if lower.contains("api key") && lower.contains("logged in") { return .apiKey }
        if lower.contains("logged in") { return .signedIn }
        return .unknown(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `grok models` says "You are not authenticated." before the list when signed out.
    static func parseGrokSignIn(_ text: String, exitCode: Int32) -> CLIStatus.SignIn {
        let lower = text.lowercased()
        if lower.contains("not authenticated") || lower.contains("not signed in") { return .notSignedIn }
        return exitCode == 0 ? .signedIn : .unknown(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
