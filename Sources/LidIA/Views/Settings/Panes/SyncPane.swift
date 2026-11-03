import SwiftUI

/// Settings › Sync: iCloud sync, its status, and the self-hosted server (advanced).
struct SyncPane: View {
    @Bindable var settings: AppSettings
    @Environment(SyncManager.self) private var syncManager

    private var runtime: CloudSyncRuntime { .shared }

    var body: some View {
        SettingsPage(pane: .sync) {
            ICloudSyncSection(settings: settings)

            if runtime.mode.isICloud {
                ICloudStatusSection(monitor: runtime.monitor)
            }

            Section {
                LabeledContent("Syncs") {
                    Text("Meetings: title, date, attendees, notes, transcript, summary, action items, folders. Ask chats.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Stays on this Mac") {
                    Text("Audio recordings, settings, API keys (they have their own iCloud Keychain option in AI › Advanced).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("What syncs")
            }

            SettingsAdvancedSection(
                pane: .sync,
                footer: "Use one or the other: self-hosted sync pauses while iCloud sync is on."
            ) {
                SelfHostedSyncRows(settings: settings, problem: syncManager.configurationProblem)
            }
        }
    }
}

// MARK: - iCloud

private struct ICloudSyncSection: View {
    @Bindable var settings: AppSettings
    @State private var restartRefused = false

    private var runtime: CloudSyncRuntime { .shared }

    private var canChoose: Bool {
        switch runtime.mode {
        case .off(.notAvailableInThisBuild), .off(.isolatedLibrary): false
        default: !settings.localOnlyMode
        }
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { runtime.choice == .on && !settings.localOnlyMode },
            set: { runtime.choice = $0 ? .on : .off }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: isOn) {
                Text("Sync with iCloud")
                Text("Keeps your meetings, notes and action items in step on your Mac and iPhone, through your own iCloud account.")
            }
            .disabled(!canChoose)
            .settingsAnchor(.iCloudSync)

            if settings.localOnlyMode {
                LocalOnlyModeBanner(message: "Local-only mode is on, so iCloud sync is off: nothing about your meetings leaves this Mac.")
            } else if let explanation = runtime.mode.explanation, !runtime.needsRestart(localOnly: settings.localOnlyMode),
                      runtime.mode != .off(.turnedOff) {
                InlineNote(text: explanation)
            }

            if let problem = runtime.startupError {
                InlineNote(text: problem, kind: .error)
            }

            if runtime.needsRestart(localOnly: settings.localOnlyMode) {
                LabeledContent {
                    Button("Restart LidIA") {
                        restartRefused = !runtime.relaunch()
                    }
                } label: {
                    Text(runtime.mode.isICloud ? "Restart to stop syncing" : "Restart to start syncing")
                    Text(runtime.mode.isICloud
                         ? "iCloud sync keeps running until LidIA restarts."
                         : "LidIA backs up your library, then uploads it to iCloud after the restart.")
                }
                if restartRefused {
                    InlineNote(text: "Stop the recording first, then restart.", kind: .warning)
                }
            }
        } footer: {
            Text(CloudSyncText.encryptionNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ICloudStatusSection: View {
    let monitor: CloudSyncMonitor

    private var accountText: String {
        switch monitor.account {
        case .unknown: "Checking…"
        case .available: "Signed in"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .couldNotDetermine: "Couldn't check"
        }
    }

    private var activityText: String? {
        switch monitor.activity {
        case .idle: nil
        case .settingUp: "Setting up…"
        case .importing: "Downloading changes…"
        case .exporting: "Uploading changes…"
        }
    }

    var body: some View {
        Section {
            LabeledContent("iCloud account", value: accountText)
                .settingsAnchor(.iCloudStatus)
            LabeledContent("Last synced") {
                if let date = monitor.lastSyncDate {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Not yet")
                }
            }
            if let activityText {
                LabeledContent("Now", value: activityText)
            }
            if let problem = monitor.account.problem {
                InlineNote(text: problem, kind: .warning)
            }
            if let error = monitor.lastError {
                InlineNote(text: error, kind: .warning)
            }
        } header: {
            Text("Status")
        }
        .task { await monitor.refreshAccount() }
    }
}

// MARK: - Self-hosted

/// The lidia-sync server option, now under Sync › Advanced.
struct SelfHostedSyncRows: View {
    @Bindable var settings: AppSettings
    var problem: String?

    var body: some View {
        Toggle(isOn: $settings.syncEnabled) {
            Text("Self-hosted sync")
            Text("Keeps your iPhone in step through a LidIA sync server you run.")
        }
        .settingsAnchor(.deviceSync)

        if settings.syncEnabled {
            LabeledContent {
                TextField("Server URL", text: $settings.syncServerURL, prompt: Text("https://…"))
                    .labelsHidden()
                    .frame(maxWidth: 260)
            } label: {
                Text("Server URL")
            }
            LabeledContent {
                SecureField("Auth token", text: $settings.syncAuthToken, prompt: Text("Paste here"))
                    .labelsHidden()
                    .frame(maxWidth: 260)
            } label: {
                Text("Auth token")
            }

            if !settings.syncServerURL.isEmpty, !SyncSafety.isAllowedServerURL(settings.syncServerURL) {
                InlineNote(text: "Use an https:// address. Plain http:// only works for this Mac or your private network, so your token isn't sent in the clear.", kind: .warning)
            }
            if settings.localOnlyMode {
                LocalOnlyModeBanner(message: "Paused by Local-only mode. Nothing is sent to your sync server.")
            } else if let problem {
                InlineNote(text: problem, kind: .warning)
            } else {
                Text("Sends meetings (title, date, transcript, summary, notes, attendees) and action items, and keeps SOUL.md and MEMORY.md in step. Audio stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
