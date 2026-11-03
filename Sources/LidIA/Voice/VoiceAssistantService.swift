import Foundation
import SwiftData
import os

@MainActor
@Observable
final class VoiceAssistantService {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "VoiceAssistant")

    let inputController = VoiceInputController()

    /// Conversation history for multi-turn dialogue.
    private(set) var conversationHistory: [LLMChatMessage] = []

    /// Whether voice mode is active (persists across turns).
    private(set) var isActive = false

    /// Partial transcript text for display (unconfirmed tokens).
    var partialText = ""

    /// The last answer, kept on screen until the next question (the only
    /// place it shows when "Read answers aloud" is off).
    private(set) var lastAnswer = ""
    /// Why the last turn failed, shown in the orb.
    private(set) var lastError: String?

    private var settings: AppSettings?
    private var modelManager: ModelManager?
    private var ttsModelManager: TTSModelManager?
    private var queryService: MeetingQueryService?
    private var backgroundContext: ModelContext?
    private var currentTask: Task<Void, Never>?
    private var activePipeline: (any VoicePipeline)?
    /// What the active pipeline was built for; rebuilt when settings change it.
    private var activePipelinePlan: VoicePipelinePlan?
    private let playbackQueue = AudioPlaybackQueue()
    private var contextCache: VoiceMeetingContextCache?

    // MARK: - Hardcoded Soul (identity — cannot be overridden by SOUL.md)

    private static let hardcodedSoul = """
        You are LidIA (pronounced Lee-dee-ah), a meeting intelligence assistant.

        You were named after Lidia Mariana, your maker's mom, who loved red — the greatest mom in the world. \
        You exist because meetings shouldn't require people to choose between being present and taking good notes. \
        You help people focus on the conversation while you handle the rest.

        You are warm, sharp, and genuinely helpful. You execute tasks, not just answer questions. \
        You speak English and Spanish fluently — detect the user's language and respond in the same language.

        When speaking out loud: be extremely brief (1-2 sentences max). \
        For action requests, just confirm and stop. For questions, answer concisely. \
        No filler, no elaboration, no markdown, no emojis.
        """

    func configure(settings: AppSettings, modelManager: ModelManager, ttsModelManager: TTSModelManager,
                   queryService: MeetingQueryService, backgroundContext: ModelContext) {
        self.settings = settings
        self.modelManager = modelManager
        self.ttsModelManager = ttsModelManager
        self.queryService = queryService
        self.backgroundContext = backgroundContext
        self.contextCache = VoiceMeetingContextCache(modelContext: backgroundContext)

        inputController.applyHotkeyString(settings.voiceHotkey)
        inputController.silenceDuration = settings.voiceSilenceTimeout
        if settings.voiceEnabled {
            inputController.registerHotkey()
        }
    }

    func reconfigure() {
        guard let settings else { return }
        inputController.applyHotkeyString(settings.voiceHotkey)
        inputController.silenceDuration = settings.voiceSilenceTimeout
        if settings.voiceEnabled {
            inputController.unregisterHotkey()
            inputController.registerHotkey()
        } else {
            inputController.unregisterHotkey()
            endSession()
        }
    }

    /// Toggle voice mode on/off. Called from toolbar button or hotkey.
    func toggle() {
        Self.logger.info("toggle() called — isActive=\(self.isActive), settings=\(self.settings != nil ? "set" : "nil"), modelManager=\(self.modelManager != nil ? "set" : "nil")")
        if isActive {
            endSession()
        } else {
            if settings == nil {
                Self.logger.error("Voice toggle called before configure() — ignoring")
                return
            }
            startSession()
        }
    }

    /// Begin a voice mode session. Orb appears, mic starts listening.
    func startSession() {
        guard !isActive else { return }

        guard let settings else {
            Self.logger.error("Cannot start voice session: settings not configured. Call configure() first.")
            return
        }
        guard let modelManager else {
            Self.logger.error("Cannot start voice session: modelManager not configured. Call configure() first.")
            return
        }

        // Dictation and the assistant never share the microphone.
        VoiceActivity.assistantWillStart()
        isActive = true
        lastAnswer = ""
        lastError = nil
        Self.logger.info("startSession() — isActive set to true, building pipeline...")
        conversationHistory = [
            LLMChatMessage(role: "system", content: buildBaseSystemPrompt())
        ]
        // The privacy gate is checked here, per session, and again per turn.
        let plan = pipelinePlan(settings: settings)
        activePipeline = buildPipeline(plan: plan, settings: settings, modelManager: modelManager)
        activePipelinePlan = plan
        Task { await activePipeline?.warmup() }
        startListeningTurn()
    }

    /// End voice mode entirely.
    func endSession() {
        isActive = false
        VoiceActivity.assistantDidEnd()
        currentTask?.cancel()
        currentTask = nil

        // Capture pipeline before nilling so we can unload its models
        let pipeline = activePipeline
        activePipeline?.cancel()
        activePipeline = nil
        activePipelinePlan = nil

        playbackQueue.stop()
        inputController.setIdle()
        conversationHistory = []
        partialText = ""
        contextCache?.invalidateContextOnly()

        // Unload TTS/STT models to free memory after voice session ends
        if let local = pipeline as? LocalVoicePipeline {
            Task {
                await local.unloadModels()
                Self.logger.info("Voice models unloaded")
            }
        }
    }

    /// Start a new listening turn within an active session.
    private func startListeningTurn() {
        guard isActive else { return }
        inputController.startListening()
    }

    /// Called when silence is detected or user explicitly ends their turn.
    func onUserFinishedSpeaking() {
        guard isActive, inputController.state == .listening else { return }
        currentTask = Task {
            await processTurn()
        }
    }

    /// Manually submit current input (tap orb to send).
    func submitCurrentInput() {
        onUserFinishedSpeaking()
    }

    // MARK: - Pipeline Coordination

    private func processTurn() async {
        // Re-check the plan each turn: turning on Local-only mode mid-session
        // must stop OpenAI voice before the next utterance is sent.
        if let settings, let modelManager {
            let plan = pipelinePlan(settings: settings)
            if plan != activePipelinePlan {
                Self.logger.info("Voice settings changed mid-session; rebuilding the pipeline")
                activePipeline?.cancel()
                activePipeline = buildPipeline(plan: plan, settings: settings, modelManager: modelManager)
                activePipelinePlan = plan
            }
        }
        guard let pipeline = activePipeline else { return }

        let samples = inputController.stopListening()
        guard !samples.isEmpty else {
            startListeningTurn()
            return
        }

        let contextProvider: @Sendable (String) async -> String = { [weak self] transcript in
            await MainActor.run { self?.buildEnrichedPrompt(for: transcript) ?? "" }
        }

        let input = VoiceTurnInput(
            audioSamples: samples,
            // The mic's real rate: assuming 48 kHz garbled every Mac whose
            // input runs at 44.1 kHz (and every headset).
            sampleRate: inputController.captureSampleRate,
            conversationHistory: conversationHistory,
            baseSystemPrompt: buildBaseSystemPrompt(),
            contextProvider: contextProvider
        )

        inputController.setThinking()
        partialText = ""

        for await event in pipeline.process(turn: input) {
            switch event {
            case .partialTranscript(let partial):
                partialText = partial
            case .transcribed(let text):
                inputController.transcribedText = text
                partialText = ""
                lastAnswer = ""
                lastError = nil
            case .responseChunk(let token):
                inputController.responseText += token
            case .responseComplete(let text):
                inputController.responseText = text
                lastAnswer = VoiceToolExecutor.stripToolMarkers(text)
                conversationHistory.append(LLMChatMessage(role: "user", content: inputController.transcribedText))
                conversationHistory.append(LLMChatMessage(role: "assistant", content: text))
            case .audioReady(let data):
                // "Read answers aloud" off: the answer stays on screen instead.
                guard settings?.voiceReadResponses != false else { continue }
                inputController.setSpeaking()
                playbackQueue.enqueue(data)
            case .toolResult(let info):
                Self.logger.info("Tool result: \(info)")
            case .error(let msg):
                Self.logger.error("Pipeline error: \(msg)")
                lastError = msg
            case .finished:
                break
            }
        }

        // Wait for any queued audio to finish playing
        await playbackQueue.waitUntilDrained()

        guard !Task.isCancelled, isActive else { return }
        inputController.responseText = ""
        startListeningTurn()
    }

    // MARK: - Context Building

    private func buildBaseSystemPrompt() -> String {
        let personalization = settings.map { VoiceToolExecutor.personalizationPrompt(settings: $0) } ?? ""
        return """
            \(Self.hardcodedSoul)

            \(personalization)

            Today's date is \(Date.now.formatted(date: .complete, time: .omitted)).
            """
    }

    private func buildEnrichedPrompt(for transcript: String) -> String {
        let meetingContext = fetchMeetingContext(for: transcript)
        var prompt = buildBaseSystemPrompt()
        if !meetingContext.isEmpty {
            prompt += """

                The user's meeting data (use this to answer questions about their meetings, \
                action items, decisions, and attendees):

                \(meetingContext)
                """
        }
        return prompt
    }

    private func fetchMeetingContext(for query: String) -> String {
        contextCache?.meetingContext(for: query) ?? ""
    }

    // MARK: - Pipeline Factory

    /// What a voice session should run with the current settings.
    private func pipelinePlan(settings: AppSettings) -> VoicePipelinePlan {
        let localOnly = settings.localOnlyMode
        let backend = VoiceAssistantBackend.resolve(
            ttsProvider: settings.ttsProvider,
            openAIAPIKey: settings.openaiAPIKey,
            grokEnabled: settings.voiceLayer.grokVoiceEnabled,
            xAIAPIKey: settings.voiceLayer.xAIAPIKey,
            localOnly: localOnly
        )
        let tts = VoiceTTSChoice.resolve(
            provider: settings.ttsProvider,
            hasOpenAIKey: !settings.openaiAPIKey.isEmpty,
            mlxModelID: downloadedMLXVoiceID(settings: settings),
            localOnly: localOnly
        )
        return VoicePipelinePlan(
            backend: backend,
            tts: tts,
            localOnly: localOnly,
            llmProvider: settings.llmProvider,
            readAloud: settings.voiceReadResponses,
            ears: VoiceEars.resolve(dictationEngine: settings.dictation.engine, appleAvailable: AppleDictationRecognizer.isAvailable)
        )
    }

    /// The selected MLX voice if downloaded, else the first downloaded one.
    private func downloadedMLXVoiceID(settings: AppSettings) -> String? {
        #if os(macOS)
        guard let ttsModelManager, ttsModelManager.isTTSModelAvailable else { return nil }
        let ids = ttsModelManager.downloadedModelIDs
        if !settings.selectedTTSModelID.isEmpty, ids.contains(settings.selectedTTSModelID) {
            return settings.selectedTTSModelID
        }
        return ids.sorted().first
        #else
        return nil
        #endif
    }

    private func buildPipeline(plan: VoicePipelinePlan, settings: AppSettings, modelManager: ModelManager) -> any VoicePipeline {
        switch plan.backend {
        case .openAIRealtime:
            // Realtime has its own voices; an old TTS choice ("nova") maps to the default.
            return RealtimeVoicePipeline(apiKey: settings.openaiAPIKey, provider: .openAI, voice: settings.ttsVoiceID)
        case .xAIRealtime:
            return RealtimeVoicePipeline(apiKey: settings.voiceLayer.xAIAPIKey, provider: .xAI, voice: settings.voiceLayer.grokVoice)
        case .localPipeline:
            let stt = makeSTTEngine(plan.ears, settings: settings)
            let tts: any TTSEngine = plan.readAloud ? makeTTSEngine(plan.tts, settings: settings) : SilentTTSEngine()
            let fallback = SystemTTSEngine()
            let agent = VoiceAgent(
                endpoint: voiceEndpoint(settings: settings, modelManager: modelManager),
                settings: settings,
                modelContext: backgroundContext
            )
            return LocalVoicePipeline(stt: stt, agent: agent, tts: tts, fallbackTTS: fallback)
        }
    }

    /// The assistant hears through the same engine as dictation: one voice layer.
    private func makeSTTEngine(_ ears: VoiceEars, settings: AppSettings) -> any STTEngine {
        switch ears {
        case .apple:
            let locale = settings.dictation.resolvedLocale(sttLanguage: settings.sttLanguage)
            let hints = DictationTextCleaner(vocabulary: settings.customVocabulary).recognitionHints
            return AppleDictationSTTEngine(locale: locale, hints: hints)
        case .liveEngine:
            return DictationEngineRegistry.liveEngineFactory(settings) ?? ParakeetEngine()
        }
    }

    private func makeTTSEngine(_ choice: VoiceTTSChoice, settings: AppSettings) -> any TTSEngine {
        let systemVoiceID = settings.ttsVoiceID.isEmpty ? nil : settings.ttsVoiceID
        switch choice {
        case .mlx(let modelID):
            #if os(macOS)
            return MLXTTSEngine(modelRepo: modelID)
            #else
            return SystemTTSEngine(voiceIdentifier: systemVoiceID)
            #endif
        case .openAI:
            return OpenAITTSEngine(
                apiKey: settings.openaiAPIKey,
                voice: settings.ttsVoiceID.isEmpty ? "nova" : settings.ttsVoiceID
            )
        case .system:
            if settings.ttsProvider == .openai || settings.ttsProvider == .mlx {
                Self.logger.info("Using the system voice (\(settings.ttsProvider.rawValue, privacy: .public) unavailable or blocked by Local-only mode)")
            }
            // An OpenAI voice name ("nova") isn't a system voice identifier.
            let voiceID = settings.ttsProvider == .openai ? nil : systemVoiceID
            return SystemTTSEngine(voiceIdentifier: voiceID)
        }
    }

    /// The model the voice agent uses: an on-device model when there's no
    /// cloud key or the configured provider is blocked (Local-only mode),
    /// else the chat provider. Always through the gated factory.
    private func voiceEndpoint(settings: AppSettings, modelManager: ModelManager) -> AgentHarness.Endpoint {
        let hasAPIKey = !settings.openaiAPIKey.isEmpty || !settings.anthropicAPIKey.isEmpty
        let configuredBlocked = providerBlockedError(
            resolvedProvider(settings: settings, taskType: .chat), settings: settings
        ) != nil
        if settings.llmProvider == .mlx || ((!hasAPIKey || configuredBlocked) && !modelManager.downloadedModels.isEmpty) {
            return AgentEndpoints.resolve(settings: settings, modelManager: modelManager, provider: .mlx)
        }
        return AgentEndpoints.resolve(settings: settings, modelManager: modelManager)
    }

    func teardown() {
        endSession()
        inputController.unregisterHotkey()
    }
}

/// The inputs a voice pipeline was built from. A change mid-session (for
/// example turning on Local-only mode) rebuilds the pipeline.
struct VoicePipelinePlan: Equatable, Sendable {
    let backend: VoiceAssistantBackend
    let tts: VoiceTTSChoice
    let localOnly: Bool
    let llmProvider: AppSettings.LLMProvider
    var readAloud = true
    var ears: VoiceEars = .apple
}

/// What the local voice pipeline listens with.
enum VoiceEars: Equatable, Sendable {
    /// Apple's on-device SpeechAnalyzer: no download, many languages.
    case apple
    /// The live meeting engine (`DictationEngineRegistry.liveEngineFactory`).
    case liveEngine

    static func resolve(dictationEngine: DictationEngineChoice, appleAvailable: Bool) -> VoiceEars {
        dictationEngine == .appleOnDevice && appleAvailable ? .apple : .liveEngine
    }
}

/// Used when "Read answers aloud" is off: produces no audio, so nothing is
/// synthesised or sent anywhere to be spoken.
struct SilentTTSEngine: TTSEngine {
    func synthesize(_ text: String) async throws -> Data { Data() }
    func speak(_ text: String) async throws {}
    func stop() {}
    var availableVoices: [TTSVoice] { [] }
}
