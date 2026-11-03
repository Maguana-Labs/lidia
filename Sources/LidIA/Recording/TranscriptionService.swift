import Foundation
import os

/// Everything needed to build an STT engine, captured from settings on the main actor so
/// engines can be created later from any thread (one per audio source).
struct STTEngineFactory: Sendable {
    var engineType: AppSettings.STTEngineType
    /// IANA locale identifier; empty means the system language.
    var language: String
    var whisperKitModel: String
    /// Names and terms to bias recognition toward (custom vocabulary, attendees). Used by
    /// Apple's SpeechAnalyzer.
    var contextualStrings: [String] = []

    /// Engines that only produce words after all audio is in. They're not run live; the
    /// recording is transcribed from disk when it stops.
    var isBatchOnly: Bool {
        engineType == .graniteSpeech
    }

    /// Engines whose post-recording pass needs the recorded samples in memory.
    var needsRecordedSamples: Bool {
        engineType == .parakeet || engineType == .graniteSpeech
    }

    func makeEngine() -> any STTEngine {
        makeEngine(engineType)
    }

    /// The locale Apple Speech uses for this factory.
    var appleSpeechLocale: Locale {
        language.isEmpty ? Locale.current : Locale(identifier: language)
    }

    /// Picks the live engine and its fallback from what's on this Mac.
    func livePlan(
        parakeetLiveModelPresent: Bool = ParakeetEngine.streamingModelsAvailable(),
        appleOnDeviceAvailable: Bool? = nil,
        analyzer: AnalyzerAvailability = .unsupported
    ) -> LiveEnginePlan {
        LiveEnginePlan.make(
            requested: engineType,
            parakeetLiveModelPresent: parakeetLiveModelPresent,
            appleOnDeviceAvailable: appleOnDeviceAvailable
                ?? AppleSpeechEngine.isOnDeviceFallbackAvailable(for: appleSpeechLocale),
            analyzer: analyzer
        )
    }

    /// The live plan with Apple's SpeechAnalyzer looked up for this language.
    func resolvedLivePlan() async -> LiveEnginePlan {
        livePlan(analyzer: await SpeechAnalyzerEngine.availability(for: appleSpeechLocale))
    }

    /// Whether the live transcript is as good as a transcript made after the meeting, so
    /// the recording needn't be transcribed again (the user keeps the text they saw).
    /// Apple's SpeechAnalyzer transcript is punctuated and timed and scored better than
    /// Parakeet's batch pass on the reference recording; the Parakeet live model is
    /// lowercase, unpunctuated and untimed, so the batch pass replaces it.
    static func liveTranscriptIsFinal(engine: AppSettings.STTEngineType?) -> Bool {
        engine == .appleSpeech
    }

    /// A live engine for one source lane: the plan's primary engine, switching to its
    /// fallback (and reporting it) if the primary stops producing words.
    func makeLiveEngine(plan: LiveEnginePlan, onEvent: @escaping @Sendable (LiveTranscriptionEvent) -> Void) -> any STTEngine {
        let fallback = plan.fallback
        return FallbackSTTEngine(
            primary: makeEngine(plan.primary, live: true),
            primaryType: plan.primary,
            fallbackType: fallback,
            makeFallback: { fallback.map { self.makeEngine($0, live: true) } },
            onEvent: onEvent
        )
    }

    /// `live`: the engine feeds the live transcript, so a quick guess matters more than a
    /// last bit of accuracy (SpeechAnalyzer `fastResults`: words show in 0.5 s instead of 2.4 s).
    func makeEngine(_ engineType: AppSettings.STTEngineType, live: Bool = false) -> any STTEngine {
        switch engineType {
        case .parakeet:
            return ParakeetEngine()
        case .graniteSpeech:
            return GraniteSpeechEngine()
        case .whisperKit:
            return WhisperKitEngine(
                modelName: whisperKitModel,
                language: language.isEmpty ? nil : language
            )
        case .appleSpeech:
            return AppleOnDeviceSpeechEngine(locale: appleSpeechLocale, contextualStrings: contextualStrings, fastResults: live)
        }
    }
}

@MainActor
struct TranscriptionService {
    private nonisolated static let logger = Logger(subsystem: "io.lidia.app", category: "TranscriptionService")

    func makeFactory(settings: AppSettings, attendees: [String] = []) -> STTEngineFactory {
        var terms = settings.customVocabulary.map(\.replaceTo) + attendees
        terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return STTEngineFactory(
            engineType: settings.sttEngine,
            language: settings.sttLanguage,
            whisperKitModel: settings.whisperKitModel,
            contextualStrings: Array(NSOrderedSet(array: terms).array as? [String] ?? terms)
        )
    }

