import SwiftUI

struct RecordingPane: View {
    @Bindable var settings: AppSettings
    @State private var copiedDisclosure = false

    var body: some View {
        SettingsPage(pane: .recording) {
            captureSection
            transcriptionSection
            consentSection
            SettingsAdvancedSection(pane: .recording) {
                Toggle(isOn: $settings.useVADPreFilter) {
                    Text("Skip silence before transcribing")
                    Text("Faster, and often more accurate, after the meeting.")
                }
                .settingsAnchor(.vadPrefilter)

                Toggle(isOn: $settings.useSpeechEnhancement) {
                    Text("Reduce background noise")
                    Text("Cleans up noisy rooms. Takes longer to process.")
                }
                .settingsAnchor(.speechEnhancement)

                LabeledContent {
                    TextField("Whisper model", text: $settings.whisperKitModel, prompt: Text("Automatic"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 180)
                } label: {
                    Text("Whisper model")
                    Text("Only for WhisperKit. Leave empty to pick the best for this Mac.")
                }
                .settingsAnchor(.whisperModel)
            }
        }
    }

    // MARK: Capture

    private var captureSection: some View {
        Section("Capture") {
            Picker(selection: $settings.audioCaptureMode) {
                ForEach(AudioCaptureMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            } label: {
                Text("What to record")
                Text(settings.audioCaptureMode == .micAndSystem
                     ? "You and everyone on the call. Needs Screen Recording permission."
                     : "Only your microphone. Others on the call won't be transcribed.")
            }
            .settingsAnchor(.captureMode)

            Toggle(isOn: $settings.autoDetectMeetings) {
                Text("Detect meetings automatically")
                Text("Offers to record when Zoom, Teams or a browser starts using the mic.")
            }
            .settingsAnchor(.autoDetect)

            Picker(selection: $settings.noteTranscription) {
                ForEach(NoteTranscriptionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Transcribe when I create a note")
                Text(settings.noteTranscription == .duringMeetings
                     ? "During a calendar meeting, or while a meeting app uses the mic, New Note starts transcribing. Otherwise it offers to."
                     : settings.noteTranscription == .always ? "Every new note starts transcribing. Stop it any time." : "New notes never use the microphone.")
            }
            .settingsAnchor(.noteTranscription)

            Toggle(isOn: $settings.autoStopOnSilence) {
                Text("Stop when it goes quiet")
                Text("Ends the recording after a stretch of silence.")
            }
            .settingsAnchor(.autoStop)

            if settings.autoStopOnSilence {
                LabeledContent("After") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.silenceTimeoutSeconds, in: 5...120, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(settings.silenceTimeoutSeconds)) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker(selection: $settings.sttEngine) {
                ForEach(AppSettings.STTEngineType.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            } label: {
                Text("Engine")
                Text(Self.engineDescription(settings.sttEngine))
            }
            .settingsAnchor(.sttEngine)

            Picker(selection: $settings.sttLanguage) {
                Text("System default").tag("")
                Divider()
                ForEach(Self.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            } label: {
                Text("Language")
                if settings.sttEngine == .parakeet && !settings.sttLanguage.isEmpty && !settings.sttLanguage.hasPrefix("en") {
                    Text("Parakeet only understands English. Pick Granite or WhisperKit for this language.")
                        .foregroundStyle(.orange)
                } else {
                    Text("The language people speak in your meetings.")
                }
            }
            .settingsAnchor(.sttLanguage)

            if settings.sttEngine == .parakeet {
                Toggle(isOn: $settings.enableDiarization) {
                    Text("Tell speakers apart")
                    Text("Labels who said what after the meeting. Adds a few seconds.")
                }
                .settingsAnchor(.diarization)
            }

            NavigationLink(value: SettingsSubpage.vocabulary) {
                LabeledContent {
                    Text(settings.customVocabulary.isEmpty ? "None" : "\(settings.customVocabulary.count)")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Custom vocabulary")
                    Text("Fix names and words the transcript gets wrong.")
                }
            }
            .settingsAnchor(.vocabulary)
        }
    }

    // MARK: Consent

    private var consentSection: some View {
        Section("Recording consent") {
            Toggle(isOn: $settings.consentReminderEnabled) {
                Text("Remind me to tell people")
                Text("A short note when a recording starts that you're taking AI notes.")
            }
            .disabled(settings.allPartyConsentMode)
            .settingsAnchor(.consentReminder)

            Toggle(isOn: $settings.allPartyConsentMode) {
                Text("Everyone must agree to be recorded")
                Text("For places with all-party consent laws. The reminder always shows.")
            }
            .settingsAnchor(.allPartyConsent)

            if settings.consentReminderEnabled || settings.allPartyConsentMode {
                LabeledContent {
                    Button(copiedDisclosure ? "Copied" : "Copy") {
                        ConsentDisclosure.copyToPasteboard(ConsentDisclosure.chatMessage(displayName: settings.displayName))
                        copiedDisclosure = true
                    }
                } label: {
                    Text("Message for the meeting chat")
                    Text(ConsentDisclosure.chatMessage(displayName: settings.displayName))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Data

    static func engineDescription(_ engine: AppSettings.STTEngineType) -> String {
        switch engine {
        case .parakeet: "Live with Apple's on-device transcriber (punctuated, many languages); Parakeet when it can't. Nothing leaves this Mac."
        case .graniteSpeech: "Runs on this Mac. English, French, German, Spanish, Portuguese and Japanese."
        case .whisperKit: "Whisper on this Mac. Many languages. Downloads on first use."
        case .appleSpeech: "Apple's on-device transcriber, live and after the meeting."
        }
    }

    struct Language { let code: String; let name: String }

    static let languages: [Language] = [
        Language(code: "en-US", name: "English (US)"),
        Language(code: "en-GB", name: "English (UK)"),
        Language(code: "es-ES", name: "Spanish"),
        Language(code: "es-419", name: "Spanish (Latin America)"),
        Language(code: "fr-FR", name: "French"),
        Language(code: "de-DE", name: "German"),
        Language(code: "pt-BR", name: "Portuguese (Brazil)"),
        Language(code: "pt-PT", name: "Portuguese (Portugal)"),
        Language(code: "it-IT", name: "Italian"),
        Language(code: "ja-JP", name: "Japanese"),
        Language(code: "ko-KR", name: "Korean"),
        Language(code: "zh-Hans", name: "Chinese (Simplified)"),
        Language(code: "zh-Hant", name: "Chinese (Traditional)"),
        Language(code: "nl-NL", name: "Dutch"),
        Language(code: "ru-RU", name: "Russian"),
        Language(code: "ar-SA", name: "Arabic"),
        Language(code: "hi-IN", name: "Hindi"),
        Language(code: "tr-TR", name: "Turkish"),
        Language(code: "pl-PL", name: "Polish"),
        Language(code: "sv-SE", name: "Swedish"),
    ]
}

// MARK: - Custom vocabulary

struct VocabularyPage: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(pane: .recording, subpage: .vocabulary,
                     subtitle: "When the transcript hears the word on the left, LidIA writes the one on the right.") {
            Section {
                if settings.customVocabulary.isEmpty {
                    Text("No words yet. Add names, products or jargon the transcript keeps getting wrong.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.customVocabulary) { $entry in
                    HStack(spacing: 10) {
                        TextField("Heard as", text: $entry.heardAs, prompt: Text("Heard as"))
                            .labelsHidden()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("becomes")
                        TextField("Replace with", text: $entry.replaceTo, prompt: Text("Replace with"))
                            .labelsHidden()
                        let entryID = entry.id
                        Button {
                            settings.customVocabulary.removeAll { $0.id == entryID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove")
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Word") {
                        settings.customVocabulary.append(AppSettings.VocabularyEntry(heardAs: "", replaceTo: ""))
                    }
                }
            }

            VocabularySuggestionsSection(settings: settings)
        }
    }
}
