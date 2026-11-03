import SwiftUI

// MARK: - What leaves this Mac

/// A plain-language list of every way meeting data, or a request about it,
/// can leave this Mac with the current settings. Kept as plain data so it can
/// be tested and reused (onboarding, About, the privacy page).
struct PrivacyDisclosure: Equatable {
    enum Status: Equatable {
        /// Nothing leaves the Mac for this item.
        case staysOnMac
        /// Something leaves the Mac. The text says what and where.
        case leavesMac
        /// It would leave the Mac, but Local-only mode is blocking it.
        case blockedByLocalOnly
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let status: Status
    }

    let items: [Item]

    @MainActor
    init(settings: AppSettings) {
        items = Self.makeItems(settings: settings)
    }

    @MainActor
    private static func makeItems(settings: AppSettings) -> [Item] {
        let localOnly = settings.localOnlyMode
        var items: [Item] = []

        func integration(_ id: String, _ title: String, sends: String, auto: Bool) {
            if localOnly {
                items.append(Item(id: id, title: title,
                                  detail: "Blocked. Nothing is sent to \(title) while Local-only mode is on.",
                                  status: .blockedByLocalOnly))
            } else {
                let when = auto ? "automatically after each meeting" : "only when you choose Send"
                items.append(Item(id: id, title: title, detail: "\(sends), \(when).", status: .leavesMac))
            }
        }

        // AI processing
        let provider = settings.llmProvider
        if isLocalProvider(provider, settings: settings) {
            items.append(Item(id: "ai", title: "AI summaries and chat",
                              detail: "Run on this Mac (\(provider.rawValue)). Transcripts stay here.",
                              status: .staysOnMac))
        } else if localOnly {
            let kind = provider.locality(settings: settings) == .localNetwork
                ? "runs on another computer on your network"
                : "is a cloud service"
            items.append(Item(id: "ai", title: "AI summaries and chat",
                              detail: "\(provider.rawValue) \(kind), so Local-only mode blocks it. Choose a model on this Mac in Settings › AI.",
                              status: .blockedByLocalOnly))
        } else {
            items.append(Item(id: "ai", title: "AI summaries and chat",
                              detail: "Transcripts, notes and your questions go to \(provider.rawValue) to be processed.",
                              status: .leavesMac))
        }

        // Transcription
        if settings.sttEngine == .appleSpeech {
            items.append(Item(id: "stt", title: "Transcription",
                              detail: settings.localOnlyMode
                                ? "Apple Speech runs on this Mac. If your language has no on-device model, transcription stops instead of sending audio to Apple."
                                : "Apple Speech can send audio to Apple when on-device recognition isn't available for your language.",
                              status: settings.localOnlyMode ? .staysOnMac : .leavesMac))
        } else {
            items.append(Item(id: "stt", title: "Transcription",
                              detail: "Runs on this Mac. Audio never leaves it.",
                              status: .staysOnMac))
        }

        // Voice assistant: OpenAI voice sends audio and spoken answers to OpenAI.
        if settings.voiceEnabled, !settings.openaiAPIKey.isEmpty,
           settings.ttsProvider == .openai || settings.ttsProvider == .automatic {
            if localOnly {
                items.append(Item(id: "voice", title: "Voice assistant",
                                  detail: "Uses the voice on this Mac. Nothing is sent to OpenAI while Local-only mode is on.",
                                  status: .blockedByLocalOnly))
            } else if settings.ttsProvider == .openai {
                items.append(Item(id: "voice", title: "Voice assistant",
                                  detail: "Your voice, your SOUL.md and answers about your meetings go to OpenAI.",
                                  status: .leavesMac))
            } else {
                items.append(Item(id: "voice", title: "Voice assistant",
                                  detail: "Spoken answers about your meetings go to OpenAI to be read aloud when no voice model is downloaded.",
                                  status: .leavesMac))
            }
        }

        // Calendars: reads only, allowed in Local-only mode
        if settings.googleCalendarEnabled {
            items.append(Item(id: "google-calendar", title: "Google Calendar",
                              detail: "LidIA downloads your events from Google (read-only). Nothing about your meetings is sent to Google.",
                              status: .staysOnMac))
        }

        // Integrations
        if !settings.notionAPIKey.isEmpty {
            integration("notion", "Notion", sends: IntegrationDataFlow.notion(settings: settings).summary,
                        auto: settings.notionAutoSend)
        }
        if settings.n8nEnabled, !settings.n8nWebhookURL.isEmpty {
            integration("n8n", "n8n", sends: IntegrationDataFlow.n8n(settings: settings).summary,
                        auto: settings.n8nAutoSend)
        }
        if settings.slackEnabled, !settings.slackBotToken.isEmpty {
            integration("slack", "Slack", sends: IntegrationDataFlow.slack(settings: settings).summary,
                        auto: settings.slackAutoSend)
        }
        if !settings.clickUpAPIKey.isEmpty {
            integration("clickup", "ClickUp", sends: "An action item's title, assignee, deadline and meeting title",
                        auto: settings.autopilotEnabled)
        }
        if !settings.linearAPIKey.isEmpty {
            integration("linear", "Linear", sends: "An action item's title and the note you confirm, with its assignee, deadline and meeting title",
                        auto: false)
        }
        if settings.syncEnabled, !settings.syncServerURL.isEmpty {
            let host = URL(string: settings.syncServerURL)?.host ?? "your sync server"
            if localOnly {
                items.append(Item(id: "sync", title: "Device Sync",
                                  detail: "Paused. Nothing is sent to \(host) while Local-only mode is on.",
                                  status: .blockedByLocalOnly))
            } else {
                items.append(Item(id: "sync", title: "Device Sync",
                                  detail: "Meetings, transcripts, summaries, notes and action items go to \(host).",
                                  status: .leavesMac))
            }
        }

        // iCloud sync: decided at launch, so "running" means this launch syncs.
        let cloud = CloudSyncRuntime.shared
        if cloud.mode.isICloud {
            if localOnly {
                items.append(Item(id: "icloud", title: "iCloud sync",
                                  detail: "Still running until LidIA restarts. Restart LidIA to stop it; after that nothing goes to iCloud while Local-only mode is on.",
                                  status: .leavesMac))
            } else {
                items.append(Item(id: "icloud", title: "iCloud sync",
                                  detail: "Meetings, transcripts, summaries, notes, action items and Ask chats go to your private iCloud database. End-to-end encrypted only with Advanced Data Protection. Audio stays on this Mac.",
                                  status: .leavesMac))
            }
        } else if cloud.choice == .on, localOnly {
            items.append(Item(id: "icloud", title: "iCloud sync",
                              detail: "Off while Local-only mode is on. Nothing goes to iCloud.",
                              status: .blockedByLocalOnly))
        }

        // Siri: can process requests on Apple's servers.
        if localOnly {
            items.append(Item(id: "siri", title: "Siri",
                              detail: "Gets meeting titles, dates, people, projects and action items only. Summaries, notes and Ask answers stay here while Local-only mode is on.",
                              status: .blockedByLocalOnly))
        } else if settings.siriReadsMeetingContent {
            items.append(Item(id: "siri", title: "Siri",
                              detail: "When you ask, Siri gets meeting titles, dates, people and action items, and after you authenticate, summaries, decisions, notes and Ask answers. Siri may process them on Apple's servers.",
                              status: .leavesMac))
        } else {
            items.append(Item(id: "siri", title: "Siri",
                              detail: "When you ask, Siri gets meeting titles, dates, people, projects and action items. Summaries, notes and Ask answers stay here.",
                              status: .leavesMac))
        }

        // MCP: local, but other apps can read
        items.append(Item(id: "mcp", title: "Apps connected over MCP",
                          detail: "Apps you connect, such as Claude Desktop, can read your meetings on this Mac. What they send on is up to them.",
                          status: .staysOnMac))

        // Company logos
        if settings.fetchCompanyLogos && !localOnly {
            items.append(Item(id: "logos", title: "Company logos",
                              detail: "Loaded from each company's own website, which lets that site see the request.",
                              status: .leavesMac))
        } else {
            items.append(Item(id: "logos", title: "Company logos",
                              detail: "Drawn on this Mac from the company's initials. No requests are made.",
                              status: .staysOnMac))
        }

        // Updates and downloads
        items.append(Item(id: "updates", title: "Updates and model downloads",
                          detail: "Checking for updates contacts lidia-app.github.io, and downloading speech or AI models contacts Hugging Face. Your meetings are never included.",
                          status: .leavesMac))

        return items
    }

