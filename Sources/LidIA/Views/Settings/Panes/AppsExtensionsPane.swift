import LidIAKit
import SwiftUI

struct AppsExtensionsPane: View {
    @Bindable var settings: AppSettings
    let mcp: MCPSettingsModel

    var body: some View {
        SettingsPage(pane: .apps) {
            MCPSettingsSection(localOnly: settings.localOnlyMode, model: mcp)

            Section {
                ForEach(IntegrationKind.allCases) { kind in
                    NavigationLink(value: SettingsSubpage.integration(kind)) {
                        SettingsLinkRow(
                            symbol: kind.symbol,
                            tint: kind.tint,
                            title: kind.title,
                            detail: kind.summary,
                            status: IntegrationStatus.status(of: kind, settings: settings)
                        )
                    }
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text("Nothing is sent until you set one up. Each page says exactly what leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsAdvancedSection(pane: .apps) {
                MCPServerRow(model: mcp)
            }
        }
    }
}

/// On / Off / Needs setup for the integration rows.
@MainActor
enum IntegrationStatus {
    static func status(of kind: IntegrationKind, settings: AppSettings) -> StatusText.Status {
        let sendsOffMac = kind != .markdown
        let base: StatusText.Status
        switch kind {
        case .notion:
            if settings.notionAPIKey.isEmpty { base = .off }
            else if settings.notionDatabaseID.isEmpty { base = .needsSetup }
            else { base = .on }
        case .slack:
            if !settings.slackEnabled { base = .off }
            else if settings.slackBotToken.isEmpty || settings.slackChannel.isEmpty { base = .needsSetup }
            else { base = .on }
        case .n8n:
            if !settings.n8nEnabled { base = .off }
            else if settings.n8nWebhookURL.isEmpty { base = .needsSetup }
            else { base = .on }
        case .clickUp:
            if settings.clickUpAPIKey.isEmpty { base = .off }
            else if settings.clickUpListID.isEmpty { base = .needsSetup }
            else { base = .on }
        case .linear:
            if settings.linearAPIKey.isEmpty { base = .off }
            else if settings.linearTeamID.isEmpty { base = .needsSetup }
            else { base = .on }
        case .markdown:
            base = settings.vaultExportEnabled ? .on : .off
        }
        if base == .on, sendsOffMac, settings.localOnlyMode { return .paused }
        return base
    }
}

// MARK: - Detail pages

struct IntegrationDetailPage: View {
    @Bindable var settings: AppSettings
    let kind: IntegrationKind

    var body: some View {
        SettingsPage(pane: .apps, subpage: .integration(kind), subtitle: kind.summary) {
            switch kind {
            case .notion: NotionSettings(settings: settings)
            case .slack: SlackSettings(settings: settings)
            case .n8n: N8nSettings(settings: settings)
            case .clickUp: ClickUpSettings(settings: settings)
            case .linear: LinearSettings(settings: settings)
            case .markdown: MarkdownExportSettings(settings: settings)
            }
        }
    }
}

private func secretField(_ title: String, text: Binding<String>, detail: String? = nil, prompt: String = "Paste here") -> some View {
    LabeledContent {
        SecureField(title, text: text, prompt: Text(prompt))
            .labelsHidden()
            .frame(maxWidth: 260)
    } label: {
        Text(title)
        if let detail { Text(detail) }
    }
}

private func textField(_ title: String, text: Binding<String>, detail: String? = nil, prompt: String? = nil) -> some View {
    LabeledContent {
        TextField(title, text: text, prompt: prompt.map { Text($0) })
            .labelsHidden()
            .frame(maxWidth: 260)
    } label: {
        Text(title)
        if let detail { Text(detail) }
    }
}

private struct NotionSettings: View {
    @Bindable var settings: AppSettings
    @State private var isFetching = false
    @State private var fetchFailed = false

    var body: some View {
        Section {
            secretField("API key", text: $settings.notionAPIKey,
                        detail: "From an internal integration at notion.so/my-integrations.")
                .settingsAnchor(.notion)

            if !settings.notionAPIKey.isEmpty {
                if settings.availableDatabases.isEmpty {
                    LabeledContent {
                        Button {
                            Task { await fetchDatabases() }
                        } label: {
                            if isFetching { ProgressView().controlSize(.small) } else { Text("Find Databases") }
                        }
                        .disabled(isFetching)
                    } label: {
                        Text("Databases")
                        Text(fetchFailed ? "Couldn't load databases. Check the key and that pages are shared with it." : "Share a database with your integration, then find it here.")
                            .foregroundStyle(fetchFailed ? .orange : .secondary)
                    }
                } else {
                    Picker(selection: $settings.notionDatabaseID) {
                        ForEach(settings.availableDatabases) { db in
                            Text(db.title).tag(db.id)
                        }
                    } label: {
                        Text("Meeting notes go to")
                    }
                    Picker(selection: $settings.notionTasksDatabaseID) {
                        Text("None").tag("")
                        ForEach(settings.availableDatabases) { db in
                            Text(db.title).tag(db.id)
                        }
                    } label: {
                        Text("Action items go to")
                        Text("Used by the export buttons on action items.")
                    }
                }
            }
        } header: {
            Text("Connection")
        }

        if !settings.notionAPIKey.isEmpty && !settings.availableDatabases.isEmpty {
            Section {
                Toggle("Send after each meeting", isOn: $settings.notionAutoSend)
                Toggle("Summary", isOn: $settings.notionSendSummary)
                Toggle("Action items", isOn: $settings.notionSendActionItems)
            } header: {
                Text("What to send")
            } footer: {
                IntegrationDataFlowNote(
                    destination: "Notion",
                    flow: .notion(settings: settings),
                    automatic: settings.notionAutoSend,
                    localOnly: settings.localOnlyMode
                )
            }
        }
    }

    @MainActor
    private func fetchDatabases() async {
        isFetching = true
        defer { isFetching = false }
        let client = NotionClient(apiKey: settings.notionAPIKey)
        if let dbs = try? await client.listDatabases() {
            fetchFailed = false
            settings.availableDatabases = dbs.map { AppSettings.DatabaseEntry(id: $0.id, title: $0.title) }
        } else {
            fetchFailed = true
        }
    }
}

private struct SlackSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.slackEnabled) {
                Text("Post to Slack")
                Text("Uses a Slack app with the chat:write permission.")
            }
            .settingsAnchor(.slack)

