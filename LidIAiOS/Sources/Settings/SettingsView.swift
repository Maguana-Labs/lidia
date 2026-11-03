import LidIAIntelligence
import LidIAKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Intelligence.self) private var intelligence
    @Environment(SyncCoordinator.self) private var sync
    @Environment(CloudSyncMonitor.self) private var cloudSync
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var speechStatus: LiveTranscriber.Availability?

    private static let languages: [(id: String, name: String)] = [
        ("en_US", "English (US)"), ("en_GB", "English (UK)"), ("es_ES", "Spanish (Spain)"),
        ("es_MX", "Spanish (Mexico)"), ("fr_FR", "French"), ("de_DE", "German"),
        ("it_IT", "Italian"), ("pt_BR", "Portuguese (Brazil)"), ("ja_JP", "Japanese"),
    ]

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                profile
                intelligenceSection
                privacySection
                recordingSection
                iCloudSection
                syncSection
                Section {
                    NavigationLink {
                        FileEditorView(title: "SOUL.md", filePath: LidIAFiles.soulFilePath, defaultContent: "# LidIA Soul\n\nInstructions that shape how LidIA behaves:\n\n")
                    } label: {
                        SettingsLabel(title: "Instructions (SOUL.md)", symbol: "text.quote", tint: .purple)
                    }
                    NavigationLink {
                        FileEditorView(title: "MEMORY.md", filePath: LidIAFiles.memoryFilePath, defaultContent: "# LidIA Memory\n\nThings I've learned about you:\n\n")
                    } label: {
                        SettingsLabel(title: "Memory (MEMORY.md)", symbol: "brain", tint: .pink)
                    }
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Shared with the Mac through self-hosted sync.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                } header: {
                    Text("About")
                } footer: {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("With iCloud sync on, your meetings go to your own iCloud account to reach your Mac. Nothing else is sent unless you turn on a cloud model or self-hosted sync.")
                        DedicationLine()
                    }
                }
                .id("about")
            }
            .task {
                // DEBUG screenshots of About (`-screen settings-about`); never in release.
                guard LaunchOptions().screen == "settings-about" else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo("about", anchor: .center)
            }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: settings.transcriptionLocaleID) {
                speechStatus = await LiveTranscriber.availability(for: settings.transcriptionLocale)
            }
            .onChange(of: settings.localOnly) { _, _ in sync.configure() }
            .onChange(of: settings.syncEnabled) { _, _ in sync.configure() }
            .onDisappear {
                sync.configure()
                intelligence.refresh()
            }
        }
    }

    // MARK: - Sections

    private var profile: some View {
        @Bindable var settings = settings
        return Section {
            HStack(spacing: 14) {
                PersonAvatar(name: settings.displayName.isEmpty ? "Me" : settings.displayName, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Your name", text: $settings.displayName)
                        .font(.title3.weight(.semibold))
                        .textContentType(.name)
                    Text("Used to find the action items that are yours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var intelligenceSection: some View {
        @Bindable var settings = settings
        let status = intelligence.onDeviceStatus
        return Section {
            HStack(spacing: 12) {
                SettingsIcon(symbol: "apple.intelligence", tint: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence")
                    Text(status.title)
                        .font(.footnote)
                        .foregroundStyle(status.isAvailable ? .green : .orange)
                }
                Spacer()
                Circle()
                    .fill(status.isAvailable ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
            }
            Picker(selection: $settings.notesEngine) {
                ForEach(NotesEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            } label: {
                SettingsLabel(title: "Write notes with", symbol: "sparkles", tint: .indigo)
            }
            .disabled(settings.localOnly)

            if !settings.localOnly, settings.notesEngine != .onDevice {
                let shared = settings.apiKey(for: settings.notesEngine)
                SecureField(settings.notesEngine == .anthropic ? "Anthropic API key" : "OpenAI API key", text: settings.notesEngine == .anthropic ? $settings.anthropicKey : $settings.openAIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let shared, shared.fromMac {
                    Label("Using the key from your Mac (iCloud Keychain)", systemImage: "checkmark.icloud.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                TextField("Model", text: $settings.cloudModel, prompt: Text(settings.notesEngine.defaultModel))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Notes & Ask")
        } footer: {
            if settings.localOnly {
                Text("Local-only is on: notes and Ask always run on this iPhone.")
            } else if settings.notesEngine == .onDevice {
                Text(status.message)
            } else {
                Text("The transcript and your question are sent to \(settings.notesEngine == .anthropic ? "Anthropic" : "OpenAI") with your key. On the Mac, turn on “Sync keys via iCloud” to use the same key here.")
            }
        }
    }

    private var privacySection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.localOnly) {
                SettingsLabel(title: "Local-only", symbol: "lock.shield.fill", tint: .green)
            }
            Toggle(isOn: $settings.consentReminder) {
                SettingsLabel(title: "Consent reminder", symbol: "hand.wave.fill", tint: .orange)
            }
            Toggle(isOn: Binding(get: { settings.siriReadsContent && !settings.localOnly }, set: { settings.siriReadsContent = $0 })) {
                SettingsLabel(title: "Let Siri read meeting content", symbol: "waveform", tint: Brand.red)
            }
            .disabled(settings.localOnly)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Local-only blocks every network send of meeting content: no cloud models and no sync. iCloud sync stops the next time you open LidIA. Siri can always find meetings by title, date and people, and list action items; with Let Siri read meeting content on, it can also read summaries, notes and Ask answers after you unlock. Siri may process requests on Apple's servers.")
        }
    }

    private var recordingSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker(selection: $settings.transcriptionLocaleID) {
                if !Self.languages.contains(where: { $0.id == settings.transcriptionLocaleID }) {
                    Text(Locale.current.localizedString(forIdentifier: settings.transcriptionLocaleID) ?? settings.transcriptionLocaleID)
                        .tag(settings.transcriptionLocaleID)
                }
                ForEach(Self.languages, id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            } label: {
                SettingsLabel(title: "Language", symbol: "globe", tint: .blue)
            }
            LabeledContent {
                Text(speechStatusText)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsLabel(title: "Speech model", symbol: "waveform", tint: Brand.coral)
            }
            Toggle(isOn: $settings.keepAudio) {
                SettingsLabel(title: "Keep audio", symbol: "speaker.wave.2.fill", tint: .teal)
            }
            Toggle(isOn: $settings.showLiveActivity) {
                SettingsLabel(title: "Live Activity", symbol: "platter.filled.top.iphone", tint: .red)
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Transcription runs on this iPhone with Apple’s speech model. The Live Activity shows the timer and Pause / Stop on the Lock Screen and in the Dynamic Island.")
        }
    }

    private var speechStatusText: String {
        switch speechStatus {
        case .ready: "On this iPhone"
        case .needsDownload: "Downloads on first use"
        case .unsupported: "Not available"
        case nil: "Checking…"
        }
    }

    private var iCloudSection: some View {
        @Bindable var settings = settings
        let wanted = settings.iCloudSync && !settings.localOnly
        return Section {
            Toggle(isOn: $settings.iCloudSync) {
                SettingsLabel(title: "Sync with iCloud", symbol: "icloud.fill", tint: .blue)
            }
            .disabled(settings.localOnly)
            if wanted != cloudSync.isActive {
                Text(wanted ? "Starts the next time you open LidIA." : "Stops the next time you open LidIA.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let problem = cloudSync.startupProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if cloudSync.isActive {
                LabeledContent("iCloud account", value: accountText)
                LabeledContent("Last synced") {
                    if let date = cloudSync.lastSyncDate {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet")
                    }
                }
                if let activity = activityText {
                    LabeledContent("Now", value: activity)
                }
                if let problem = cloudSync.account.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error = cloudSync.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(CloudSyncText.encryptionNote)
        }
        .task { await cloudSync.refreshAccount() }
    }

    private var accountText: String {
        switch cloudSync.account {
        case .unknown: "Checking…"
        case .available: "Signed in"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .couldNotDetermine: "Couldn't check"
        }
    }

    private var activityText: String? {
        switch cloudSync.activity {
        case .idle: nil
        case .settingUp: "Setting up…"
        case .importing: "Downloading changes…"
        case .exporting: "Uploading changes…"
        }
    }

    private var syncSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.syncEnabled) {
                SettingsLabel(title: "Sync through your own server", symbol: "arrow.triangle.2.circlepath", tint: .indigo)
            }
            .disabled(settings.localOnly)
            if settings.syncEnabled {
                TextField("https://sync.example.com", text: $settings.syncServerURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { sync.configure() }
                SecureField("Token", text: $settings.syncAuthToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { sync.configure() }
                HStack {
                    syncStatus
                    Spacer()
                    Button("Sync now") {
                        sync.configure()
                        Task {
                            await sync.syncNow()
                            toasts.show("Synced")
                        }
                    }
                    .disabled(!sync.isRunning)
                }
            }
        } header: {
            Text("Self-hosted sync (advanced)")
        } footer: {
            Text("Instead of iCloud: use the same lidia-sync server and token as LidIA on your Mac (Settings › Sync › Advanced). Pauses while iCloud sync is on.")
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch sync.state {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .paused(let reason):
            Text(reason).font(.footnote).foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Syncing…") }
                .font(.footnote).foregroundStyle(.secondary)
        case .idle(let last):
            Label(last.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Connected", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        }
    }
}

// MARK: - Pieces

struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

struct SettingsLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: tint)
            Text(title)
        }
    }
}

/// Edits SOUL.md / MEMORY.md.
struct FileEditorView: View {
    let title: String
    let filePath: String
    let defaultContent: String

    @Environment(ToastCenter.self) private var toasts
    @State private var content = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $content)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 12)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        toasts.show("\(title) saved")
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                content = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? defaultContent
            }
    }

    private func save() {
        let directory = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}

/// The quiet line in About: the app's name, and whose it is. The wording
/// lives in `LidIABrand.dedication` (LidIAKit), shared with the Mac.
private struct DedicationLine: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(Brand.red)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(LidIABrand.dedication)
        }
        .accessibilityElement(children: .combine)
    }
}
