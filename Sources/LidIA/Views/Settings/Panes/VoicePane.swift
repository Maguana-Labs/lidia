import SwiftUI

struct VoicePane: View {
    @Bindable var settings: AppSettings
    @Environment(VoiceAssistantService.self) private var voiceAssistant
    @Environment(TTSModelManager.self) private var ttsModelManager
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        SettingsPage(pane: .voice) {
            Section {
                Toggle(isOn: $settings.voiceEnabled) {
                    Text("Voice assistant")
                    Text("Ask about your meetings out loud.")
                }
                .settingsAnchor(.voiceAssistant)
                .onChange(of: settings.voiceEnabled) { _, _ in voiceAssistant.reconfigure() }

                if settings.voiceEnabled {
                    HotkeyRecorderRow(hotkey: $settings.voiceHotkey, onChanged: { voiceAssistant.reconfigure() })
                        .settingsAnchor(.voiceHotkey)
                }
            } footer: {
                if settings.voiceEnabled && isFullyLocalPipeline {
                    Label("Everything runs on this Mac. No API keys needed.", systemImage: "lock.laptopcomputer")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if settings.voiceEnabled {
                Section("Answers") {
                    Toggle(isOn: $settings.voiceReadResponses) {
                        Text("Read answers aloud")
                        Text("Off shows them as text only.")
                    }
                    .settingsAnchor(.readAloud)

                    Picker(selection: voiceChoice) {
                        Text("Automatic").tag(VoiceChoice.automatic)
                        Text("Downloaded voice").tag(VoiceChoice.mlx)
                        Text("macOS voice").tag(VoiceChoice.system)
                        Section("Better voice with your own key") {
                            Text("OpenAI").tag(VoiceChoice.openai)
                            Text("Grok (xAI)").tag(VoiceChoice.grok)
                        }
                    } label: {
                        Text("Voice")
                        Text(ttsDetail)
                    }
                    .settingsAnchor(.voiceOutput)

                    if voiceChoice.wrappedValue == .openai {
                        Picker("OpenAI voice", selection: $settings.ttsVoiceID) {
                            Text("Marin (default)").tag("")
                            ForEach(RealtimeVoiceProvider.openAI.voices.dropFirst(), id: \.self) { voice in
                                Text(voice.capitalized).tag(voice)
                            }
                        }
                    }

                    grokRows

                    if settings.localOnlyMode && (settings.ttsProvider == .openai || settings.voiceLayer.grokVoiceEnabled) {
                        InlineNote(text: "Local-only mode is on, so a voice on this Mac answers instead.", kind: .info)
                    }

                    LabeledContent {
                        HStack(spacing: 10) {
                            Slider(value: $settings.voiceSilenceTimeout, in: 0.8...3.0, step: 0.1)
                                .frame(maxWidth: 180)
                            Text(String(format: "%.1f s", settings.voiceSilenceTimeout))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    } label: {
                        Text("Wait before answering")
                        Text("How long a pause means you're done talking.")
                    }
                    .settingsAnchor(.voiceSilence)
                }

                if settings.ttsProvider == .mlx || settings.ttsProvider == .automatic {
                    voiceModelsSection
                }
            }
        }
    }

    /// The voice menu: the TTS provider, plus Grok (which lives in `voiceLayer`).
    enum VoiceChoice: Hashable { case automatic, mlx, system, openai, grok }

    private var voiceChoice: Binding<VoiceChoice> {
        Binding(
            get: {
                if settings.voiceLayer.grokVoiceEnabled { return .grok }
                switch settings.ttsProvider {
                case .automatic: return .automatic
                case .mlx: return .mlx
                case .system: return .system
                case .openai: return .openai
                }
            },
            set: { choice in
                settings.voiceLayer.grokVoiceEnabled = choice == .grok
                switch choice {
                case .automatic, .grok: settings.ttsProvider = .automatic
                case .mlx: settings.ttsProvider = .mlx
                case .system: settings.ttsProvider = .system
                case .openai: settings.ttsProvider = .openai
                }
            }
        )
    }

    @ViewBuilder
    private var grokRows: some View {
        if settings.voiceLayer.grokVoiceEnabled {
            @Bindable var layer = settings.voiceLayer
            LabeledContent {
                SecureField("xAI API key", text: $layer.xAIAPIKey, prompt: Text("xai-…"))
                    .labelsHidden()
                    .frame(maxWidth: 220)
            } label: {
                Text("xAI API key")
                Text("Kept in your Keychain. Get one at console.x.ai.")
            }
            .settingsAnchor(.grokVoice)

            Picker("Grok voice", selection: $layer.grokVoice) {
                Text("Eve — soothing (default)").tag("eve")
                Text("Ara — upbeat").tag("ara")
                Text("Leo — British").tag("leo")
                Text("Rex — calm").tag("rex")
                Text("Sal — smooth").tag("sal")
            }
        }
    }

    private var ttsDetail: String {
        if settings.voiceLayer.grokVoiceEnabled {
            return settings.voiceLayer.xAIAPIKey.isEmpty
                ? "Needs an xAI API key. Until then, a voice on this Mac answers."
                : "Sends your voice and the meeting notes it needs to xAI, which answers out loud."
        }
        return switch settings.ttsProvider {
        case .automatic: "The best voice available on this Mac."
        case .mlx: "A natural voice that runs on this Mac."
        case .system: "Built into macOS. Free, no download."
        case .openai: settings.openaiAPIKey.isEmpty ? "Needs an OpenAI API key in AI › Advanced." : "Sends your voice and the meeting notes it needs to OpenAI, which answers out loud."
        }
    }

    private var isFullyLocalPipeline: Bool {
        if settings.voiceLayer.grokVoiceEnabled && !settings.voiceLayer.xAIAPIKey.isEmpty && !settings.localOnlyMode { return false }
        let localTTS = settings.ttsProvider == .system || settings.ttsProvider == .mlx
            || (settings.ttsProvider == .automatic && settings.openaiAPIKey.isEmpty)
        let localLLM = settings.llmProvider == .mlx
            || (settings.openaiAPIKey.isEmpty && settings.anthropicAPIKey.isEmpty && !modelManager.downloadedModels.isEmpty)
        return localTTS && localLLM
    }

    @ViewBuilder
    private var voiceModelsSection: some View {
        Section("Downloaded voices") {
            if ttsModelManager.downloadedModelIDs.count > 1 {
                Picker("Use", selection: $settings.selectedTTSModelID) {
                    Text("First available").tag("")
                    ForEach(ttsModelManager.availableModels.filter { ttsModelManager.downloadedModelIDs.contains($0.id) }) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }

            ForEach(ttsModelManager.availableModels) { model in
                LabeledContent {
                    if ttsModelManager.downloadedModelIDs.contains(model.id) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Downloaded")
                            Button("Delete", role: .destructive) { ttsModelManager.delete(model) }
                        }
                    } else if ttsModelManager.isDownloading {
                        HStack(spacing: 8) {
                            ProgressView(value: ttsModelManager.downloadProgress)
                                .frame(width: 100)
                            Text("\(Int(ttsModelManager.downloadProgress * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Download") {
                            Task { await ttsModelManager.download(model) }
                        }
                    }
                } label: {
                    Text(model.name)
                    Text(model.sizeDescription)
                }
            }

            if let error = ttsModelManager.downloadError {
                InlineNote(text: error, kind: .error)
            }
        }
    }
}
