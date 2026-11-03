import Foundation
import os
import Synchronization

/// An engine that can say why it stopped producing words before its audio ended
/// (model failed to load, every chunk rejected, permission missing).
protocol STTFailureReporting: AnyObject, Sendable {
    var failureReason: String? { get }
}

/// What the live transcription path tells the recording session, so a failing engine is
/// never silent: the UI shows the message and the user gets a notification.
enum LiveTranscriptionEvent: Sendable, Equatable {
    /// The engine the user picked failed; the rest of the recording uses `fallback`.
    case switchedEngine(from: AppSettings.STTEngineType, to: AppSettings.STTEngineType, reason: String)
    /// The engine stopped and there is nothing to fall back to. The recording is still
    /// saved and is transcribed from disk when it stops.
    case unavailable(engine: AppSettings.STTEngineType, reason: String)
    /// The live model is being downloaded; `fraction` is 0...1 when known. `meanwhile` is
    /// the engine transcribing this recording until then (nil: words start once it's in).
    case downloadingModel(engine: AppSettings.STTEngineType, fraction: Double?, meanwhile: AppSettings.STTEngineType?)
    /// The download finished; the next recording uses the model.
    case modelReady(engine: AppSettings.STTEngineType)

    /// User-facing text for the live transcript area and the notification.
    var message: String {
        switch self {
        case let .switchedEngine(from, to, reason):
            return "\(from.shortName) live transcription stopped (\(reason)). Switched to \(to.shortName) for the rest of this meeting."
        case let .unavailable(engine, reason):
            return "Live transcript unavailable: \(engine.shortName) stopped (\(reason)). Audio is still being recorded and will be transcribed when you stop."
        case let .downloadingModel(engine, fraction, meanwhile):
            let percent = fraction.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
            let then = meanwhile.map { "\($0.shortName) transcribes this meeting meanwhile." }
                ?? "Live words start when it finishes."
            return "Downloading the \(engine.shortName) live model\(percent). \(then)"
        case let .modelReady(engine):
            return "\(engine.shortName) live model downloaded. It is used from the next recording."
        }
    }
}

extension AppSettings.STTEngineType {
    /// Name in Settings. `.parakeet` keeps its stored raw value, but is the recommended
    /// on-device setup: Apple's SpeechAnalyzer live, Parakeet as fallback and batch.
    var displayName: String {
        switch self {
        case .parakeet: "On-device (Recommended)"
        case .graniteSpeech: rawValue
        case .whisperKit: rawValue
        case .appleSpeech: "Apple Speech"
        }
    }

    /// Name without the "(Recommended)" style suffix, for messages.
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .graniteSpeech: "Granite Speech"
        case .whisperKit: "WhisperKit"
        case .appleSpeech: "Apple Speech (on-device)"
        }
    }
}

/// Whether Apple's SpeechAnalyzer transcriber can run for a language.
enum AnalyzerAvailability: Equatable, Sendable {
    /// The model is on this Mac.
    case installed
    /// Supported, but macOS still has to download the model.
    case needsDownload
    /// Not on this OS, or not for this language.
    case unsupported
}

/// Which engine runs live, and which one takes over if it fails.
struct LiveEnginePlan: Equatable, Sendable {
    var primary: AppSettings.STTEngineType
    var fallback: AppSettings.STTEngineType?
    /// The requested engine's live model isn't on disk yet and should be downloaded in the
    /// background (this recording uses `primary` meanwhile).
    var downloadModelFor: AppSettings.STTEngineType?

    /// - Parameters:
    ///   - requested: the engine in Settings.
    ///   - parakeetLiveModelPresent: the Parakeet streaming model is on disk.
    ///   - appleOnDeviceAvailable: Apple Speech can recognise the language on this Mac
    ///     without sending audio to Apple, and isn't denied permission.
    ///   - analyzer: Apple's SpeechAnalyzer transcriber (macOS 26) for the language. It is
    ///     always on-device, punctuates, and needs no Speech Recognition permission.
    static func make(
        requested: AppSettings.STTEngineType,
        parakeetLiveModelPresent: Bool,
        appleOnDeviceAvailable: Bool,
        analyzer: AnalyzerAvailability = .unsupported
    ) -> LiveEnginePlan {
        // Apple Speech is only a fallback when it stays on the Mac: the user didn't pick it,
        // so it must not start sending meeting audio to Apple.
        let apple: AppSettings.STTEngineType? = (appleOnDeviceAvailable || analyzer != .unsupported) ? .appleSpeech : nil
        switch requested {
        case .parakeet:
            // The recommended setup: Apple's SpeechAnalyzer live (punctuated, 4.4% WER on
            // the reference recording against 7.8% for the Parakeet live model; see
            // docs/research/2026-11-live-stt.md), Parakeet as the fallback.
            switch analyzer {
            case .installed:
                return LiveEnginePlan(primary: .appleSpeech, fallback: parakeetLiveModelPresent ? .parakeet : nil, downloadModelFor: nil)
            case .needsDownload:
                // Parakeet (if present) runs while macOS downloads the speech model.
                return LiveEnginePlan(
                    primary: parakeetLiveModelPresent ? .parakeet : .appleSpeech,
                    fallback: nil,
                    downloadModelFor: .appleSpeech
                )
            case .unsupported:
                break
            }
            if parakeetLiveModelPresent {
                return LiveEnginePlan(primary: .parakeet, fallback: apple, downloadModelFor: nil)
            }
            if let apple {
                // Don't leave the live transcript empty for minutes while ~250 MB download.
                return LiveEnginePlan(primary: apple, fallback: nil, downloadModelFor: .parakeet)
            }
            // Nothing else runs live here: Parakeet downloads first (with progress shown),
            // then transcribes.
            return LiveEnginePlan(primary: .parakeet, fallback: nil, downloadModelFor: .parakeet)
        case .whisperKit:
            return LiveEnginePlan(primary: .whisperKit, fallback: apple, downloadModelFor: nil)
        case .appleSpeech:
            return LiveEnginePlan(primary: .appleSpeech, fallback: parakeetLiveModelPresent ? .parakeet : nil, downloadModelFor: nil)
        case .graniteSpeech:
            // Batch-only; nothing runs live.
            return LiveEnginePlan(primary: .graniteSpeech, fallback: nil, downloadModelFor: nil)
        }
    }
}

