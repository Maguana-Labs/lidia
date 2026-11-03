import SwiftUI
import FluidAudio

struct SetupWizardView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(TTSModelManager.self) private var ttsModelManager
    @Environment(\.openSettings) private var openSettings

    /// The on-device model recommended for this Mac's memory.
    private var recommendedLLM: ModelCatalogEntry { ModelCatalog.recommendedForThisMac }
    private var appleIntelligenceReady: Bool { AppleFoundationClient.availability == .available }
    private var llmInstalled: Bool { modelManager.isDownloaded(recommendedLLM.id) || !modelManager.downloadedEntries.isEmpty }

    enum Step {
        case welcome
        case downloading
        case ready
    }

    @State private var step: Step = .welcome

    // Download selections
    @State private var downloadParakeet = true
    @State private var downloadLLM = true
    @State private var downloadTTS = true

    // Download state
    @State private var currentDownloadLabel = ""
    @State private var currentDownloadStep = 0
    @State private var totalDownloadSteps = 0
    @State private var parakeetError: String?

    private var defaultTTSModel: TTSModelManager.TTSModelInfo {
        ttsModelManager.availableModels.first!
    }

    private var parakeetModelsExist: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    private var selectedCount: Int {
        (downloadParakeet ? 1 : 0) + (downloadLLM ? 1 : 0) + (downloadTTS ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .welcome:
                welcomeView
            case .downloading:
                downloadingView
            case .ready:
                readyView
            }
        }
        .padding(40)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 520)
        .onAppear {
            if parakeetModelsExist {
                downloadParakeet = false
            }
            if llmInstalled || modelManager.preflight(recommendedLLM.id) != nil {
                downloadLLM = false
            }
            if ttsModelManager.isTTSModelAvailable {
                downloadTTS = false
            }
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Welcome to LidIA")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("LidIA can run entirely on your Mac — your audio and meetings never leave your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Select which local models to download:")
                    .font(.subheadline.bold())

                VStack(alignment: .leading, spacing: 10) {
                    modelToggle(
                        isOn: $downloadParakeet,
                        icon: "waveform",
                        iconColor: .blue,
                        title: "Parakeet TDT 0.6B",
                        subtitle: "Speech-to-text for live transcription (~200 MB)",
                        alreadyDownloaded: parakeetModelsExist
                    )

                    modelToggle(
                        isOn: $downloadLLM,
                        icon: "text.badge.star",
                        iconColor: .orange,
                        title: "Summaries on this Mac — \(recommendedLLM.displayName)",
                        subtitle: llmSubtitle,
                        alreadyDownloaded: llmInstalled
                    )

                    modelToggle(
                        isOn: $downloadTTS,
                        icon: "speaker.wave.2",
                        iconColor: .purple,
                        title: defaultTTSModel.name,
                        subtitle: "Text-to-speech for voice assistant (\(defaultTTSModel.sizeDescription))",
                        alreadyDownloaded: ttsModelManager.isTTSModelAvailable
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                Button(selectedCount > 0 ? "Download Selected Models" : "Continue Without Local Models") {
                    if selectedCount > 0 {
                        startDownloads()
                    } else {
                        settings.hasCompletedSetup = true
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button("Use a cloud provider instead") {
                    useCloudProvider()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)

                Text("Cloud providers use your own API key, and meeting data is sent to them. You can switch any time in Settings → AI.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// "5.2 GB, fits your 16 GB Mac. Apple Intelligence handles summaries until it's ready."
    private var llmSubtitle: String {
        let size = String(format: "%.1f GB", recommendedLLM.downloadGB)
        let memory = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        if let problem = modelManager.preflight(recommendedLLM.id) {
            return problem.localizedDescription
        }
        if appleIntelligenceReady {
            return "\(size), fits your \(memory) GB Mac. Summaries work now with Apple Intelligence; this download makes them better and takes over when it's ready."
        }
        return "\(size), fits your \(memory) GB Mac. Needed for summaries and action items on this Mac."
    }

    /// Skip local models and pick a cloud provider in Settings.
    private func useCloudProvider() {
        cancelAll()
        settings.llmProvider = .automaticLocal
        settings.hasCompletedSetup = true
        openSettings()
    }

    private func modelToggle(
        isOn: Binding<Bool>,
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        alreadyDownloaded: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if alreadyDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 20)
            } else {
                Toggle("", isOn: isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }

            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.bold())
                    if alreadyDownloaded {
                        Text("Downloaded")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    // MARK: - Downloading

    private var downloadingView: some View {
        VStack(spacing: 20) {
            Text("Step \(currentDownloadStep) of \(totalDownloadSteps)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(currentDownloadLabel)
                .font(.title2.bold())

            if currentDownloadLabel.contains("TTS") {
                if ttsModelManager.downloadProgress > 0 && ttsModelManager.downloadProgress < 1 {
                    ProgressView(value: ttsModelManager.downloadProgress)
                        .frame(maxWidth: 300)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            } else {
                ProgressView()
                    .controlSize(.large)

                Text("This may take a minute...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let error = parakeetError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)

                HStack(spacing: 10) {
                    Button("Retry") {
                        parakeetError = nil
                        startDownloads()
                    }
                    .buttonStyle(.glass)

                    Button("Skip and continue") {
                        parakeetError = nil
                        downloadParakeet = false
                        startDownloads()
                    }
                    .buttonStyle(.glass)
                }
            }

            llmBackgroundStatus

            if let error = ttsModelManager.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)

                HStack(spacing: 10) {
                    Button("Retry") {
                        startDownloads()
                    }
                    .buttonStyle(.glass)

                    Button("Skip and continue") {
                        downloadTTS = false
                        startDownloads()
                    }
                    .buttonStyle(.glass)
                }
            }

            HStack(spacing: 16) {
                Button("Back") {
                    cancelAll()
                    step = .welcome
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Cancel setup") {
                    cancelAll()
                    settings.hasCompletedSetup = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// Progress of the on-device model, which downloads in the background
    /// while the other steps run and after setup finishes.
    @ViewBuilder
    private var llmBackgroundStatus: some View {
        if let status = modelManager.downloadStatus, status.modelID == recommendedLLM.id {
            VStack(spacing: 6) {
                switch status.phase {
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("Retry \(recommendedLLM.displayName)") {
                            modelManager.downloadModel(recommendedLLM.id)
                        }
                        .buttonStyle(.glass)
                        Button("Skip") { downloadLLM = false }
                            .buttonStyle(.glass)
                    }
                case .finished:
                    Label("\(recommendedLLM.displayName) ready for summaries", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                default:
                    Text("\(recommendedLLM.displayName) (in the background)")
                        .font(.caption.bold())
                    ProgressView(value: status.fraction)
                        .frame(maxWidth: 300)
                    Text(status.phase == .verifying ? "Verifying files\u{2026}" : status.progressDescription)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func cancelAll() {
        // The on-device model keeps downloading in the background: it is
        // resumable and finishing it is what makes summaries work.
        // TTS and Parakeet downloads run via async APIs without cancel handles today;
        // task is implicitly cancelled when step changes, but we surface the intent.
        parakeetError = nil
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("All Set!")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 8) {
                if parakeetModelsExist {
                    Label("Parakeet TDT ready for transcription", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if llmInstalled {
                    Label("\(recommendedLLM.displayName) ready for summaries", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if modelManager.downloadStatus?.isActive == true {
                    Label(
                        appleIntelligenceReady
                            ? "\(recommendedLLM.displayName) is downloading; Apple Intelligence handles summaries until it's ready"
                            : "\(recommendedLLM.displayName) is downloading; summaries start when it's ready",
                        systemImage: "arrow.down.circle"
                    )
                    .foregroundStyle(.secondary)
                } else if appleIntelligenceReady {
                    Label("Apple Intelligence ready for summaries", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Label("Summaries need an on-device model or a cloud provider. Set one up in Settings → AI.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if ttsModelManager.isTTSModelAvailable {
                    Label("\(defaultTTSModel.name) ready for voice assistant", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            .font(.subheadline)

            llmBackgroundStatus

            Text("Everything runs locally on your Mac. No data leaves your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Using LidIA") {
                // Automatic on-device AI: the downloaded model when present,
                // Apple Intelligence until then. Never Ollama.
                settings.llmProvider = .automaticLocal
                settings.hasCompletedSetup = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Download Orchestration

    private func startDownloads() {
        guard selectedCount > 0 else {
            settings.llmProvider = .automaticLocal
            settings.hasCompletedSetup = true
            return
        }

        // The on-device model downloads in the background (resumable) while
        // the smaller downloads run; it isn't a blocking step.
        if downloadLLM && !llmInstalled && !modelManager.isDownloading {
            if settings.selectedMLXModelID.isEmpty {
                settings.selectedMLXModelID = recommendedLLM.id
            }
            modelManager.downloadModel(recommendedLLM.id)
        }

        let blockingSteps = selectedCount - (downloadLLM ? 1 : 0)
        guard blockingSteps > 0 else {
            step = .ready
            return
        }

        totalDownloadSteps = blockingSteps
        currentDownloadStep = 0
        step = .downloading

        Task {
            // Step 1: Parakeet (if selected)
            if downloadParakeet && !parakeetModelsExist {
                currentDownloadStep += 1
                currentDownloadLabel = "Downloading Parakeet TDT"
                do {
                    try await AsrModels.download(version: .v3)
                    let streamingDir = ParakeetEngine.streamingModelsDirectory()
                    try await ParakeetEngine.downloadStreamingModelsIfNeeded(to: streamingDir)
                } catch {
                    parakeetError = error.localizedDescription
                    return
                }
            }

            // Step 2: TTS (if selected)
            if downloadTTS && !ttsModelManager.isTTSModelAvailable {
                currentDownloadStep += 1
                currentDownloadLabel = "Downloading \(defaultTTSModel.name)"
                guard let ttsModel = ttsModelManager.availableModels.first else {
                    ttsModelManager.downloadError = "No TTS models available. Check your internet connection."
                    return
                }
                await ttsModelManager.download(ttsModel)
                if ttsModelManager.downloadError != nil { return }
            }

            step = .ready
        }
    }
}
