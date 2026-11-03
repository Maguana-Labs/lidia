import Foundation

// Connects LidIA's bundled stdio MCP server (`LidiaMCP`) to AI apps on this Mac.
//
// Each app keeps its MCP servers in its own config file. The writers here only
// touch LidIA's own entry (`lidia`) and keep everything else in the file as is.
// Everything takes a home directory so tests can point it at a temp folder.

/// An app that can run LidIA's MCP server.
enum MCPClient: String, CaseIterable, Identifiable, Sendable {
    case claudeDesktop
    case claudeCode
    case cursor
    case vsCode
    case codex
    case windsurf
    /// Pi (pi.dev), Mario Zechner's minimal agent: native MCP since its
    /// `mcp.json` support, user-level servers in `~/.pi/agent/mcp.json`.
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .vsCode: "VS Code"
        case .codex: "Codex"
        case .windsurf: "Windsurf"
        case .pi: "Pi"
        }
    }

    /// What to do after connecting so the app picks LidIA up.
    var afterConnectHint: String {
        switch self {
        case .claudeDesktop: "Quit and reopen Claude to load LidIA."
        case .claudeCode, .codex: "Start a new session to use LidIA."
        case .cursor, .vsCode, .windsurf: "Reload the window if LidIA doesn't show up."
        case .pi: "Run /reload in Pi, or start a new session."
        }
    }
}

/// Whether an app is set up to use LidIA's MCP server.
enum MCPClientState: Equatable, Sendable {
    /// The app isn't on this Mac.
    case notInstalled
    case readyToConnect
    case connected
    /// Connected, but to a LidiaMCP somewhere else (the app moved).
    case needsUpdate(configuredPath: String)
    /// The config file exists but couldn't be read.
    case unreadable(String)
}

/// How an app's config file stores MCP servers.
enum MCPConfigFormat: Equatable, Sendable {
    /// A JSON object under `serversKey`, keyed by server name.
    case json(serversKey: String, style: MCPJSONEntryStyle)
    /// Codex's `config.toml`: a `[mcp_servers.lidia]` table.
    case toml
}

enum MCPJSONEntryStyle: Equatable, Sendable {
    /// `{"command": path}`: Claude Desktop, Cursor, Windsurf, Pi.
    case command
    /// `{"type": "stdio", "command": path, ...}`: VS Code, Claude Code.
    case typedStdio
}

/// The `claude` command-line tool and the environment to run it with.
struct MCPCommandLineTool: Equatable, Sendable {
    let url: URL
    var environment: [String: String]? = nil
}

enum MCPInstallError: LocalizedError, Equatable {
    case notInstalled(String)
    case malformedConfig(path: String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let app): "\(app) isn't installed on this Mac."
        case .malformedConfig(let path): "Couldn't read \((path as NSString).abbreviatingWithTildeInPath). Fix the file or add LidIA by hand with Copy Config."
        case .commandFailed(let message): message
        }
    }
}

// MARK: - Installer

struct MCPClientInstaller: Sendable {
    static let serverName = "lidia"