            if settings.slackEnabled {
                secretField("Bot token", text: $settings.slackBotToken,
                            detail: "The Bot User OAuth Token, starting with xoxb-.", prompt: "xoxb-…")
                textField("Channel", text: $settings.slackChannel, prompt: "#meeting-notes")
            }
        } header: {
            Text("Connection")
        }

        if settings.slackEnabled {
            Section {
                Toggle("Send after each meeting", isOn: $settings.slackAutoSend)
                Toggle("Summary", isOn: $settings.slackSendSummary)
                Toggle("Action items", isOn: $settings.slackSendActionItems)
                Toggle("Attendees", isOn: $settings.slackSendAttendees)
            } header: {
                Text("What to send")
            } footer: {
                IntegrationDataFlowNote(
                    destination: "Slack",
                    flow: .slack(settings: settings),
                    automatic: settings.slackAutoSend,
                    localOnly: settings.localOnlyMode
                )
            }
        }
    }
}

private struct N8nSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.n8nEnabled) {
                Text("Send to n8n")
                Text("Posts each meeting as JSON. n8n takes it from there.")
            }
            .settingsAnchor(.n8n)

            if settings.n8nEnabled {
                textField("Webhook URL", text: $settings.n8nWebhookURL, prompt: "https://…")
                secretField("Auth header", text: $settings.n8nAuthHeader, detail: "Optional.", prompt: "Optional")
            }
        } header: {
            Text("Connection")
        }

        if settings.n8nEnabled {
            Section {
                Toggle("Send after each meeting", isOn: $settings.n8nAutoSend)
                Toggle("Summary", isOn: $settings.n8nSendSummary)
                Toggle("Action items", isOn: $settings.n8nSendActionItems)
                Toggle("Attendees", isOn: $settings.n8nSendAttendees)
                Toggle(isOn: $settings.n8nSendTranscript) {
                    Text("Full transcript")
                    if settings.n8nSendTranscript {
                        Text("Includes everything other people said.")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("What to send")
            } footer: {
                IntegrationDataFlowNote(
                    destination: "n8n",
                    flow: .n8n(settings: settings),
                    automatic: settings.n8nAutoSend,
                    localOnly: settings.localOnlyMode
                )
            }
        }
    }
}

