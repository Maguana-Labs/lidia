import Foundation
import Testing
@testable import LidIA

// Config writers for connecting AI apps to LidIA's MCP server. Every test uses
// a temp "home" folder; the real config files on this Mac are never touched.

private struct TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidia-mcp-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func installer(binary: String = "/Applications/LidIA.app/Contents/MacOS/LidiaMCP") -> MCPClientInstaller {
        MCPClientInstaller(home: url, binaryPath: binary)
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func write(_ text: String, to path: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func json(_ path: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(path))) as? [String: Any])
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

private let claudeDesktopConfig = "Library/Application Support/Claude/claude_desktop_config.json"

private let unrelatedDesktopConfig = """
{
  "globalShortcut": "Alt+Space",
  "preferences": { "quickEntry": true, "nested": { "deep": [1, 2.5, "x", null, false] } },
  "mcpServers": {
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me"] }
  }
}
"""

@Suite("MCP client installer")
struct MCPClientInstallerTests {

    // MARK: JSON

    @Test("JSON connect keeps every unrelated key and server")
    func jsonMergePreservesKeys() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.write(unrelatedDesktopConfig, to: claudeDesktopConfig)
        let original = try home.json(claudeDesktopConfig)
        let installer = home.installer()

        #expect(installer.state(for: .claudeDesktop) == .readyToConnect)
        try await installer.connect(.claudeDesktop)
        #expect(installer.state(for: .claudeDesktop) == .connected)

