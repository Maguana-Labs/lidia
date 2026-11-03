import Foundation
import SwiftData
import os

@MainActor
final class PostProcessingService {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "PostProcessingService")

    private let maxQueueAttempts = 8
    private var queueDrainTask: Task<Void, Never>?
    private let queue: DeferredMeetingProcessingQueue

    init(queue: DeferredMeetingProcessingQueue = .shared) {
        self.queue = queue
    }


    /// Meetings currently inside `processAfterCapture`, so the drain loop never runs one twice.
    private(set) var inFlightMeetingIDs: Set<UUID> = []

    /// - Parameters:
    ///   - transcribeFromRecordedAudio: build the transcript from the meeting's recording on
    ///     disk first (a meeting requeued after a crash with audio but no usable transcript).
    ///   - rawTracksDirectory: raw tracks kept by the caller until the transcript is saved;
    ///     they are deleted once the transcribing stage is done.
    func processAfterCapture(
        meeting: Meeting,
        micSamples: [Float],
        systemSamples: [Float],
        reTranscribe: Bool = true,
        sourceEvents: [AudioSourceEvent],
        modelContext: ModelContext,
        settings: AppSettings,
        eventKitManager: EventKitManager?,
        modelManager: ModelManager? = nil,
        transcribeFromRecordedAudio: Bool = false,
        rawTracksDirectory: URL? = nil
    ) async {
        // The meeting can be deleted while this awaits (sync, or the MCP inbox, in another
        // context). After every await it is re-fetched by this ID before it is touched.
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        inFlightMeetingIDs.insert(meetingID)
        defer { inFlightMeetingIDs.remove(meetingID) }
        func wasDeleted() async -> Bool {
            guard !LiveModel.meetingExists(meetingID, in: home) else { return false }
            Self.logger.info("Meeting \(meetingID.uuidString) was deleted while processing; stopping")
            ProcessingProgressCenter.shared.end(meetingID: meetingID)
            await queue.remove(meetingID)
            return true
        }

        let progress = ProcessingProgressCenter.shared.start(meetingID: meetingID)
        if meeting.status != .processing {
            meeting.status = .processing
            try? modelContext.save()
        }

        if transcribeFromRecordedAudio {
            progress.begin(.transcribing, detail: String(localized: "Transcribing recorded audio"))
            let factory = TranscriptionService().makeFactory(settings: settings)
            let vocabulary = settings.customVocabulary
            await RecordingRecovery.transcribeFromRecordedAudio(
                meeting: meeting,
                modelContext: modelContext,
                transcribe: { mic, system in
                    await TranscriptionService.transcribeRecorded(mic: mic, system: system, factory: factory, vocabulary: vocabulary)
                },
                applyVocabulary: { settings.applyVocabulary(to: $0) }
            )
            if await wasDeleted() { return }
            if !ProcessingRecovery.hasTextContent(meeting) {
                meeting.status = .failed
                meeting.processingError = RecordingRecovery.noSpeechMessage
                try? modelContext.save()
                progress.fail(.transcribing, message: RecordingRecovery.noSpeechMessage)
                ProcessingProgressCenter.shared.end(meetingID: meetingID)
                NotificationCenter.default.post(name: .meetingProcessingDidFail, object: meeting)
                await queue.remove(meetingID)
                return
            }
        }

        let combinedSamples = micSamples + systemSamples
        let useBatch = reTranscribe
            && (settings.sttEngine == .parakeet || settings.sttEngine == .graniteSpeech)
            && !combinedSamples.isEmpty

        // Stage: transcribing. Batch re-transcription improves on the live transcript;
        // if it fails we keep the live transcript instead of failing the meeting.
        if useBatch {
            progress.begin(.transcribing, detail: String(localized: "Transcribing audio"))
            do {
                let words = try await batchTranscribe(
                    micSamples: micSamples,
                    systemSamples: systemSamples,
                    sourceEvents: sourceEvents,
                    settings: settings
                )
                if await wasDeleted() { return }
                if let words { meeting.rawTranscript = words }
            } catch {
                if await wasDeleted() { return }
                Self.logger.warning("Batch transcription failed, keeping live transcript: \(error.localizedDescription)")
                progress.warn(String(localized: "Re-transcription failed; using the live transcript."))
            }
            try? modelContext.save()
        }

        // Who said what: mic = You, system audio = Others, and diarization numbers several
        // remote voices (or other voices in the room when only the mic was recorded).
        if !meeting.rawTranscript.isEmpty {
            let words = meeting.rawTranscript
            let hasSystemWords = words.contains { $0.isLocalSpeaker == false }
            var segments: [SpeakerAttribution.Segment] = []
            if settings.enableDiarization {
                let track = hasSystemWords ? systemSamples : micSamples
                if !track.isEmpty {
                    progress.begin(.transcribing, detail: String(localized: "Telling speakers apart"))
                    segments = await RecordingDiarizer.segments(samples: track)
                    if await wasDeleted() { return }
                }
            }
            meeting.rawTranscript = hasSystemWords
                ? SpeakerAttribution.labelCall(words, systemSegments: segments)
                : SpeakerAttribution.labelRoom(words, segments: segments)
            try? modelContext.save()
        }
        progress.complete(.transcribing)
        if let rawTracksDirectory {
            // The transcript is saved; the encoded files replace the raw tracks.
            RecordingFinalizer.discardRawTracks(in: rawTracksDirectory)
        }

        do {
            try await runPipelineAndAutomation(
                meeting: meeting,
                modelContext: modelContext,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: modelManager,
                preserveUserEdits: true
            )
            if await wasDeleted() { return }
            meeting.processingRetryCount = 0
            try? modelContext.save()
            NotificationCenter.default.post(name: .meetingDidFinishProcessing, object: meeting)
            await queue.remove(meetingID)
        } catch {
            if await wasDeleted() { return }
            if shouldQueue(error), meeting.processingRetryCount < maxQueueAttempts {
                meeting.processingRetryCount += 1
                meeting.status = .queued
                meeting.processingError = String(localized: "Processing queued (attempt \(meeting.processingRetryCount)/\(maxQueueAttempts)): \(error.localizedDescription)")
                try? modelContext.save()
                await queue.enqueue(meetingID)
                Self.logger.warning("Meeting queued for deferred processing: \(meetingID.uuidString)")
            } else {
                meeting.status = .failed
                // Keep the pipeline's more specific message (e.g. "Summary generation failed: …").
                if meeting.processingError?.isEmpty ?? true {
                    meeting.processingError = error.localizedDescription
                }
                try? modelContext.save()
                NotificationCenter.default.post(name: .meetingProcessingDidFail, object: meeting)
                NotificationDispatcher.sendProcessingFailed(
                    meetingTitle: meeting.title,
                    meetingID: meetingID,
                    reason: meeting.processingError
                )
                await queue.remove(meetingID)
                Self.logger.error("Meeting processing failed permanently: \(error.localizedDescription)")
            }
        }
        ProcessingProgressCenter.shared.end(meetingID: meetingID)

        // Unload MLX model after processing to free RAM
        if settings.llmProvider == .mlx {
            modelManager?.unloadModel()
        }
    }

    func startQueueDrainLoop(
        contextProvider: @escaping @MainActor () -> (modelContext: ModelContext, settings: AppSettings, eventKitManager: EventKitManager?, modelManager: ModelManager?)?
    ) {
        guard queueDrainTask == nil else { return }

        queueDrainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let env = contextProvider() {
                    await self.drainQueuedMeetings(
                        modelContext: env.modelContext,
                        settings: env.settings,
                        eventKitManager: env.eventKitManager,
                        modelManager: env.modelManager
                    )
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopQueueDrainLoop() {
        queueDrainTask?.cancel()
        queueDrainTask = nil
    }

    /// Re-transcribes the captured audio with the batch engine (Parakeet or Granite),
    /// labelling words Me/Them by stream. Returns nil when the batch engine produced no
    /// words, so the caller keeps the live transcript. It never touches the meeting: the
    /// caller first checks the meeting still exists after this long await.
    private func batchTranscribe(
        micSamples: [Float],
        systemSamples: [Float],
        sourceEvents: [AudioSourceEvent],
        settings: AppSettings
    ) async throws -> [TranscriptWord]? {
        var result: [TranscriptWord]?
        let combinedSamples = micSamples + systemSamples
        let useParakeetBatch = settings.sttEngine == .parakeet && !combinedSamples.isEmpty
        let useGraniteBatch = settings.sttEngine == .graniteSpeech && !combinedSamples.isEmpty
        let enableDiarization = settings.enableDiarization
        let vadEnabled = settings.useVADPreFilter
        let enhanceEnabled = settings.useSpeechEnhancement

        Self.logger.info("""
            Post-processing input: mic=\(micSamples.count) system=\(systemSamples.count) \
            parakeet=\(useParakeetBatch) granite=\(useGraniteBatch) diarization=\(enableDiarization) \
            sourceEvents=\(sourceEvents.count)
            """)
        // === VAD PRE-FILTER: Strip silence before batch STT ===
        var filteredMic = micSamples
        var filteredSystem = systemSamples
        var filteredCombined = combinedSamples
        // Map transcript times in the silence-trimmed audio back to the recording, so
        // the separately transcribed mic and system words interleave correctly.
        var micTimeMap = SpeechTimeMap.identity
        var systemTimeMap = SpeechTimeMap.identity

        if vadEnabled && !combinedSamples.isEmpty {
            do {
                let vad = VADFilter.shared
                if !micSamples.isEmpty {
                    (filteredMic, micTimeMap) = try await vad.filterSpeechKeepingTimeline(samples: micSamples, sampleRate: 16000)
                }
                if !systemSamples.isEmpty {
                    (filteredSystem, systemTimeMap) = try await vad.filterSpeechKeepingTimeline(samples: systemSamples, sampleRate: 16000)
                }
                filteredCombined = filteredMic + filteredSystem
                Self.logger.info("VAD pre-filter complete: \(combinedSamples.count) → \(filteredCombined.count) samples")
            } catch {
                Self.logger.warning("VAD pre-filter failed, using unfiltered audio: \(error.localizedDescription)")
                filteredMic = micSamples
                filteredSystem = systemSamples
                filteredCombined = combinedSamples
                micTimeMap = .identity
                systemTimeMap = .identity
            }
        }
        let singleTrackTimeMap = filteredMic.isEmpty ? systemTimeMap : micTimeMap

        // === SPEECH ENHANCEMENT: Denoise before batch STT ===
        if enhanceEnabled && !filteredCombined.isEmpty {
            do {
                let enhancer = SpeechEnhancerWrapper.shared
                if !filteredMic.isEmpty {
                    filteredMic = try await enhancer.enhance(samples: filteredMic, sampleRate: 16000)
                }
                if !filteredSystem.isEmpty {
                    filteredSystem = try await enhancer.enhance(samples: filteredSystem, sampleRate: 16000)
                }
                filteredCombined = filteredMic + filteredSystem
                Self.logger.info("Speech enhancement complete: \(filteredCombined.count) samples")
            } catch {
                Self.logger.warning("Speech enhancement failed, using unenhanced audio: \(error.localizedDescription)")
                // Fall through with existing filtered samples
            }
        }

        if useParakeetBatch {
            let processor = ParakeetBatchProcessor()

            // === GRANOLA APPROACH: Transcribe mic and system audio SEPARATELY ===
            if !filteredMic.isEmpty && !filteredSystem.isEmpty {
                Self.logger.info("Using dual-stream transcription: mic=\(filteredMic.count) system=\(filteredSystem.count)")

                // Transcribe each stream independently
                let vocab = settings.customVocabulary
                async let micWordsAsync = processor.transcribeOnly(samples: filteredMic, vocabulary: vocab)
                async let sysWordsAsync = processor.transcribeOnly(samples: filteredSystem, vocabulary: vocab)
                let micWords = micTimeMap.remap(try await micWordsAsync)
                let sysWords = systemTimeMap.remap(try await sysWordsAsync)

                // Label by source, drop mic echoes of the other side, merge by time
                let merged = SpeakerStreamMerger.merge(mic: micWords, system: sysWords)
                Self.logger.info("Dual-stream: \(micWords.count) mic words + \(sysWords.count) system words = \(merged.count) total")

                if !merged.isEmpty {
                    result = merged
                    Self.logger.info("Dual-stream transcription replaced output with \(merged.count) words")
                }
            } else {
                // Fallback: single stream (mic-only or system-only)
                // Speakers are attributed afterwards (`SpeakerAttribution`): the track's
                // source says who it is, diarization splits voices within it.
                Self.logger.info("Single-stream batch with \(filteredCombined.count) samples")
                let batchWords = try await processor.transcribeOnly(samples: filteredCombined, vocabulary: settings.customVocabulary)
                if !batchWords.isEmpty {
                    var tagged = singleTrackTimeMap.remap(batchWords)
                    let isMic = !filteredMic.isEmpty
                    for i in tagged.indices { tagged[i].isLocalSpeaker = isMic }
                    result = tagged
                    Self.logger.info("Batch transcription replaced stream output with \(tagged.count) words")
                }
            }
        } else if useGraniteBatch {
            // === DUAL-STREAM: Transcribe mic and system audio SEPARATELY ===
            if !filteredMic.isEmpty && !filteredSystem.isEmpty {
                Self.logger.info("Granite dual-stream transcription: mic=\(filteredMic.count) system=\(filteredSystem.count)")

                let micEngine = GraniteSpeechEngine()
                let sysEngine = GraniteSpeechEngine()

                let micStream = AsyncStream<AudioChunk> { continuation in
                    continuation.yield(AudioChunk(samples: filteredMic, sampleRate: 16000, timestamp: 0, source: .mic))
                    continuation.finish()
                }
                let sysStream = AsyncStream<AudioChunk> { continuation in
                    continuation.yield(AudioChunk(samples: filteredSystem, sampleRate: 16000, timestamp: 0, source: .system))
                    continuation.finish()
                }

                // Transcribe each stream independently
                async let micWordsAsync = { () async -> [TranscriptWord] in
                    var words: [TranscriptWord] = []
                    for await word in micEngine.transcribe(audioStream: micStream) {
                        words.append(word)
                    }
                    return words
                }()
                async let sysWordsAsync = { () async -> [TranscriptWord] in
                    var words: [TranscriptWord] = []
                    for await word in sysEngine.transcribe(audioStream: sysStream) {
                        words.append(word)
                    }
                    return words
                }()

                let micWords = micTimeMap.remap(await micWordsAsync)
                let sysWords = systemTimeMap.remap(await sysWordsAsync)

                // Label by source, drop mic echoes of the other side, merge by time
                let merged = SpeakerStreamMerger.merge(mic: micWords, system: sysWords)
                Self.logger.info("Granite dual-stream: \(micWords.count) mic words + \(sysWords.count) system words = \(merged.count) total")

                if !merged.isEmpty {
                    result = merged
                    Self.logger.info("Granite dual-stream transcription replaced output with \(merged.count) words")
                }
            } else {
                // Fallback: single stream (mic-only or system-only)
                Self.logger.info("Running Granite Speech single-stream batch transcription with \(filteredCombined.count) samples")
                let engine = GraniteSpeechEngine()
                let audioStream = AsyncStream<AudioChunk> { continuation in
                    continuation.yield(AudioChunk(samples: filteredCombined, sampleRate: 16000, timestamp: 0, source: .mic))
                    continuation.finish()
                }
                var batchWords: [TranscriptWord] = []
                for await word in engine.transcribe(audioStream: audioStream) {
                    batchWords.append(word)
                }
                if !batchWords.isEmpty {
                    batchWords = singleTrackTimeMap.remap(batchWords)
                    let isMic = !filteredMic.isEmpty
                    for i in batchWords.indices { batchWords[i].isLocalSpeaker = isMic }
                    result = batchWords
                    Self.logger.info("Granite batch transcription produced \(batchWords.count) words")
                }
            }
        }
        return result
    }

    /// Processes every queued meeting.
    ///
    /// Self-healing: any meeting whose status is `.queued` is (re-)added to the queue even
    /// if the persisted queue lost it. Queued IDs whose meeting is `.queued`, `.processing`
    /// (interrupted by a crash) or `.recording` (finalised by crash recovery) are
    /// processed; `.complete` / `.failed` ones are dropped from the queue.
    ///
    /// Each meeting is fetched by ID right before it is processed, never taken from a list
    /// fetched earlier: processing one meeting takes minutes, and any meeting can be
    /// deleted meanwhile. `process` stands in for `processAfterCapture` in tests.
    func drainQueuedMeetings(
        modelContext: ModelContext,
        settings: AppSettings,
        eventKitManager: EventKitManager?,
        modelManager: ModelManager? = nil,
        process: (@MainActor (Meeting) async -> Void)? = nil
    ) async {
        let queuedNow = ((try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter { $0.status == .queued }
            .map(\.id)
        for id in queuedNow {
            await queue.enqueue(id)
        }

        let queuedIDs = await queue.all()
        guard !queuedIDs.isEmpty else { return }

        for id in queuedIDs {
            guard let meeting = LiveModel.meeting(id, in: modelContext) else {
                await queue.remove(id)
                continue
            }

            // Already being processed by a live session — leave it in the queue.
            guard !inFlightMeetingIDs.contains(id) else { continue }

            guard Self.drainableStatuses.contains(meeting.status) else {
                await queue.remove(id)
                continue
            }

            if meeting.processingRetryCount >= maxQueueAttempts {
                meeting.status = .failed
                meeting.processingError = "Exceeded max queued processing attempts (\(maxQueueAttempts))."
                try? modelContext.save()
                await queue.remove(id)
                continue
            }

            meeting.status = .processing
            meeting.processingError = nil
            try? modelContext.save()

            if let process {
                await process(meeting)
                continue
            }
            await processAfterCapture(
                meeting: meeting,
                micSamples: [],
                systemSamples: [],
                sourceEvents: [],
                modelContext: modelContext,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: modelManager,
                transcribeFromRecordedAudio: RecordingRecovery.needsTranscriptionFromAudio(meeting)
            )
        }
    }

    private func runPipelineAndAutomation(
        meeting: Meeting,
        modelContext: ModelContext,
        settings: AppSettings,
        eventKitManager: EventKitManager?,
        modelManager: ModelManager? = nil,
        preserveUserEdits: Bool
    ) async throws {
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .summarization)
        let pipeline = MeetingPipeline(
            llmClient: client,
            modelContext: modelContext
        )
        let model = effectiveModel(for: .summary, settings: settings, taskType: .summarization)
        let transcript = MeetingPipeline.buildRawText(from: meeting.rawTranscript)
        let template = await settings.resolveTemplateAsync(
            for: meeting,
            transcript: transcript,
            llmClient: client,
            model: model
        )
        meeting.templateAutoDetected = true
        settings.rememberTemplateChoice(for: meeting, templateID: template.id)
        try await pipeline.process(
            meeting: meeting,
            model: model,
            template: template,
            vocabulary: settings.customVocabulary,
            preserveUserEdits: preserveUserEdits,
            userName: settings.displayName
        )

        // e.g. "No model selected": the pipeline marked the meeting failed without throwing.
        guard meeting.status == .complete else {
            throw PostProcessingFailure.pipelineDidNotComplete(meeting.processingError ?? "")
        }

        await PostMeetingAutomation.run(
            meeting: meeting,
            modelContext: modelContext,
            settings: settings,
            eventKitManager: eventKitManager,
            modelManager: modelManager
        )
    }

    /// Statuses the drain loop will process when the meeting is in the queue.
    static let drainableStatuses: Set<MeetingStatus> = [.queued, .processing, .recording]

    private enum PostProcessingFailure: LocalizedError {
        case pipelineDidNotComplete(String)
        var errorDescription: String? {
            switch self {
            case .pipelineDidNotComplete(let message): message
            }
        }
    }

    private func shouldQueue(_ error: Error) -> Bool {
        if error is PipelineError || error is PostProcessingFailure || error is CancellationError {
            return false
        }
        if isConfigurationError(error) {
            return false
        }
        return RetryClassifier.isRetryable(error)
    }

    private func isConfigurationError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("api key")
            || message.contains("not configured")
            || message.contains("no model selected")
            || message.contains("no model")
    }
}
