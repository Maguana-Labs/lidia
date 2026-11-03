import Foundation
import os

// MARK: - Agents

/// An agent LidIA can talk to over the Agent Client Protocol
/// (https://agentclientprotocol.com): JSON-RPC 2.0, one message per line,
/// over the agent's stdin/stdout.
///
/// Today: Grok (`grok agent stdio`, native) and Codex through Zed's
/// `codex-acp` adapter when it's installed. Any other ACP agent (Gemini CLI,
/// Goose, …) becomes a provider by adding a spec here. Not Claude Code:
/// Anthropic's terms don't allow third-party apps to use claude.ai logins.
struct ACPAgentSpec: Sendable, Equatable {
    let vendor: CLIVendor
    let executable: URL
    let arguments: [String]

    /// The ACP agent for a vendor, if one is installed.
    static func find(for vendor: CLIVendor, environment: [String: String] = ProcessInfo.processInfo.environment) -> ACPAgentSpec? {
        switch vendor {
        case .grok:
            guard let grok = vendor.resolveExecutable(environment: environment) else { return nil }
            return ACPAgentSpec(vendor: .grok, executable: grok, arguments: ["agent", "--no-leader", "stdio"])
        case .codex:
            guard let adapter = codexACPAdapter(environment: environment) else { return nil }
            return ACPAgentSpec(vendor: .codex, executable: adapter, arguments: [])
        }
    }

    /// Zed's `codex-acp` adapter on PATH or in the usual install folders.
    /// Never fetched on demand (no `npx`): LidIA only runs what's installed.
    static func codexACPAdapter(environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/.npm-global/bin"]
        dirs += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let path = "\(dir)/codex-acp"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

// MARK: - Protocol turn

/// What the runner should do after an agent message.
enum ACPAction: Equatable, Sendable {
    /// Write this line to the agent.
    case send(Data)
    /// Answer text to show.
    case text(String)
    /// The turn ended (`session/prompt` returned this stop reason).
    case finished(stopReason: String)
    case failed(CLIClientError)
}

/// One prompt turn as a pure state machine: feed it the agent's lines, run
/// the actions it returns. No I/O, so it is tested with recorded traffic.
///
/// initialize → session/new → (session/set_config_option for model and
/// effort, when the agent offers them) → session/prompt, streaming
/// `session/update` `agent_message_chunk`s as text.
///
/// LidIA only wants text: every `session/request_permission` is answered
/// with a reject option, filesystem and terminal requests are refused
/// (the client advertises neither), and a tool call ends the turn.
struct ACPTurn {
    enum Phase: Equatable { case initializing, creatingSession, configuring, prompting, done }

    let vendor: CLIVendor
    let workingDirectory: String
    let prompt: String
    let model: String
    let effort: String

    private(set) var phase: Phase = .initializing
    private(set) var sessionId: String?
    private var nextID = 1
    private var pendingConfigIDs: Set<Int> = []
    private var promptID: Int?
    private(set) var toolCallAttempted = false

    init(vendor: CLIVendor, workingDirectory: String, prompt: String, model: String, effort: String) {
        self.vendor = vendor
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.model = model
        self.effort = effort
    }

    static let protocolVersion = 1
    static let authRequiredCode = -32000

    mutating func start() -> [ACPAction] {
        [.send(request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "lidia", "title": "LidIA", "version": "1"],
        ]))]
    }

    /// `session/cancel` for the current turn, if one is running.
    func cancelMessage() -> Data? {
        guard let sessionId, phase == .prompting else { return nil }
        return Self.encode(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]])
    }

    mutating func consume(_ line: String) -> [ACPAction] {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let method = message["method"] as? String
        let id = message["id"]

        // Agent → client request.
        if let method, let id {
            return [.send(answer(request: method, id: id, params: message["params"] as? [String: Any] ?? [:]))]
        }
        // Notification.
        if let method {
            guard method == "session/update",
                  let update = (message["params"] as? [String: Any])?["update"] as? [String: Any] else { return [] }
            return handle(update: update)
        }
        // Response to one of ours.
        guard let responseID = (id as? Int) ?? (id as? NSNumber)?.intValue else { return [] }
        if let error = message["error"] as? [String: Any] {
            return handle(error: error, for: responseID)
        }
        return handle(result: message["result"] as? [String: Any] ?? [:], for: responseID)
    }

    // MARK: Responses

    private mutating func handle(result: [String: Any], for id: Int) -> [ACPAction] {
        switch phase {
        case .initializing where id == 1:
            phase = .creatingSession
            return [.send(request("session/new", ["cwd": workingDirectory, "mcpServers": [Any]()]))]
        case .creatingSession:
            guard let session = result["sessionId"] as? String else {
                phase = .done
                return [.failed(.failed(vendor, "the agent didn't start a session"))]
            }
            sessionId = session
            let configs = configRequests(from: result["configOptions"] as? [[String: Any]] ?? [], sessionId: session)
            if configs.isEmpty { return sendPrompt() }
            phase = .configuring
            return configs.map { .send($0) }
        case .configuring:
            pendingConfigIDs.remove(id)
            return pendingConfigIDs.isEmpty ? sendPrompt() : []
        case .prompting where id == promptID:
            phase = .done
            let stop = result["stopReason"] as? String ?? "end_turn"
            if toolCallAttempted {
                return [.failed(.failed(vendor, "the agent tried to use a tool, so LidIA stopped it"))]
            }
            if stop == "refusal" { return [.failed(.failed(vendor, "the model declined to answer"))] }
            return [.finished(stopReason: stop)]
        default:
            return []
        }
    }

    private mutating func handle(error: [String: Any], for id: Int) -> [ACPAction] {
        let code = (error["code"] as? Int) ?? (error["code"] as? NSNumber)?.intValue ?? 0
        let text = [error["message"] as? String, error["data"] as? String].compactMap { $0 }.joined(separator: ": ")
        switch phase {
        case .configuring where pendingConfigIDs.contains(id):
            // A model or effort the agent won't take: keep its default.
            pendingConfigIDs.remove(id)
            return pendingConfigIDs.isEmpty ? sendPrompt() : []
        default:
            phase = .done
            if code == Self.authRequiredCode || text.lowercased().contains("auth") {
                return [.failed(.notSignedIn(vendor))]
            }
            return [.failed(CLIClientError.classify(vendor, message: text.isEmpty ? "error \(code)" : text))]
        }
    }

    private mutating func sendPrompt() -> [ACPAction] {
        guard let sessionId else { return [] }
        phase = .prompting
        let id = nextID
        promptID = id
        return [.send(request("session/prompt", [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": prompt]],
        ]))]
    }

    /// `session/set_config_option` for the model (category `model`) and the
    /// reasoning effort (category `thought_level`), when offered with a
    /// matching value.
    private mutating func configRequests(from options: [[String: Any]], sessionId: String) -> [Data] {
        var requests: [Data] = []
        for option in options {
            guard let configID = option["id"] as? String else { continue }
            let category = (option["category"] as? String ?? "").lowercased()
            let values = Self.optionValues(option["options"])
            var wanted: String?
            if category == "model", !CLIVendor.isDefaultModel(model), values.contains(model) {
                wanted = model
            } else if category == "thought_level" || configID.lowercased().contains("effort") {
                wanted = values.contains(effort) ? effort : nil
            }
            guard let wanted, (option["currentValue"] as? String) != wanted else { continue }
            pendingConfigIDs.insert(nextID)
            requests.append(request("session/set_config_option", ["sessionId": sessionId, "configId": configID, "value": wanted]))
        }
        return requests
    }

    /// Values of a select option: a flat list, or groups of lists.
    static func optionValues(_ raw: Any?) -> [String] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.flatMap { entry -> [String] in
            if let value = entry["value"] as? String { return [value] }
            return optionValues(entry["options"])
        }
    }

    // MARK: Updates and requests

    private mutating func handle(update: [String: Any]) -> [ACPAction] {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                  let text = content["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "tool_call":
            // Text only: stop the turn rather than let a tool run.
            guard !toolCallAttempted else { return [] }
            toolCallAttempted = true
            return cancelMessage().map { [.send($0)] } ?? []
        default:
            return []
        }
    }

    private func answer(request method: String, id: Any, params: [String: Any]) -> Data {
        guard method == "session/request_permission" else {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "LidIA doesn't offer \(method)"]])
        }
        let options = params["options"] as? [[String: Any]] ?? []
        let reject = options.first { $0["kind"] as? String == "reject_once" }
            ?? options.first { $0["kind"] as? String == "reject_always" }
        let outcome: [String: Any] = reject.flatMap { $0["optionId"] as? String }
            .map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
    }

    private mutating func request(_ method: String, _ params: [String: Any]) -> Data {
        let id = nextID
        nextID += 1
        return Self.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}