    func makeEngine(settings: AppSettings) -> any STTEngine {
        makeFactory(settings: settings).makeEngine()
    }

    /// Live transcription of the capture stream, one engine per source when system audio is
    /// captured, so live Me/Them labels come from the source rather than a guess.
    ///
    /// Each lane runs `plan.primary` and switches to `plan.fallback` if it fails; anything
    /// that keeps live words from appearing is reported through `onEvent`.
    func liveTranscription(
        of audioStream: AsyncStream<AudioChunk>,
        factory: STTEngineFactory,
        plan: LiveEnginePlan? = nil,
        separateSources: Bool,
        timeline: @escaping @Sendable (TimeInterval) -> TimeInterval,
        onEvent: @escaping @Sendable (LiveTranscriptionEvent) -> Void = { _ in }
    ) -> AsyncStream<TranscriptWord> {
        let plan = plan ?? factory.livePlan()
        let transcriber = SourceSeparatedTranscriber(
            makeEngine: { factory.makeLiveEngine(plan: plan, onEvent: onEvent) },
            separateSources: separateSources,
            timeline: timeline
        )
        return transcriber.transcribe(audioStream)
    }

    /// Live transcription with each lane's volatile guess as well as its final words.
    func liveTranscriptionEvents(
        of audioStream: AsyncStream<AudioChunk>,
        factory: STTEngineFactory,
        plan: LiveEnginePlan,
        separateSources: Bool,
        timeline: @escaping @Sendable (TimeInterval) -> TimeInterval,
        onEvent: @escaping @Sendable (LiveTranscriptionEvent) -> Void = { _ in }
    ) -> AsyncStream<LiveLaneEvent> {
        SourceSeparatedTranscriber(
            makeEngine: { factory.makeLiveEngine(plan: plan, onEvent: onEvent) },
            separateSources: separateSources,
            timeline: timeline
        ).transcribeLive(audioStream)
    }

    /// Transcribes recorded 16 kHz tracks after the fact (crash recovery, or a recording that
    /// produced no live words). Mic and system are transcribed separately and merged with
    /// Me/Them labels; a single track is left unlabelled.
    nonisolated static func transcribeRecorded(
        mic: [Float],
        system: [Float],
        factory: STTEngineFactory,
        vocabulary: [AppSettings.VocabularyEntry] = []
    ) async -> [TranscriptWord] {
        async let micWords = transcribeTrack(mic, factory: factory, vocabulary: vocabulary)
        async let systemWords = transcribeTrack(system, factory: factory, vocabulary: vocabulary)
        let (m, s) = await (micWords, systemWords)
        if !m.isEmpty && !s.isEmpty {
            return SpeakerStreamMerger.merge(mic: m, system: s)
        }
        // One track: its source still says who it is (mic = You, system = Others).
        let isMic = !m.isEmpty
        return (isMic ? m : s)
            .map { word -> TranscriptWord in
                var w = word
                w.isLocalSpeaker = isMic
                return w
            }
            .sorted { $0.start < $1.start }
    }

    nonisolated static func transcribeTrack(
        _ samples: [Float],
        factory: STTEngineFactory,
        vocabulary: [AppSettings.VocabularyEntry]
    ) async -> [TranscriptWord] {
        guard !samples.isEmpty else { return [] }
        if factory.engineType == .parakeet {
            // The streaming Parakeet model is English-only and has no timings; the batch
            // model is multilingual and timed, so use it for recorded audio.
            do {
                return try await ParakeetBatchProcessor().transcribeOnly(samples: samples, vocabulary: vocabulary)
            } catch {
                logger.error("Parakeet batch transcription failed: \(error.localizedDescription)")
                return []
            }
        }
        let engine = factory.makeEngine()
        let stream = recordedChunks(samples)
        var words: [TranscriptWord] = []
        for await word in engine.transcribe(audioStream: stream) {
            words.append(word)
        }
        return words
    }

    /// Splits recorded samples into 0.5 s chunks. Timestamps are each chunk's start offset,
    /// so engines that time words from chunk timestamps (WhisperKit) start at zero.
    nonisolated static func recordedChunks(_ samples: [Float], chunkFrames: Int = 8_000) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + chunkFrames)
                let chunk = Array(samples[offset..<end])
                continuation.yield(AudioChunk(
                    samples: chunk,
                    sampleRate: PCMTrackWriter.sampleRate,
                    timestamp: Double(offset) / Double(PCMTrackWriter.sampleRate),
                    source: .unknown
                ))
                offset = end
            }
            continuation.finish()
        }
    }
}