    let home: URL
    let binaryPath: String
    /// When set, Claude Code is configured through `claude mcp add/remove`.
    var claudeCLI: MCPCommandLineTool?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, binaryPath: String, claudeCLI: MCPCommandLineTool? = nil) {
        self.home = home
        self.binaryPath = binaryPath
        self.claudeCLI = claudeCLI
    }

    // MARK: Locations

    /// The folder whose presence means the app is installed.
    func appDirectory(for client: MCPClient) -> URL {
        switch client {
        case .claudeDesktop: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        case .claudeCode: home.appendingPathComponent(".claude", isDirectory: true)
        case .cursor: home.appendingPathComponent(".cursor", isDirectory: true)
        case .vsCode: home.appendingPathComponent("Library/Application Support/Code", isDirectory: true)
        case .codex: home.appendingPathComponent(".codex", isDirectory: true)
        case .windsurf: home.appendingPathComponent(".codeium/windsurf", isDirectory: true)
        case .pi: home.appendingPathComponent(".pi/agent", isDirectory: true)
        }
    }

    func configFile(for client: MCPClient) -> URL {
        switch client {
        case .claudeDesktop: appDirectory(for: client).appendingPathComponent("claude_desktop_config.json")
        case .claudeCode: home.appendingPathComponent(".claude.json")
        case .cursor: appDirectory(for: client).appendingPathComponent("mcp.json")
        case .vsCode: appDirectory(for: client).appendingPathComponent("User/mcp.json")
        case .codex: appDirectory(for: client).appendingPathComponent("config.toml")
        case .windsurf: appDirectory(for: client).appendingPathComponent("mcp_config.json")
        case .pi: appDirectory(for: client).appendingPathComponent("mcp.json")
        }
    }

    func format(for client: MCPClient) -> MCPConfigFormat {
        switch client {
        case .claudeDesktop, .cursor, .windsurf, .pi: .json(serversKey: "mcpServers", style: .command)
        case .claudeCode: .json(serversKey: "mcpServers", style: .typedStdio)
        case .vsCode: .json(serversKey: "servers", style: .typedStdio)
        case .codex: .toml
        }
    }

    func isInstalled(_ client: MCPClient) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: appDirectory(for: client).path) { return true }
        if client == .claudeCode {
            return claudeCLI != nil || fm.fileExists(atPath: configFile(for: client).path)
        }
        return false
    }

    // MARK: State

    /// The command LidIA's entry points at, `""` if the entry has none, or nil when not connected.
    func configuredCommand(for client: MCPClient) throws -> String? {
        let file = configFile(for: client)
        switch format(for: client) {
        case .json(let key, _):
            let data = try Self.read(file)
            do {
                return try MCPJSONConfig.command(in: data, serversKey: key)
            } catch {
                throw MCPInstallError.malformedConfig(path: file.path)
            }
        case .toml:
            guard let data = try Self.read(file) else { return nil }
            guard let text = String(data: data, encoding: .utf8) else {
                throw MCPInstallError.malformedConfig(path: file.path)
            }
            return MCPTOMLConfig.command(in: text)
        }
    }

    func state(for client: MCPClient) -> MCPClientState {
        guard isInstalled(client) else { return .notInstalled }
        do {
            guard let command = try configuredCommand(for: client) else { return .readyToConnect }
            return Self.samePath(command, binaryPath) ? .connected : .needsUpdate(configuredPath: command)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    func states() -> [MCPClient: MCPClientState] {
        Dictionary(uniqueKeysWithValues: MCPClient.allCases.map { ($0, state(for: $0)) })
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    // MARK: Connect / disconnect

    /// Adds LidIA, or points an existing entry at the current binary.
    func connect(_ client: MCPClient) async throws {
        guard isInstalled(client) else { throw MCPInstallError.notInstalled(client.displayName) }
        if client == .claudeCode, let cli = claudeCLI {
            // `add` refuses to overwrite, so clear any old entry first.
            _ = try? await runCLI(cli, ["mcp", "remove", "--scope", "user", Self.serverName])
            try await runCLI(cli, ["mcp", "add", "--scope", "user", Self.serverName, "--", binaryPath])
            return
        }
        let file = configFile(for: client)
        switch format(for: client) {
        case .json(let key, let style):
            let existing = try Self.read(file)
            let updated: Data
            do {
                updated = try MCPJSONConfig.adding(MCPJSONConfig.entry(command: binaryPath, style: style), to: existing, serversKey: key)
            } catch {
                throw MCPInstallError.malformedConfig(path: file.path)
            }
            try Self.write(updated, to: file)
        case .toml:
            let text = try Self.readText(file)
            try Self.write(Data(MCPTOMLConfig.adding(command: binaryPath, to: text).utf8), to: file)
        }
    }

    func disconnect(_ client: MCPClient) async throws {
        if client == .claudeCode, let cli = claudeCLI {
            try await runCLI(cli, ["mcp", "remove", "--scope", "user", Self.serverName])
            return
        }
        let file = configFile(for: client)
        switch format(for: client) {
        case .json(let key, _):
            let existing = try Self.read(file)
            let updated: Data?
            do {
                updated = try MCPJSONConfig.removing(from: existing, serversKey: key)
            } catch {
                throw MCPInstallError.malformedConfig(path: file.path)
            }
            if let updated { try Self.write(updated, to: file) }
        case .toml:
            let text = try Self.readText(file)
            let updated = MCPTOMLConfig.removing(from: text)
            if updated != text { try Self.write(Data(updated.utf8), to: file) }
        }
    }

    @discardableResult
    private func runCLI(_ cli: MCPCommandLineTool, _ arguments: [String]) async throws -> MCPProcessRunner.Output {
        let output = try await MCPProcessRunner.run(cli.url, arguments: arguments, environment: cli.environment, timeout: 30)
        guard output.status == 0, !output.timedOut else {
            let message = (String(data: output.stderr, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = output.timedOut ? "`claude` didn't finish in time." : "`claude` exited with status \(output.status)."
            throw MCPInstallError.commandFailed(message.isEmpty ? fallback : message)
        }
        return output
    }

    // MARK: File access

    /// The file's contents, or nil if it doesn't exist.
    static func read(_ url: URL) throws -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return try Data(contentsOf: resolved)
    }

    private static func readText(_ url: URL) throws -> String {
        guard let data = try read(url) else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPInstallError.malformedConfig(path: url.path)
        }
        return text
    }

    /// Writes atomically, keeping the file's permissions and a one-time
    /// `<name>.bak` of the original. Symlinked configs are written through.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        var permissions: Any?
        if fm.fileExists(atPath: target.path) {
            permissions = try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]
            let backup = URL(fileURLWithPath: target.path + ".bak")
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: target, to: backup)
            }
        }
        try data.write(to: target, options: .atomic)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }
}

