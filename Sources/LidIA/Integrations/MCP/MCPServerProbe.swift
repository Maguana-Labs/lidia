import Foundation
import os

// Finds the bundled LidiaMCP binary, checks that it answers over stdio, and
// finds the `claude` CLI. Process plumbing lives in `MCPProcessRunner`.

/// The `LidiaMCP` binary that ships next to the app's executable.
enum MCPServerBinary {
    /// `LidIA.app/Contents/MacOS/LidiaMCP` (or `.build/<config>/LidiaMCP` when run unbundled).
    static var defaultURL: URL {
        let directory = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent("Contents/MacOS", isDirectory: true)
        return directory.appendingPathComponent("LidiaMCP")
    }

    enum Status: Equatable, Sendable {
        case ready
        case missing
        case notExecutable
    }

    static func status(of url: URL) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        return fm.isExecutableFile(atPath: url.path) ? .ready : .notExecutable
    }
}

/// Launches the server, sends `initialize` and `tools/list`, and reports what it said.
enum MCPServerProbe {
    struct Result: Equatable, Sendable {
        var serverName: String?
        var serverVersion: String?
        var tools: [String]
    }

    enum ProbeError: LocalizedError, Equatable {
        case missingBinary
        case notExecutable
        case timedOut
        case noResponse(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .missingBinary: "The server isn't in the app bundle. Reinstall LidIA."
            case .notExecutable: "The server file can't be run. Reinstall LidIA."
            case .timedOut: "The server didn't answer within 10 seconds."
            case .noResponse(let detail): detail.isEmpty ? "The server didn't answer." : "The server didn't answer: \(detail)"
            case .serverError(let message): "The server returned an error: \(message)"
            }
        }
    }

    static func requests() -> Data {
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "LidIA Settings", "version": "1"],
                ],
            ],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ]
        var data = Data()
        for message in messages {
            if let line = try? JSONSerialization.data(withJSONObject: message) {
                data.append(line)
                data.append(0x0A)
            }
        }
        return data
    }

    static func probe(binary: URL, environment: [String: String]? = nil, timeout: TimeInterval = 10) async throws -> Result {
        switch MCPServerBinary.status(of: binary) {
        case .missing: throw ProbeError.missingBinary
        case .notExecutable: throw ProbeError.notExecutable
        case .ready: break
        }
        // Closing stdin after the requests makes the server exit on its own.
        let output = try await MCPProcessRunner.run(binary, arguments: [], environment: environment, input: requests(), timeout: timeout)
        if output.timedOut { throw ProbeError.timedOut }
        do {
            return try parse(output.stdout)
        } catch let error as ProbeError {
            if case .noResponse = error {
                let stderr = String(decoding: output.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ProbeError.noResponse(stderr.components(separatedBy: "\n").last ?? "")
            }
            throw error
        }
    }

    /// Reads the server's newline-delimited JSON-RPC replies.
    static func parse(_ stdout: Data) throws -> Result {
        var result = Result(tools: [])
        var sawInitialize = false
        var sawTools = false
        for line in stdout.split(separator: 0x0A) where !line.isEmpty {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let id = message["id"] as? Int
            if let error = message["error"] as? [String: Any] {
                throw ProbeError.serverError(error["message"] as? String ?? "unknown error")
            }
            guard let body = message["result"] as? [String: Any] else { continue }
            if id == 1 {
                sawInitialize = true
                let info = body["serverInfo"] as? [String: Any]
                result.serverName = info?["name"] as? String
                result.serverVersion = info?["version"] as? String
            } else if id == 2 {
                sawTools = true
                let tools = body["tools"] as? [[String: Any]] ?? []
                result.tools = tools.compactMap { $0["name"] as? String }
            }
        }
        guard sawInitialize, sawTools else { throw ProbeError.noResponse("") }
        return result
    }
}

/// Finds the `claude` command-line tool. GUI apps don't get the login shell's
/// PATH, so the usual install locations are checked first, then a login shell.
enum ClaudeCLILocator {
    static func candidates(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
    }

    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> MCPCommandLineTool? {
        let shellInfo = await loginShellInfo()
        let fm = FileManager.default
        var environment = ProcessInfo.processInfo.environment
        if let path = shellInfo.path { environment["PATH"] = path }

        if let found = candidates(home: home).first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return MCPCommandLineTool(url: found, environment: environment)
        }
        if let path = shellInfo.claude, fm.isExecutableFile(atPath: path) {
            return MCPCommandLineTool(url: URL(fileURLWithPath: path), environment: environment)
        }
        return nil
    }

    /// The login shell's PATH and `command -v claude`. Markers skip anything a profile prints.
    private static func loginShellInfo() async -> (path: String?, claude: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = #"printf '__LIDIA_PATH__=%s\n' "$PATH"; printf '__LIDIA_CLAUDE__=%s\n' "$(command -v claude)""#
        guard let output = try? await MCPProcessRunner.run(URL(fileURLWithPath: shell), arguments: ["-l", "-c", script], timeout: 5),
              !output.timedOut else { return (nil, nil) }
        var path: String?
        var claude: String?
        for line in String(decoding: output.stdout, as: UTF8.self).components(separatedBy: "\n") {
            if line.hasPrefix("__LIDIA_PATH__=") {
                path = String(line.dropFirst("__LIDIA_PATH__=".count))
            } else if line.hasPrefix("__LIDIA_CLAUDE__=") {
                let value = String(line.dropFirst("__LIDIA_CLAUDE__=".count))
                claude = value.hasPrefix("/") ? value : nil
            }
        }
        return (path?.isEmpty == false ? path : nil, claude)
    }
}

// MARK: - Process runner

/// Runs a short-lived process off the main thread with a timeout.
enum MCPProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runBlocking(executable, arguments, environment, input, timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
    }

    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ input: Data?,
        _ timeout: TimeInterval
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let box = Box()
        let group = DispatchGroup()
        let readOut = stdoutPipe.fileHandleForReading
        let readErr = stderrPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            let data = readOut.readDataToEndOfFile()
            box.lock.withLock { box.stdout = data }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let data = readErr.readDataToEndOfFile()
            box.lock.withLock { box.stderr = data }
            group.leave()
        }

        // A process that exits early must not kill LidIA with SIGPIPE.
        let writer = stdinPipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let input, !input.isEmpty {
            try? writer.write(contentsOf: input)
        }
        try? writer.close()

        let pid = process.processIdentifier
        let timer = DispatchWorkItem {
            box.lock.withLock { box.timedOut = true }
            kill(pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        process.waitUntilExit()
        timer.cancel()
        group.wait()

        return box.lock.withLock {
            Output(status: process.terminationStatus, stdout: box.stdout, stderr: box.stderr, timedOut: box.timedOut)
        }
    }
}