    @MainActor
    static func isLocalProvider(_ provider: AppSettings.LLMProvider, settings: AppSettings) -> Bool {
        provider.locality(settings: settings) == .onDevice
    }

    static func isLoopback(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return false }
        return DataLocality.forHost(host) == .onDevice
    }
}

// MARK: - Integration data flows

/// Exactly what an integration sends, built from the current toggles, so the
/// settings cards and the privacy list never disagree with the code.
struct IntegrationDataFlow: Equatable {
    /// Fields that are sent, in display order.
    let fields: [String]

    var summary: String {
        guard !fields.isEmpty else { return "Only the meeting title and date" }
        return "The meeting title and date, " + ListFormatter.localizedString(byJoining: fields)
    }

    @MainActor
    static func notion(settings: AppSettings) -> IntegrationDataFlow {
        var fields: [String] = ["duration"]
        if settings.notionSendSummary { fields.append("summary") }
        if settings.notionSendActionItems { fields.append("action items") }
        return IntegrationDataFlow(fields: fields)
    }

    @MainActor
    static func n8n(settings: AppSettings) -> IntegrationDataFlow {
        var fields: [String] = ["duration", "your notes"]
        if settings.n8nSendSummary { fields.append("summary") }
        if settings.n8nSendActionItems { fields.append("action items") }
        if settings.n8nSendAttendees { fields.append("attendee emails with their open action item counts") }
        if settings.n8nSendTranscript { fields.append("the full transcript") }
        return IntegrationDataFlow(fields: fields)
    }

