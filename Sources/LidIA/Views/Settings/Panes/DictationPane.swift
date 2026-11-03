import AppKit
import SwiftUI

/// Settings › Dictation: speak into any app with a key.
struct DictationPane: View {
    @Bindable var settings: AppSettings
    var controller: DictationController = .shared

    @State private var isTrusted = DictationPermissions.isAccessibilityTrusted
    @State private var micStatus = DictationPermissions.microphoneStatus
    @State private var globeAction = DictationPermissions.globeKeyAction
    @State private var confirmClear = false

    private var dictation: DictationSettings { settings.dictation }

    var body: some View {
        @Bindable var dictation = settings.dictation
        SettingsPage(pane: .dictation) {
            Section {
                Toggle(isOn: $dictation.enabled) {
                    Text("Dictation")
                    Text("Hold \(dictation.triggerKey.symbol), speak, let go: the text appears where your cursor is, in any app.")
                }
                .settingsAnchor(.dictationEnabled)

                if dictation.enabled && !isTrusted {
                    accessibilityOnboarding
                }
                if dictation.enabled && micStatus != .authorized {
                    microphoneRow
                }
            } footer: {
                if dictation.enabled {
                    privacyFooter
                }
            }

            Section("Key") {
                Picker(selection: $dictation.triggerKey) {
                    ForEach(DictationTriggerKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                } label: {
                    Text("Dictation key")
                    Text("Pressed together with another key it's a normal shortcut, never dictation.")
                }
                .settingsAnchor(.dictationKey)

                if dictation.triggerKey == .fn && globeAction != .doNothing {
                    HStack(alignment: .firstTextBaseline) {
                        InlineNote(
                            text: "The Globe key is set to “\(globeAction.title)”. Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings so it only dictates.",
                            kind: .warning
                        )
                        Spacer()
                        Button("Keyboard Settings…") { DictationPermissions.openKeyboardSettings() }
                    }
                }
                if let conflict = assistantConflict {
                    InlineNote(text: conflict)
                }

                Picker(selection: $dictation.activation) {
                    ForEach(DictationActivation.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Hold or double-tap")
                    Text(activationDetail)
                }
                .settingsAnchor(.dictationMode)
            }

            Section("Text") {
                Toggle(isOn: $dictation.tidyText) {
                    Text("Tidy dictated text")
                    Text("Drops “um” and “uh”, keeps only your correction (“Tuesday, no wait, Thursday”), turns “first… second…” into a list. Instant, on this Mac.")
                }
                .settingsAnchor(.dictationTidy)

                LabeledContent {
                    Button("Edit…") { SettingsRouter.shared.show(.recording, subpage: .vocabulary) }
                } label: {
                    Text("Your vocabulary")
                    Text(vocabularyDetail)
                }

                Toggle(isOn: $dictation.polishWithAI) {
                    Text("Polish with AI")
                    Text(polishDetail)
                }
                .settingsAnchor(.dictationPolish)

                Picker(selection: $dictation.insertion) {
                    ForEach(DictationInsertionMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                } label: {
                    Text("How text is inserted")
                    Text(dictation.insertion.detail)
                }
                .settingsAnchor(.dictationInsertion)
            }

            Section("Speech") {
                Picker(selection: $dictation.language) {
                    Text(sameAsTranscriptionLabel).tag("")
                    ForEach(Self.languages, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                } label: {
                    Text("Language")
                    Text("The language you dictate in.")
                }
                .settingsAnchor(.dictationLanguage)

                Picker(selection: $dictation.engine) {
                    ForEach(DictationEngineChoice.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                } label: {
                    Text("Speech recognition")
                    Text(dictation.engine == .appleOnDevice
                         ? "Shows words as you speak. Nothing to download beyond the system's speech model."
                         : "Uses the engine chosen in Recording. May take a moment to load the first time.")
                }
                .settingsAnchor(.dictationEngine)
            }

            historySection
        }
        .onChange(of: dictation.enabled) { _, enabled in
            // Accessibility is asked from the card's button, after the explanation.
            let isSnapshot = ProcessInfo.processInfo.environment["LIDIA_SNAPSHOT_SETTINGS"] != nil
            if enabled && !isSnapshot && DictationPermissions.microphoneStatus == .notDetermined {
                Task {
                    _ = await DictationPermissions.requestMicrophone()
                    micStatus = DictationPermissions.microphoneStatus
                }
            }
            controller.apply()
        }
        .onChange(of: dictation.triggerKey) { _, _ in controller.apply() }
        .onChange(of: dictation.activation) { _, _ in controller.apply() }
        .onChange(of: dictation.language) { _, _ in controller.apply() }
        .onChange(of: dictation.engine) { _, _ in controller.apply() }
        .onChange(of: dictation.keepHistory) { _, _ in controller.apply() }
        .onChange(of: dictation.historyLimit) { _, _ in controller.apply() }
        .task {
            // Accessibility and microphone changes can't be observed; refresh while visible.
            while !Task.isCancelled {
                isTrusted = DictationPermissions.isAccessibilityTrusted
                micStatus = DictationPermissions.microphoneStatus
                globeAction = DictationPermissions.globeKeyAction
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: - Permissions

    private var accessibilityOnboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Allow LidIA in Accessibility")
                    .font(.headline)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            Text("macOS asks for this once. LidIA uses it for two things only: noticing when you press the dictation key or Esc, and typing what you dictated into the app you're using. It doesn't record what you type.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("In Privacy & Security › Accessibility, turn on LidIA. This page updates by itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Accessibility Settings…") {
                    DictationPermissions.requestAccessibility()
                    DictationPermissions.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private var microphoneRow: some View {
        HStack(alignment: .firstTextBaseline) {
            InlineNote(
                text: micStatus == .notDetermined
                    ? "LidIA will ask for the microphone the first time you dictate."
                    : "Microphone access is off for LidIA.",
                kind: micStatus == .notDetermined ? .info : .warning
            )
            Spacer()
            if micStatus != .notDetermined {
                Button("Microphone Settings…") { DictationPermissions.openMicrophoneSettings() }
            }
        }
    }

    @ViewBuilder
    private var privacyFooter: some View {
        if dictation.polishWithAI, let provider = polishProvider, provider.locality(settings: settings) == .cloud, !settings.localOnlyMode {
            Label("Speech is recognised on this Mac. With Polish on, the text is sent to \(provider.displayName).", systemImage: "cloud")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Speech is recognised on this Mac. Nothing you say leaves it.", systemImage: "lock.laptopcomputer")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: - History

    private var historySection: some View {
        @Bindable var dictation = settings.dictation
        let records = controller.history.records
        return Section {
            Toggle(isOn: $dictation.keepHistory) {
                Text("Dictation history")
                Text("Keeps your recent dictations on this Mac, so nothing is lost if an app didn't accept the text.")
            }
            .settingsAnchor(.dictationHistory)

            if dictation.keepHistory {
                Picker("Keep the last", selection: $dictation.historyLimit) {
                    ForEach([10, 25, 50, 100], id: \.self) { count in
                        Text("\(count) dictations").tag(count)
                    }
                }

                if records.isEmpty {
                    Text("Nothing dictated yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records.prefix(dictation.historyLimit)) { record in
                        DictationHistoryRow(record: record)
                    }
                    HStack {
                        Spacer()
                        Button("Clear History…", role: .destructive) { confirmClear = true }
                    }
                }
            }
        }
        .confirmationDialog("Clear dictation history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { controller.history.clear() }
        } message: {
            Text("Removes every saved dictation from this Mac.")
        }
    }

    // MARK: - Text

    private var activationDetail: String {
        let key = dictation.triggerKey.symbol
        switch dictation.activation {
        case .holdOrDoubleTap: return "Hold \(key) while you speak. Double-tap \(key) to keep listening hands-free; tap again to insert."
        case .hold: return "Hold \(key) while you speak; release to insert."
        case .doubleTap: return "Double-tap \(key) to start, tap once to insert."
        }
    }

    private var vocabularyDetail: String {
        let count = settings.customVocabulary.count
        guard count > 0 else { return "Add names and acronyms (like “TAPR”) so they're spelled your way." }
        return "\(count) \(count == 1 ? "word is" : "words are") spelled your way, and recognised more often."
    }

    private var polishProvider: AppSettings.LLMProvider? {
        resolvedProvider(settings: settings, taskType: .chat)
    }

    private var polishDetail: String {
        guard let provider = polishProvider else { return "Off: needs an AI provider in Settings › AI." }
        if providerBlockedError(provider, settings: settings) != nil {
            return "\(provider.displayName) is blocked by Local-only mode, so the tidy version is used."
        }
        switch provider.locality(settings: settings) {
        case .onDevice:
            return "Rewrites the text with \(provider.displayName), without leaving this Mac. Adds a second or two."
        case .localNetwork:
            return "Sends the text to your \(provider.displayName) server. Adds a second or two."
        case .cloud:
            return "Sends the text to \(provider.displayName) with your key (low effort). Adds a second or two."
        }
    }

    private var sameAsTranscriptionLabel: String {
        let id = settings.sttLanguage
        guard !id.isEmpty else { return "Same as the system" }
        return "Same as transcription (\(Locale.current.localizedString(forIdentifier: id) ?? id))"
    }

    /// Tells the user ⌥Space still works when the dictation key is ⌥.
    private var assistantConflict: String? {
        guard settings.voiceEnabled,
              let shared = dictation.triggerKey.sharedHotkeyModifier,
              settings.voiceHotkey.lowercased().split(separator: "+").contains(where: { $0 == shared || ($0 == "alt" && shared == "option") || ($0 == "cmd" && shared == "command") || ($0 == "ctrl" && shared == "control") })
        else { return nil }
        let hotkey = settings.voiceHotkey.replacingOccurrences(of: "option", with: "⌥").replacingOccurrences(of: "command", with: "⌘")
            .replacingOccurrences(of: "control", with: "⌃").replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "space", with: "Space")
        return "The voice assistant's \(hotkey) still works: \(dictation.triggerKey.symbol) with another key is a shortcut, never dictation."
    }

    static let languages = [
        "en-US", "en-GB", "en-AU", "en-IN", "es-ES", "es-MX", "es-US", "fr-FR", "fr-CA", "de-DE",
        "it-IT", "pt-BR", "pt-PT", "nl-NL", "ja-JP", "ko-KR", "zh-CN", "zh-TW",
    ]
}

private struct DictationHistoryRow: View {
    let record: DictationRecord
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy dictation")
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        var parts = [record.date.formatted(date: .abbreviated, time: .shortened)]
        if let app = record.appName { parts.append(app) }
        parts.append(record.outcome)
        if let ms = record.latencyMilliseconds { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }
}