// MARK: - JSON configs

/// Edits LidIA's entry in a JSON MCP config, leaving every other key alone.
enum MCPJSONConfig {
    struct Malformed: Error {}

    static func entry(command: String, style: MCPJSONEntryStyle) -> [String: Any] {
        switch style {
        case .command:
            ["command": command]
        case .typedStdio:
            ["type": "stdio", "command": command, "args": [String](), "env": [String: String]()]
        }
    }

    /// Parses a config; a missing or blank file is an empty object.
    static func object(from data: Data?) throws -> [String: Any] {
        guard let data, !String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Malformed() }
        return object
    }

    static func command(in data: Data?, serversKey: String) throws -> String? {
        let object = try object(from: data)
        guard let rawServers = object[serversKey] else { return nil }
        guard let servers = rawServers as? [String: Any] else { throw Malformed() }
        guard let entry = servers[MCPClientInstaller.serverName] else { return nil }
        return (entry as? [String: Any])?["command"] as? String ?? ""
    }

    static func adding(_ entry: [String: Any], to data: Data?, serversKey: String) throws -> Data {
        var object = try object(from: data)
        var servers: [String: Any] = [:]
        if let existing = object[serversKey] {
            guard let existing = existing as? [String: Any] else { throw Malformed() }
            servers = existing
        }
        servers[MCPClientInstaller.serverName] = entry
        object[serversKey] = servers
        return try serialize(object)
    }

    /// The config without LidIA's entry, or nil when there was nothing to remove.
    /// Drops the servers object too if LidIA was its only entry.
    static func removing(from data: Data?, serversKey: String) throws -> Data? {
        var object = try object(from: data)
        guard let rawServers = object[serversKey] else { return nil }
        guard var servers = rawServers as? [String: Any] else { throw Malformed() }
        guard servers.removeValue(forKey: MCPClientInstaller.serverName) != nil else { return nil }
        object[serversKey] = servers.isEmpty ? nil : servers
        return try serialize(object)
    }

    static func serialize(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// A config snippet for apps not listed here.
    static func snippet(command: String, serversKey: String = "mcpServers", style: MCPJSONEntryStyle = .command) -> String {
        let data = (try? serialize([serversKey: [MCPClientInstaller.serverName: entry(command: command, style: style)]])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - TOML (Codex)

/// Adds and removes the `[mcp_servers.lidia]` table in Codex's `config.toml`.
/// Only that table (and its sub-tables) is touched; the rest of the file is kept verbatim.
enum MCPTOMLConfig {
    static let tableName = "mcp_servers.\(MCPClientInstaller.serverName)"

    static func table(command: String) -> String {
        "[\(tableName)]\ncommand = \(quoted(command))\n"
    }

    static func command(in text: String) -> String? {
        var inTable = false
        var found = false
        for line in text.components(separatedBy: "\n") {
            if let name = headerName(line) {
                inTable = name == tableName
                found = found || inTable
                continue
            }
            guard inTable else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command") else { continue }
            let rest = trimmed.dropFirst("command".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            return unquoted(rest.dropFirst().trimmingCharacters(in: .whitespaces)) ?? ""
        }
        return found ? "" : nil
    }

    static func adding(command: String, to text: String) -> String {
        var base = removing(from: text)
        while base.hasSuffix("\n") { base.removeLast() }
        return base.isEmpty ? table(command: command) : base + "\n\n" + table(command: command)
    }

    static func removing(from text: String) -> String {
        var kept: [String] = []
        var inTable = false
        var removedAny = false
        for line in text.components(separatedBy: "\n") {
            if let name = headerName(line) {
                inTable = isLidIATable(name)
            }
            if inTable { removedAny = true } else { kept.append(line) }
        }
        guard removedAny else { return text }
        var result = kept.joined(separator: "\n")
        while result.hasSuffix("\n") { result.removeLast() }
        return result.isEmpty ? "" : result + "\n"
    }

    private static func isLidIATable(_ name: String) -> Bool {
        name == tableName || name.hasPrefix(tableName + ".")
    }

    /// `mcp_servers.lidia` for `[mcp_servers.lidia]`, `[ mcp_servers."lidia" ]` or `[[…]]`; nil for other lines.
    private static func headerName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        let inner = trimmed.drop { $0 == "[" }
        guard let close = inner.firstIndex(of: "]") else { return nil }
        return String(inner[..<close]).filter { $0 != " " && $0 != "\t" && $0 != "\"" && $0 != "'" }
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The value of a basic (`"…"`) or literal (`'…'`) TOML string.
    private static func unquoted(_ value: String) -> String? {
        if value.hasPrefix("'") {
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return nil }
            return String(body[..<end])
        }
        guard value.hasPrefix("\"") else { return nil }
        var result = ""
        var escaping = false
        for character in value.dropFirst() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }
}