    @MainActor
    static func slack(settings: AppSettings) -> IntegrationDataFlow {
        var fields: [String] = ["duration"]
        if settings.slackSendSummary { fields.append("summary") }
        if settings.slackSendActionItems { fields.append("action items") }
        if settings.slackSendAttendees { fields.append("attendee emails") }
        return IntegrationDataFlow(fields: fields)
    }
}

// MARK: - Views

/// Settings › Privacy: Local-only mode, company logos, and the list of what
/// leaves this Mac. (Recording consent lives in Settings › Recording.)
struct PrivacySettingsSection: View {
    @Bindable var settings: AppSettings
    @State private var confirmStopICloud = false
    @State private var restartRefused = false

    /// What the Local-only toggle promises. Kept in step with the gates:
    /// `allowsMeetingData` (AI on this Mac only, loopback servers included),
    /// `PrivacyGate` (integrations, sync, logos, OpenAI voice).
    static let localOnlyDescription = "Nothing about your meetings leaves this Mac. AI runs only on this Mac: cloud AI and AI servers on other computers are blocked, and so are OpenAI voice, Notion, n8n, Slack, ClickUp, Linear, iCloud sync, self-hosted sync and company logos. Calendar reads still work."

    /// What "Let Siri read meeting content" promises. Kept in step with
    /// `SiriContentPolicy` and `SiriSpotlight`.
    static let siriDescription = "Siri can always find your meetings by title, date, people and project, list and update action items, and record. With this on, Siri can also read a meeting's summary, decisions and notes, and answers from Ask, after you authenticate. Siri may process requests on Apple's servers. With it off, and always in Local-only mode, Siri gets titles, dates, people, projects and action items only, and Spotlight's index leaves summaries out."