// MARK: - Runner

enum ACPRunner {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "ACPClient")

    /// Runs one prompt turn against an ACP agent in an empty temporary folder.
    /// Kills the agent when the turn ends, times out or is cancelled.
    static func run(
        spec: ACPAgentSpec,
        prompt: String,
        model: String,
        effort: String,
        timeout: Duration,
        onText: @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("lidia-acp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }

        let process = try CLIProcess(
            executable: spec.executable,
            arguments: spec.arguments,
            environment: CLIInvocationBuilder.environment(for: spec.vendor, executable: spec.executable),
            workingDirectory: workDir,
            stdin: nil,
            interactive: true
        )
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { process.stop(.timeout) }
        }
        defer { timer.cancel() }

        var turn = ACPTurn(vendor: spec.vendor, workingDirectory: workDir.path, prompt: prompt, model: model, effort: effort)
        let cancelBox = OSAllocatedUnfairLock<Data?>(initialState: nil)
        for action in turn.start() { if case .send(let data) = action { process.send(data) } }

        var outcome: Result<String, CLIClientError>?
        try await withTaskCancellationHandler {
            lineLoop: for try await line in process.lines {
                for action in turn.consume(line) {
                    switch action {
                    case .send(let data): process.send(data)
                    case .text(let text): onText(text)
                    case .finished(let stop):
                        outcome = .success(stop)
                    case .failed(let error):
                        outcome = .failure(error)
                    }
                }
                let cancel = turn.cancelMessage()
                cancelBox.withLock { $0 = cancel }
                if outcome != nil { break lineLoop }
            }
        } onCancel: {
            // Ask the agent to stop the turn, then end it.
            if let cancel = cancelBox.withLock({ $0 }) { process.send(cancel) }
            process.stop(.cancelled)
        }
        process.stop(.finished)
        _ = await process.exitCode()
        // A finished turn needs nothing from stderr. Reading it to the end would
        // wait for any grandchild that inherited the pipe (e.g. a helper the CLI
        // spawned), long after the agent itself exited.
        let stderr = outcome == nil ? await process.stderrText() : ""

        switch process.stopReason {
        case .cancelled: throw CancellationError()
        case .timeout: throw CLIClientError.timedOut(spec.vendor, seconds: Int(timeout.components.seconds))
        case .none, .finished: break
        }
        try Task.checkCancellation()
        switch outcome {
        case .success: return
        case .failure(let error):
            logger.info("ACP turn with \(spec.vendor.rawValue, privacy: .public) failed")
            throw error
        case nil:
            throw CLIClientError.classify(spec.vendor, message: stderr.isEmpty ? "the agent stopped before answering" : stderr)
        }
    }
}