        let updated = try home.json(claudeDesktopConfig)
        #expect(updated["globalShortcut"] as? String == "Alt+Space")
        #expect(NSDictionary(dictionary: updated["preferences"] as? [String: Any] ?? [:])
            .isEqual(to: original["preferences"] as? [String: Any] ?? [:]))
        let servers = try #require(updated["mcpServers"] as? [String: Any])
        #expect(NSDictionary(dictionary: servers["filesystem"] as? [String: Any] ?? [:])
            .isEqual(to: (original["mcpServers"] as? [String: Any])?["filesystem"] as? [String: Any] ?? [:]))
        let lidia = try #require(servers["lidia"] as? [String: Any])
        #expect(lidia["command"] as? String == installer.binaryPath)
        // Paths aren't escaped as \/.
        #expect(try home.read(claudeDesktopConfig).contains("\"/Applications/LidIA.app/Contents/MacOS/LidiaMCP\""))
    }

    @Test("JSON disconnect restores the original content")
    func jsonRemoveIsClean() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.write(unrelatedDesktopConfig, to: claudeDesktopConfig)
        let original = try home.json(claudeDesktopConfig)
        let installer = home.installer()

        try await installer.connect(.claudeDesktop)
        try await installer.disconnect(.claudeDesktop)

        #expect(NSDictionary(dictionary: try home.json(claudeDesktopConfig)).isEqual(to: original))
        #expect(installer.state(for: .claudeDesktop) == .readyToConnect)
    }

    @Test("Pi: connects in ~/.pi/agent/mcp.json under mcpServers, keeping other servers")
    func piConfig() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        let installer = home.installer()
        #expect(installer.state(for: .pi) == .notInstalled)
        try home.write(#"{"mcpServers":{"docs":{"url":"https://example.com/mcp"}}}"#, to: ".pi/agent/mcp.json")
        #expect(installer.state(for: .pi) == .readyToConnect)

        try await installer.connect(.pi)
        #expect(installer.state(for: .pi) == .connected)
        let servers = try #require(try home.json(".pi/agent/mcp.json")["mcpServers"] as? [String: Any])
        #expect(servers["docs"] != nil)
        #expect((servers["lidia"] as? [String: Any])?["command"] as? String == installer.binaryPath)

        try await installer.disconnect(.pi)
        #expect(installer.state(for: .pi) == .readyToConnect)
    }

    @Test("JSON disconnect drops a servers object LidIA created")
    func jsonRemoveDropsEmptyServers() throws {
        let original = Data(#"{"theme":"dark"}"#.utf8)
        let added = try MCPJSONConfig.adding(["command": "/x"], to: original, serversKey: "mcpServers")
        #expect(try MCPJSONConfig.command(in: added, serversKey: "mcpServers") == "/x")
        let removed = try #require(try MCPJSONConfig.removing(from: added, serversKey: "mcpServers"))
        let object = try MCPJSONConfig.object(from: removed)
        #expect(object.keys.sorted() == ["theme"])
        // Nothing to remove: no rewrite.
        #expect(try MCPJSONConfig.removing(from: original, serversKey: "mcpServers") == nil)
    }

    @Test("Missing or blank config files are created; malformed ones are left alone")
    func jsonMissingAndMalformed() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.makeDirectory(".cursor")
        let installer = home.installer()

        try await installer.connect(.cursor)
        #expect(installer.state(for: .cursor) == .connected)
        #expect(!home.exists(".cursor/mcp.json.bak"), "No backup when there was no original")

        try home.write("{ not json", to: ".codeium/windsurf/mcp_config.json")
        guard case .unreadable = installer.state(for: .windsurf) else {
            Issue.record("Expected unreadable"); return
        }
        await #expect(throws: MCPInstallError.self) { try await installer.connect(.windsurf) }
        #expect(try home.read(".codeium/windsurf/mcp_config.json") == "{ not json")
    }

    @Test("First edit keeps a .bak of the original, later edits don't replace it")
    func backupOnFirstEdit() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.write(unrelatedDesktopConfig, to: claudeDesktopConfig)
        let installer = home.installer()

        try await installer.connect(.claudeDesktop)
        try await installer.disconnect(.claudeDesktop)
        try await installer.connect(.claudeDesktop)
        #expect(try home.read(claudeDesktopConfig + ".bak") == unrelatedDesktopConfig)
    }

    @Test("Writes keep file permissions and go through symlinks")
    func permissionsAndSymlinks() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.write(#"{"userID":"abc"}"#, to: "dotfiles/claude.json")
        let real = home.url.appendingPathComponent("dotfiles/claude.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent(".claude.json"), withDestinationURL: real)
        let installer = home.installer()

        try await installer.connect(.claudeCode)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.url.appendingPathComponent(".claude.json").path)
        #expect(link == real.path)
        let permissions = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let lidia = try #require((try home.json("dotfiles/claude.json")["mcpServers"] as? [String: Any])?["lidia"] as? [String: Any])
        #expect(lidia["type"] as? String == "stdio")
        #expect(try home.json("dotfiles/claude.json")["userID"] as? String == "abc")
    }

    @Test("VS Code uses the servers key with a stdio type")
    func vsCodeFormat() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.write(#"{"inputs":[],"servers":{"other":{"type":"http","url":"https://example.com"}}}"#, to: "Library/Application Support/Code/User/mcp.json")
        let installer = home.installer()

        try await installer.connect(.vsCode)
        let servers = try #require(try home.json("Library/Application Support/Code/User/mcp.json")["servers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["lidia", "other"])
        #expect((servers["lidia"] as? [String: Any])?["type"] as? String == "stdio")
        #expect(!(try home.json("Library/Application Support/Code/User/mcp.json").keys.contains("mcpServers")))
    }

    // MARK: Detection

    @Test("Apps without their folder are not installed")
    func notInstalled() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        let installer = home.installer()
        for client in MCPClient.allCases {
            #expect(installer.state(for: client) == .notInstalled)
        }
        await #expect(throws: MCPInstallError.notInstalled("Cursor")) { try await installer.connect(.cursor) }
        #expect(!home.exists(".cursor"))
    }

    @Test("A connected app pointing at an old binary needs an update")
    func stalePathDetection() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.makeDirectory(".cursor")
        try home.makeDirectory(".codex")
        let old = home.installer(binary: "/Users/me/Downloads/LidIA.app/Contents/MacOS/LidiaMCP")
        try await old.connect(.cursor)
        try await old.connect(.codex)

        let current = home.installer()
        #expect(current.state(for: .cursor) == .needsUpdate(configuredPath: old.binaryPath))
        #expect(current.state(for: .codex) == .needsUpdate(configuredPath: old.binaryPath))
        #expect(old.state(for: .cursor) == .connected)

        // Update rewrites the entry in place.
        try await current.connect(.cursor)
        try await current.connect(.codex)
        #expect(current.state(for: .cursor) == .connected)
        #expect(current.state(for: .codex) == .connected)
        #expect(try home.read(".codex/config.toml").components(separatedBy: "[mcp_servers.lidia]").count == 2)

        // Equivalent spellings of the same path still count as connected.
        #expect(MCPClientInstaller.samePath("/Applications/LidIA.app/Contents/MacOS/../MacOS/LidiaMCP", current.binaryPath))
        #expect(!MCPClientInstaller.samePath("", current.binaryPath))
    }

    @Test("An entry without a command is reported as needing an update")
    func entryWithoutCommand() throws {
        let data = Data(#"{"mcpServers":{"lidia":{"url":"http://x"}}}"#.utf8)
        #expect(try MCPJSONConfig.command(in: data, serversKey: "mcpServers") == "")
        #expect(throws: MCPJSONConfig.Malformed.self) {
            try MCPJSONConfig.command(in: Data(#"{"mcpServers":[]}"#.utf8), serversKey: "mcpServers")
        }
        #expect(try MCPJSONConfig.command(in: nil, serversKey: "mcpServers") == nil)
        #expect(try MCPJSONConfig.command(in: Data("  \n".utf8), serversKey: "mcpServers") == nil)
    }

    // MARK: TOML

    private let codexConfig = """
    model = "gpt-5"
    approval_policy = "on-request"

    [mcp_servers.github]
    command = "github-mcp"
    args = ["stdio"]

    [profiles.fast]
    model = "gpt-5-mini"

    """

    @Test("TOML add then remove gives back the original file")
    func tomlRoundTrip() {
        let added = MCPTOMLConfig.adding(command: "/Apps/LidIA.app/Contents/MacOS/LidiaMCP", to: codexConfig)
        #expect(added.hasPrefix(codexConfig))
        #expect(added.hasSuffix("[mcp_servers.lidia]\ncommand = \"/Apps/LidIA.app/Contents/MacOS/LidiaMCP\"\n"))
        #expect(MCPTOMLConfig.command(in: added) == "/Apps/LidIA.app/Contents/MacOS/LidiaMCP")
        #expect(MCPTOMLConfig.command(in: codexConfig) == nil)
        #expect(MCPTOMLConfig.removing(from: added) == codexConfig)
        // Nothing to remove leaves the text untouched.
        #expect(MCPTOMLConfig.removing(from: codexConfig) == codexConfig)
        #expect(MCPTOMLConfig.removing(from: MCPTOMLConfig.adding(command: "/x", to: "")) == "")
    }

    @Test("TOML remove takes the lidia table and its sub-tables from the middle of a file")
    func tomlRemoveFromMiddle() {
        let text = """
        model = "gpt-5"

        [ mcp_servers."lidia" ]
        command = 'C:\\literal\\path'
        startup_timeout_sec = 20

        [mcp_servers.lidia.env]
        LIDIA_STORE_PATH = "/tmp/x"

        [mcp_servers.lidia-other]
        command = "keep-me"

        [[profiles.list]]
        name = "a"

        """
        #expect(MCPTOMLConfig.command(in: text) == "C:\\literal\\path")
        let removed = MCPTOMLConfig.removing(from: text)
        #expect(removed == """
        model = "gpt-5"

        [mcp_servers.lidia-other]
        command = "keep-me"

        [[profiles.list]]
        name = "a"

        """)
    }

    @Test("TOML strings are escaped and read back")
    func tomlEscaping() {
        let path = #"/Users/me/My "Apps"/back\slash/LidiaMCP"#
        let added = MCPTOMLConfig.adding(command: path, to: "")
        #expect(added == "[mcp_servers.lidia]\ncommand = \"/Users/me/My \\\"Apps\\\"/back\\\\slash/LidiaMCP\"\n")
        #expect(MCPTOMLConfig.command(in: added) == path)
    }

    @Test("Codex connect and disconnect leave the rest of config.toml as it was")
    func codexEndToEnd() async throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.write(codexConfig, to: ".codex/config.toml")
        let installer = home.installer()

        #expect(installer.state(for: .codex) == .readyToConnect)
        try await installer.connect(.codex)
        #expect(installer.state(for: .codex) == .connected)
        try await installer.disconnect(.codex)
        #expect(try home.read(".codex/config.toml") == codexConfig)
        #expect(try home.read(".codex/config.toml.bak") == codexConfig)
    }

    // MARK: Snippets

    @Test("Copy Config snippets are valid and point at the binary")
    func snippets() throws {
        let json = MCPJSONConfig.snippet(command: "/A/LidiaMCP")
        #expect(try MCPJSONConfig.command(in: Data(json.utf8), serversKey: "mcpServers") == "/A/LidiaMCP")
        let vsCode = MCPJSONConfig.snippet(command: "/A/LidiaMCP", serversKey: "servers", style: .typedStdio)
        #expect(try MCPJSONConfig.command(in: Data(vsCode.utf8), serversKey: "servers") == "/A/LidiaMCP")
        #expect(MCPTOMLConfig.command(in: MCPTOMLConfig.table(command: "/A/LidiaMCP")) == "/A/LidiaMCP")
    }
}

// MARK: - Server probe

@Suite("MCP server probe")
struct MCPServerProbeTests {
    /// `.build/<config>/LidiaMCP`, next to the test bundle.
    static let binary: URL? = {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("LidiaMCP"))
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/LidiaMCP"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    @Test("Parses initialize and tools/list replies")
    func parse() throws {
        let output = """
        {"id":1,"jsonrpc":"2.0","result":{"serverInfo":{"name":"lidia-mcp","version":"1.1.0"}}}
        not json
        {"id":2,"jsonrpc":"2.0","result":{"tools":[{"name":"a"},{"name":"b"}]}}
        """
        let result = try MCPServerProbe.parse(Data(output.utf8))
        #expect(result == MCPServerProbe.Result(serverName: "lidia-mcp", serverVersion: "1.1.0", tools: ["a", "b"]))

        #expect(throws: MCPServerProbe.ProbeError.self) { try MCPServerProbe.parse(Data()) }
        let failing = #"{"id":2,"jsonrpc":"2.0","error":{"code":-32601,"message":"nope"}}"#
        #expect(throws: MCPServerProbe.ProbeError.serverError("nope")) { try MCPServerProbe.parse(Data(failing.utf8)) }
    }

    @Test("A missing binary is reported, not launched")
    func missingBinary() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(MCPServerBinary.status(of: url) == .missing)
        await #expect(throws: MCPServerProbe.ProbeError.missingBinary) {
            try await MCPServerProbe.probe(binary: url)
        }
    }

    @Test("The built server answers with its own tool list", .enabled(if: binary != nil, "LidiaMCP binary not built"))
    func probeRealBinary() async throws {
        let binary = try #require(Self.binary)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = ProcessInfo.processInfo.environment
        // No store here: the server still starts and lists its tools.
        env["LIDIA_STORE_PATH"] = dir.appendingPathComponent("missing.store").path
        env["LIDIA_MCP_INBOX"] = dir.appendingPathComponent("inbox").path

        let result = try await MCPServerProbe.probe(binary: binary, environment: env)
        #expect(result.serverName == "lidia-mcp")
        #expect(result.tools.contains("search_meetings"))
        #expect(result.tools.count >= 5)
    }
}