private struct ClickUpSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            secretField("API token", text: $settings.clickUpAPIKey,
                        detail: "A personal token from ClickUp → Settings → Apps.", prompt: "pk_…")
                .settingsAnchor(.clickUp)
            textField("List ID", text: $settings.clickUpListID,
                      detail: "Tasks are created in this list.", prompt: "901234567")
        } header: {
            Text("Connection")
        } footer: {
            IntegrationSendNote(destination: "ClickUp", localOnly: settings.localOnlyMode)
        }
    }
}

private struct LinearSettings: View {
    @Bindable var settings: AppSettings
    @State private var teams: [LinearClient.Team] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            secretField("API key", text: $settings.linearAPIKey,
                        detail: "A personal API key from Linear → Settings → Security & access.", prompt: "lin_api_…")
                .settingsAnchor(.linear)
            LabeledContent {
                HStack(spacing: 8) {
                    if teams.isEmpty {
                        Text(settings.linearTeamName.isEmpty ? "None" : settings.linearTeamName)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Team", selection: Binding(
                            get: { settings.linearTeamID },
                            set: { id in
                                settings.linearTeamID = id
                                settings.linearTeamName = teams.first { $0.id == id }?.name ?? ""
                            }
                        )) {
                            Text("Choose…").tag("")
                            ForEach(teams) { team in Text(team.name).tag(team.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    Button {
                        Task { await loadTeams() }
                    } label: {
                        if isLoading { ProgressView().controlSize(.small) } else { Text("Load Teams") }
                    }
                    .disabled(settings.linearAPIKey.isEmpty || isLoading)
                }
            } label: {
                Text("Team")
                Text(errorMessage ?? "New issues go to this team's backlog.")
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
            }
        } header: {
            Text("Connection")
        } footer: {
            IntegrationSendNote(destination: "Linear", localOnly: settings.localOnlyMode)
        }
    }

    private func loadTeams() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            teams = try await LinearClient.teams(apiKey: settings.linearAPIKey)
            if teams.count == 1, let only = teams.first {
                settings.linearTeamID = only.id
                settings.linearTeamName = only.name
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// What a confirm-to-send integration sends, under its settings.
private struct IntegrationSendNote: View {
    let destination: String
    let localOnly: Bool

    var body: some View {
        Text(localOnly
             ? "Local-only mode is on, so nothing is sent to \(destination)."
             : "Sends an action item's title, the note you confirm, its assignee, deadline and meeting title, only when you press Create on a card. Nothing is sent automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct MarkdownExportSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.vaultExportEnabled) {
                Text("Save meetings as Markdown")
                Text("Works with Obsidian, iA Writer and any notes app that reads .md files.")
            }
            .settingsAnchor(.markdownExport)

            if settings.vaultExportEnabled {
                LabeledContent {
                    Button("Choose\u{2026}") { chooseFolder() }
                } label: {
                    Text("Folder")
                    Text(settings.vaultExportPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Toggle(isOn: $settings.vaultExportIncludeTranscript) {
                    Text("Include the full transcript")
                    Text("Off saves the summary, notes and action items.")
                }
            }
        } footer: {
            Text("Files stay on this Mac unless the folder syncs to a cloud drive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.vaultExportPath = url.path
        }
    }
}
