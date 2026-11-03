import AVFoundation
import FluidAudio
import os
import Synchronization

/// Streaming STT engine using FluidAudio's Parakeet EOU model.
/// Uses StreamingEouAsrManager for real-time transcription during recording.
///
/// Words are emitted progressively via the partial callback (fires on every decoded chunk),
/// then reset on EOU (end-of-utterance silence). The batch processor replaces this
/// streaming transcript with a higher-quality version after recording stops.
/// Thread-safe via Mutex for the pre-loaded manager state.
/// StreamingEouAsrManager is not Sendable, so we use @unchecked Sendable
/// with Mutex-based synchronization for the only shared mutable state.
final class ParakeetEngine: @unchecked Sendable, LiveSTTEngine, STTFailureReporting {

    private static let logger = Logger(subsystem: "io.lidia.app", category: "ParakeetEngine")

    /// After this many chunks in a row fail, the engine stops and reports why, instead of
    /// logging an error per chunk for the whole meeting while the transcript stays empty.
    static let maxConsecutiveProcessingErrors = 3

    private let failureReasonMutex = Mutex<String?>(nil)

    /// Why the last `transcribe` stopped early, or nil while it is fine.
    var failureReason: String? {
        failureReasonMutex.withLock { $0 }
    }

    private func fail(_ reason: String) {
        failureReasonMutex.withLock { $0 = reason }
    }

    /// Pre-loaded manager from `preload()`, reused by `transcribe()` to skip model loading.
    /// Access synchronized via Mutex. StreamingEouAsrManager is not Sendable itself.
    private let preloadedManagerMutex = Mutex<StreamingEouAsrManager?>(nil)