/// Runs a primary engine and, if its word stream ends while audio is still coming (the
/// engine failed), hands the rest of the audio, plus the last few seconds it may have
/// dropped, to a fallback engine. Reports what happened through `onEvent`.
struct FallbackSTTEngine: LiveSTTEngine {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "FallbackSTTEngine")

    let primary: any STTEngine
    let primaryType: AppSettings.STTEngineType
    let fallbackType: AppSettings.STTEngineType?
    let makeFallback: @Sendable () -> (any STTEngine)?
    let onEvent: @Sendable (LiveTranscriptionEvent) -> Void
    /// Audio kept for replay into the fallback, so words spoken while the primary was
    /// failing aren't lost.
    var replaySeconds: TimeInterval = 10

    func preload() async throws {
        try await primary.preload()
    }

    func transcribeLive(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<LiveSTTEvent> {
        let primary = primary
        let primaryType = primaryType
        let fallbackType = fallbackType
        let makeFallback = makeFallback
        let onEvent = onEvent
        let replaySeconds = replaySeconds
        return AsyncStream { output in
            let task = Task {
                let primaryEnded = Mutex(false)
                let (primaryInput, primaryContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
                let primaryEvents = primary.liveEvents(audioStream: primaryInput)
                let primaryTask = Task {
                    for await event in primaryEvents { output.yield(event) }
                    primaryEnded.withLock { $0 = true }
                }

                var replay: [AudioChunk] = []
                var replayDuration: TimeInterval = 0
                /// Seconds of audio fed before `replay[0]`; the fallback's relative word
                /// times are shifted by this so they stay on the lane's timeline.
                var consumedBeforeReplay: TimeInterval = 0
                var fallbackContinuation: AsyncStream<AudioChunk>.Continuation?
                var fallbackTask: Task<Void, Never>?
                var gaveUp = false

                func reasonForStop() -> String {
                    (primary as? STTFailureReporting)?.failureReason ?? "the engine stopped producing words"
                }

                func startFallback() {
                    let reason = reasonForStop()
                    guard let fallbackType, let engine = makeFallback() else {
                        Self.logger.error("Live \(primaryType.rawValue, privacy: .public) stopped (\(reason, privacy: .public)); no fallback")
                        onEvent(.unavailable(engine: primaryType, reason: reason))
                        gaveUp = true
                        return
                    }
                    Self.logger.warning("Live \(primaryType.rawValue, privacy: .public) stopped (\(reason, privacy: .public)); switching to \(fallbackType.rawValue, privacy: .public)")
                    onEvent(.switchedEngine(from: primaryType, to: fallbackType, reason: reason))
                    let (input, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
                    fallbackContinuation = continuation
                    let offset = consumedBeforeReplay
                    let events = engine.liveEvents(audioStream: input)
                    // The failed engine's guess is stale now.
                    output.yield(.volatile(text: "", start: nil))
                    fallbackTask = Task {
                        var producedAny = false
                        for await event in events {
                            switch event {
                            case .finalized(let words):
                                producedAny = producedAny || !words.isEmpty
                                output.yield(.finalized(words.map { Self.shift($0, by: offset) }))
                            case .volatile(let text, let start):
                                output.yield(.volatile(text: text, start: start.map { Self.shiftTime($0, by: offset) }))
                            }
                        }
                        if !producedAny {
                            let fallbackReason = (engine as? STTFailureReporting)?.failureReason
                                ?? "it produced no words"
                            Self.logger.error("Fallback \(fallbackType.rawValue, privacy: .public) produced nothing: \(fallbackReason, privacy: .public)")
                        }
                    }
                    for chunk in replay { continuation.yield(chunk) }
                    replay.removeAll()
                }

                for await chunk in audioStream {
                    if let fallbackContinuation {
                        fallbackContinuation.yield(chunk)
                        continue
                    }
                    if gaveUp { continue }
                    if primaryEnded.withLock({ $0 }) {
                        replay.append(chunk)
                        replayDuration += chunk.duration
                        startFallback()
                        continue
                    }
                    primaryContinuation.yield(chunk)
                    replay.append(chunk)
                    replayDuration += chunk.duration
                    while replayDuration > replaySeconds, replay.count > 1 {
                        let dropped = replay.removeFirst()
                        replayDuration -= dropped.duration
                        consumedBeforeReplay += dropped.duration
                    }
                }

                primaryContinuation.finish()
                fallbackContinuation?.finish()
                await primaryTask.value
                await fallbackTask?.value
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    /// Moves a fallback word's audio-relative time onto the lane's timeline. Untimed words
    /// (0/0) and wall-clock times are left for `LiveWordTiming` to place.
    static func shiftTime(_ time: TimeInterval, by offset: TimeInterval) -> TimeInterval {
        guard offset > 0, time < LiveWordTiming.epochThreshold else { return time }
        return time + offset
    }

    static func shift(_ word: TranscriptWord, by offset: TimeInterval) -> TranscriptWord {
        guard offset > 0, !(word.start == 0 && word.end == 0), word.start < LiveWordTiming.epochThreshold else {
            return word
        }
        var w = word
        w.start += offset
        w.end += offset
        return w
    }
}