    /// Off while Local-only mode is on, whatever the stored choice.
    private var siriReadsContent: Binding<Bool> {
        Binding(
            get: { settings.siriReadsMeetingContent && !settings.localOnlyMode },
            set: { settings.siriReadsMeetingContent = $0 }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.localOnlyMode) {
                Text("Local-only mode")
                Text("Blocks cloud AI and every integration.")
            }
            .settingsAnchor(.localOnly)
            .onChange(of: settings.localOnlyMode) { _, isOn in
                if isOn, CloudSyncRuntime.shared.mode.isICloud { confirmStopICloud = true }
            }
            .alert("Restart to stop iCloud sync?", isPresented: $confirmStopICloud) {
                Button("Restart LidIA") { restartRefused = !CloudSyncRuntime.shared.relaunch() }
                Button("Keep iCloud Sync", role: .cancel) { settings.localOnlyMode = false }
            } message: {
                Text("iCloud sync started when LidIA opened and keeps running until it restarts. Restart now so nothing about your meetings leaves this Mac.")
            }

            if settings.localOnlyMode {
                LocalOnlyModeBanner()
            }
            if settings.localOnlyMode, CloudSyncRuntime.shared.mode.isICloud {
                // The library opened with iCloud sync; only a restart stops it.
                LabeledContent {
                    Button("Restart LidIA") { restartRefused = !CloudSyncRuntime.shared.relaunch() }
                } label: {
                    Text("iCloud sync stops when LidIA restarts")
                }
                if restartRefused {
                    InlineNote(text: "Stop the recording first, then restart.", kind: .warning)
                }
            }
        } footer: {
            Text(Self.localOnlyDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Toggle(isOn: siriReadsContent) {
                Text("Let Siri read meeting content")
                Text("Summaries, decisions, notes and Ask answers, after you authenticate.")
            }
            .disabled(settings.localOnlyMode)
            .settingsAnchor(.siriContent)
            .onChange(of: settings.siriReadsMeetingContent) { _, _ in SpotlightIndexer.reindexLibrary() }
            .onChange(of: settings.localOnlyMode) { _, _ in SpotlightIndexer.reindexLibrary() }
        } footer: {
            Text(Self.siriDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Toggle(isOn: $settings.fetchCompanyLogos) {
                Text("Load company logos from their websites")
                Text("Off draws a monogram on this Mac. On asks each company's site for its icon.")
            }
            .disabled(settings.localOnlyMode)
            .settingsAnchor(.companyLogos)
        }

        Section {
            PrivacyDisclosureList(disclosure: PrivacyDisclosure(settings: settings))
        } header: {
            Text("What leaves this Mac")
                .settingsAnchor(.whatLeaves)
        } footer: {
            Text("Updates as you change settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The list rendered inside "What leaves this Mac".
struct PrivacyDisclosureList: View {
    let disclosure: PrivacyDisclosure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(disclosure.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(for: item.status))
                        .foregroundStyle(color(for: item.status))
                        .accessibilityLabel(label(for: item.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.medium))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for status: PrivacyDisclosure.Status) -> String {
        switch status {
        case .staysOnMac: "lock.laptopcomputer"
        case .leavesMac: "arrow.up.forward.circle"
        case .blockedByLocalOnly: "nosign"
        }
    }

    private func color(for status: PrivacyDisclosure.Status) -> Color {
        switch status {
        case .staysOnMac: .green
        case .leavesMac: .orange
        case .blockedByLocalOnly: .secondary
        }
    }

    private func label(for status: PrivacyDisclosure.Status) -> String {
        switch status {
        case .staysOnMac: "Stays on this Mac"
        case .leavesMac: "Leaves this Mac"
        case .blockedByLocalOnly: "Blocked by Local-only mode"
        }
    }
}

/// A small banner that says Local-only mode is on. Any view can show it, for
/// example an integration card or the main window.
struct LocalOnlyModeBanner: View {
    var message: String = "Local-only mode is on. Nothing about your meetings is sent off this Mac."

    var body: some View {
        Label {
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Sends: …" line under an integration card.
struct IntegrationDataFlowNote: View {
    let destination: String
    let flow: IntegrationDataFlow
    var automatic: Bool
    var localOnly: Bool

    var body: some View {
        if localOnly {
            LocalOnlyModeBanner(message: "Paused by Local-only mode. Nothing is sent to \(destination).")
        } else {
            Label {
                Text("Sends to \(destination): \(flow.summary). \(automatic ? "Automatically after each meeting." : "Only when you choose Send.")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.up.forward.circle")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