    /// Pre-load the streaming ASR model so the first `transcribe()` call is fast.
    func preload() async throws {
        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 800)
        let modelsDir = Self.streamingModelsDirectory()
        try await Self.downloadStreamingModelsIfNeeded(to: modelsDir)
        try await manager.loadModels(from: modelsDir)
        Self.logger.info("Streaming ASR models pre-loaded")
        preloadedManagerMutex.withLock { $0 = manager }
    }

    /// Take the pre-loaded manager (if any), clearing it so it's only used once.
    private func takePreloadedManager() -> StreamingEouAsrManager? {
        preloadedManagerMutex.withLock { manager in
            let taken = manager
            manager = nil
            return taken
        }
    }

    func transcribeLive(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<LiveSTTEvent> {
        return AsyncStream { continuation in
            Task { @Sendable [weak self] in
                let manager: StreamingEouAsrManager
                if let preloaded = self?.takePreloadedManager() {
                    manager = preloaded
                    ParakeetEngine.logger.info("Reusing pre-loaded ASR manager")
                } else {
                    manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 800)
                    do {
                        let modelsDir = Self.streamingModelsDirectory()
                        try await Self.downloadStreamingModelsIfNeeded(to: modelsDir)
                        try await manager.loadModels(from: modelsDir)
                        ParakeetEngine.logger.info("Streaming ASR models loaded")
                    } catch {
                        ParakeetEngine.logger.error("Failed to load streaming models: \(error.localizedDescription, privacy: .public)")
                        self?.fail("the live model couldn't be loaded: \(error.localizedDescription)")
                        continuation.finish()
                        return
                    }
                }

                // The partial callback gets the whole utterance so far on every decoded
                // chunk. The stitcher sends each word once, after the next word has started
                // (until then the word can still grow: "wor" -> "working").
                let stitcher = Mutex(ParakeetPartialStitcher())

                @Sendable func emit(_ words: [String]) {
                    guard !words.isEmpty else { return }
                    continuation.yield(.finalized(words.map {
                        TranscriptWord(word: $0, start: 0, end: 0, confidence: 0.90, speaker: nil)
                    }))
                }

                await manager.setPartialCallback { partial in
                    let update = stitcher.withLock { $0.update(partial: partial) }
                    emit(update.confirmed)
                    continuation.yield(.volatile(text: update.volatile, start: nil))
                }

                /// Sends the words of a finished utterance that weren't sent yet and starts
                /// the next utterance clean. `transcript` is what `finish()` returns.
                func emitUnsent(of transcript: String?) {
                    emit(stitcher.withLock { $0.finish(utterance: transcript) })
                    continuation.yield(.volatile(text: "", start: nil))
                }

                // Process audio chunks from the capture stream
                var consecutiveErrors = 0
                for await chunk in audioStream {
                    let samples16k: [Float]
                    if chunk.sampleRate != 16000 {
                        samples16k = AudioResampler.resample(chunk.samples, from: chunk.sampleRate, to: 16000)
                    } else {
                        samples16k = chunk.samples
                    }

                    guard let buffer = Self.makePCMBuffer(from: samples16k, sampleRate: 16000) else {
                        continue
                    }

                    do {
                        // process() drives the model; partialCallback fires inside here
                        // when new tokens are decoded. process() itself returns "".
                        _ = try await manager.process(audioBuffer: buffer)

                        // On end-of-utterance (silence detected), finalize and reset
                        if await manager.eouDetected {
                            let utterance = try await manager.finish()
                            emitUnsent(of: utterance)
                            await manager.reset()
                        }
                        consecutiveErrors = 0
                    } catch {
                        consecutiveErrors += 1
                        ParakeetEngine.logger.error("Processing error (\(consecutiveErrors) in a row): \(error.localizedDescription, privacy: .public)")
                        if consecutiveErrors >= Self.maxConsecutiveProcessingErrors {
                            // The model rejects every chunk (for example an input shape
                            // mismatch): stop so the caller can switch engines and say so.
                            self?.fail("the live model rejected the audio: \(error.localizedDescription)")
                            continuation.finish()
                            return
                        }
                    }
                }

                // Finalize remaining audio when recording stops
                do {
                    emitUnsent(of: try await manager.finish())
                } catch {
                    ParakeetEngine.logger.error("Finish error: \(error)")
                    // Still send the words of the last partial.
                    emitUnsent(of: nil)
                }

                ParakeetEngine.logger.info("Streaming transcription complete")
                continuation.finish()
            }
        }
    }

    // MARK: - Model Management

    static func streamingModelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming/320ms", isDirectory: true)
    }

    /// Files the streaming model needs; a partial download lacks some of them.
    static let streamingModelFiles = [
        "streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json",
    ]

    /// Whether the live (streaming) model is fully on disk.
    static func streamingModelsAvailable(in directory: URL = streamingModelsDirectory()) -> Bool {
        streamingModelFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func downloadStreamingModelsIfNeeded(
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if destination == streamingModelsDirectory() {
            try await ParakeetLiveModelDownloader.shared.ensureDownloaded(progress: progress)
        } else {
            try await ParakeetLiveModelDownloader.download(to: destination, progress: progress)
        }
    }

    // MARK: - Helpers

    private static func makePCMBuffer(from samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}

/// Turns Parakeet EOU partials (the whole utterance so far, re-sent on every decoded
/// chunk) into words that are each sent once and never change.
///
/// The model appends sub-word tokens, so the last word of a partial may still grow
/// ("wor" -> "working"). It stays the volatile guess until a later word starts, and the
/// confirmed word is then taken from the newest partial. (The old code sent the copy it
/// had held back from an earlier partial, so every word that grew after being held was
/// sent cut: "wor", "te", "se", "lyd", "applicat".)
struct ParakeetPartialStitcher: Sendable, Equatable {
    /// Words of the current utterance already sent as final.
    private(set) var sentCount = 0
    /// The newest partial's words.
    private(set) var lastWords: [String] = []

    struct Update: Equatable {
        var confirmed: [String]
        /// The words not confirmed yet (normally the last one), for display.
        var volatile: String
    }

    mutating func update(partial: String) -> Update {
        let words = Self.words(partial)
        lastWords = words
        let confirmedCount = max(0, words.count - 1)
        var confirmed: [String] = []
        if confirmedCount > sentCount {
            confirmed = Array(words[sentCount..<confirmedCount])
            sentCount = confirmedCount
        }
        let volatile = words.count > sentCount ? words[sentCount...].joined(separator: " ") : ""
        return Update(confirmed: confirmed, volatile: volatile)
    }

    /// The utterance's words not sent yet, then starts a new utterance. `utterance` is the
    /// final text (`finish()`), or nil to use the last partial.
    mutating func finish(utterance: String?) -> [String] {
        let words = utterance.map(Self.words) ?? lastWords
        let unsent = words.count > sentCount ? Array(words[sentCount...]) : []
        sentCount = 0
        lastWords = []
        return unsent
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Downloads the Parakeet streaming model once, however many lanes or recordings ask for
/// it at the same time, and reports progress to each of them.
actor ParakeetLiveModelDownloader {
    static let shared = ParakeetLiveModelDownloader()

    private static let logger = Logger(subsystem: "io.lidia.app", category: "ParakeetEngine")

    private var inFlight: Task<Void, Error>?
    private var observers: [UUID: @Sendable (Double) -> Void] = [:]

    func ensureDownloaded(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let destination = ParakeetEngine.streamingModelsDirectory()
        if ParakeetEngine.streamingModelsAvailable(in: destination) { return }
        let id = UUID()
        if let progress { observers[id] = progress }
        defer { observers[id] = nil }
        let task: Task<Void, Error>
        if let inFlight {
            task = inFlight
        } else {
            task = Task {
                try await Self.download(to: destination) { fraction in
                    Task { await self.broadcast(fraction) }
                }
            }
            inFlight = task
        }
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }

    private func broadcast(_ fraction: Double) {
        for observer in observers.values { observer(fraction) }
    }

    static func download(to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        if ParakeetEngine.streamingModelsAvailable(in: destination) { return }
        logger.info("Downloading streaming EOU models...")
        // The repo folder is "parakeet-eou-streaming/320ms" under the FluidAudio directory.
        let fluidAudioDir = destination
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try await DownloadUtils.downloadRepo(.parakeetEou320, to: fluidAudioDir) { update in
            progress?(update.fractionCompleted)
        }
        logger.info("Streaming models downloaded")
    }
}
