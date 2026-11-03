import AppKit
import SwiftUI

/// State behind the "LidIA MCP server" settings section.
@MainActor
@Observable
final class MCPSettingsModel {
    enum TestState: Equatable {
        case idle
        case running
        case working(MCPServerProbe.Result)
        case failed(String)
    }

    let binaryURL: URL
    private(set) var binaryStatus: MCPServerBinary.Status
    private(set) var test: TestState = .idle
    private(set) var states: [MCPClient: MCPClientState] = [:]
    private(set) var busy: Set<MCPClient> = []
    private(set) var errors: [MCPClient: String] = [:]
    private(set) var hints: [MCPClient: String] = [:]
    private(set) var claudeCLI: MCPCommandLineTool?
    private var located = false

    init(binaryURL: URL = MCPServerBinary.defaultURL) {
        self.binaryURL = binaryURL
        self.binaryStatus = MCPServerBinary.status(of: binaryURL)
    }

    private var installer: MCPClientInstaller {
        MCPClientInstaller(binaryPath: binaryURL.path, claudeCLI: claudeCLI)
    }

    var hasStaleClients: Bool {
        states.values.contains { if case .needsUpdate = $0 { true } else { false } }
    }

    func refresh() async {
        binaryStatus = MCPServerBinary.status(of: binaryURL)
        if !located {
            claudeCLI = await ClaudeCLILocator.locate()
            located = true
        }
        let installer = installer
        // ~/.claude.json can be large; read off the main actor.
        states = await Task.detached { installer.states() }.value
    }

    func runTest() async {
        test = .running
        do {
            test = .working(try await MCPServerProbe.probe(binary: binaryURL))
        } catch {
            test = .failed(error.localizedDescription)
        }
    }

    func connect(_ client: MCPClient) async {
        await perform(client) { try await $0.connect(client) }
        if states[client] == .connected { hints[client] = client.afterConnectHint }
    }

    func disconnect(_ client: MCPClient) async {
        await perform(client) { try await $0.disconnect(client) }
        hints[client] = nil
    }

    func updateAll() async {
        for (client, state) in states {
            if case .needsUpdate = state { await connect(client) }
        }
    }

    private func perform(_ client: MCPClient, _ action: @escaping @Sendable (MCPClientInstaller) async throws -> Void) async {
        busy.insert(client)
        errors[client] = nil
        let installer = installer
        do {
            try await Task.detached { try await action(installer) }.value
        } catch {
            errors[client] = error.localizedDescription
        }
        states[client] = await Task.detached { installer.state(for: client) }.value
        busy.remove(client)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


/// Settings › Apps & Extensions › Connect AI apps. One row per AI app, with
/// Connect / Disconnect, plus "Copy setup" for any other MCP app.
struct MCPSettingsSection: View {
    var localOnly: Bool
    let model: MCPSettingsModel

    var body: some View {
        Section {
            if model.hasStaleClients {
                LabeledContent {
                    Button("Update All") { Task { await model.updateAll() } }
                        .buttonStyle(.borderedProminent)
                } label: {
                    Text("LidIA moved")
                    Text("Some apps still point at the old copy.")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(MCPClient.allCases) { client in
                clientRow(client)
            }

            LabeledContent {
                copyMenu
            } label: {
                Text("Other apps")
                Text("Copy the setup for any app that speaks MCP.")
            }
        } header: {
            Text("Connect AI apps")
                .settingsAnchor(.connectAIApps)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected apps can search your meetings and action items on this Mac. Anything they ask to change is checked by LidIA first.")
                if localOnly {
                    Text("Local-only mode covers LidIA only. A connected app may send what it reads to its own servers.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.refresh() }
    }

    // MARK: Clients

    private func clientRow(_ client: MCPClient) -> some View {
        let state = model.states[client]
        let isBusy = model.busy.contains(client)
        return LabeledContent {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                clientButtons(client, state: state)
                    .disabled(isBusy || model.binaryStatus != .ready)
            }
        } label: {
            Text(client.displayName)
            if let error = model.errors[client] {
                Text(error).foregroundStyle(.red)
            } else if let hint = model.hints[client] {
                Text(hint)
            } else {
                stateLabel(state)
            }
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: MCPClientState?) -> some View {
        switch state {
        case nil:
            Text("Checking…")
        case .notInstalled:
            Text("Not installed")
        case .readyToConnect:
            Text("Ready to connect")
        case .connected:
            Text("Connected").foregroundStyle(.green)
        case .needsUpdate(let path):
            Text(path.isEmpty ? "Needs update" : "Points to an old copy of LidIA")
                .foregroundStyle(.orange)
                .help(path)
        case .unreadable(let message):
            Text(message).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func clientButtons(_ client: MCPClient, state: MCPClientState?) -> some View {
        switch state {
        case .connected:
            Button("Disconnect") { Task { await model.disconnect(client) } }
        case .needsUpdate:
            Button("Disconnect") { Task { await model.disconnect(client) } }
            Button("Update") { Task { await model.connect(client) } }
                .buttonStyle(.borderedProminent)
        case .readyToConnect:
            Button("Connect") { Task { await model.connect(client) } }
                .buttonStyle(.borderedProminent)
        case .notInstalled, .unreadable, nil:
            Button("Connect") {}
                .disabled(true)
        }
    }

    // MARK: Copy config

    private var copyMenu: some View {
        let path = model.binaryURL.path
        return Menu("Copy Setup") {
            Button("JSON (mcpServers)") {
                model.copy(MCPJSONConfig.snippet(command: path))
            }
            Button("VS Code (servers)") {
                model.copy(MCPJSONConfig.snippet(command: path, serversKey: "servers", style: .typedStdio))
            }
            Button("Codex (TOML)") {
                model.copy(MCPTOMLConfig.table(command: path))
            }
            Divider()
            Button("Server Path") {
                model.copy(path)
            }
        }
        .fixedSize()
    }
}

/// The MCP server binary: where it is, whether it runs, and a Test button.
/// Shown under Apps & Extensions › Advanced.
struct MCPServerRow: View {
    let model: MCPSettingsModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                serverStatus
                Button("Test") { Task { await model.runTest() } }
                    .disabled(model.binaryStatus != .ready || model.test == .running)
            }
        } label: {
            Text("LidIA MCP server")
            Text((model.binaryURL.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .working(let result) = model.test, !result.tools.isEmpty {
                Text(result.tools.joined(separator: ", "))
            }
            if case .failed(let message) = model.test {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch (model.binaryStatus, model.test) {
        case (.missing, _):
            Label("Missing", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        case (.notExecutable, _):
            Label("Can't run", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        case (.ready, .running):
            ProgressView().controlSize(.small)
        case (.ready, .working(let result)):
            Label("Working — \(result.tools.count) tools", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case (.ready, .failed):
            Label("Not working", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case (.ready, .idle):
            Text("Installed").foregroundStyle(.secondary).font(.callout)
        }
    }
}
