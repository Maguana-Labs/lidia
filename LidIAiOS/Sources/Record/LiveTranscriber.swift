@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import Speech
import Synchronization
import os

/// Live, on-device transcription with SpeechAnalyzer (iOS 26).
///
/// SpeechTranscriber where the language is supported (the model is a system
/// asset, downloaded once and shared by apps), DictationTranscriber otherwise.
/// Reports a volatile guess that refines in place, then finalized text with
/// audio times. Nothing leaves the device.
final class LiveTranscriber: @unchecked Sendable {
    struct Segment: Sendable, Hashable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    enum Event: Sendable {
        case volatile(String)
        case finalized(Segment)
        case failed(String)
    }

    enum Availability: Equatable, Sendable {
        case ready
        case needsDownload
        case unsupported
    }

    private static let logger = Logger(subsystem: "io.lidia.ios", category: "LiveTranscriber")

    private let locale: Locale
    private let contextualStrings: [String]
    private let inputs: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let feed = Mutex(Feed())
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    private struct Feed {
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        var frames: Int64 = 0
    }

    init(locale: Locale, contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    static func availability(for locale: Locale) async -> Availability {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            switch await AssetInventory.status(forModules: [module]) {
            case .installed: return .ready
            case .supported, .downloading: return .needsDownload
            default: return .unsupported
            }
        }
        if await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil { return .ready }
        return .unsupported
    }

    /// Prepares the model (downloading it if needed) and starts. Events arrive on `events`.
    func start() async throws -> AsyncStream<Event> {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let module: any SpeechModule
        let resultsTask: Task<Void, Never>

        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            module = transcriber
            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        Self.emit(text: result.text, range: result.range, isFinal: result.isFinal, to: continuation)
                    }
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(
                locale: supported,
                contentHints: [.farField],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            module = transcriber
            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        Self.emit(text: result.text, range: result.range, isFinal: result.isFinal, to: continuation)
                    }
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
        } else {
            throw LiveTranscriberError.unsupported(locale.identifier)
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Self.logger.info("Downloading the on-device speech model")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            resultsTask.cancel()
            throw LiveTranscriberError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        feed.withLock { $0.format = format }
        try await analyzer.start(inputSequence: inputs)
        self.analyzer = analyzer
        self.resultsTask = resultsTask
        return events
    }

    /// Called from the audio thread with 48 kHz mono float buffers.
    func append(_ buffer: AVAudioPCMBuffer) {
        let prepared: (AVAudioConverter, AVAudioFormat, Int64)? = feed.withLock { feed in
            guard let format = feed.format else { return nil }
            if feed.converter == nil || feed.converter?.inputFormat != buffer.format {
                feed.converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter = feed.converter else { return nil }
            return (converter, format, feed.frames)
        }
        guard let (converter, format, frames) = prepared else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        let start = CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))
        feed.withLock { $0.frames += Int64(out.frameLength) }
        inputContinuation.yield(AnalyzerInput(buffer: out, bufferStartTime: start))
    }

    /// Finalizes everything heard so far and waits for the last results.
    func finish() async {
        inputContinuation.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Self.logger.error("Finish failed: \(error.localizedDescription, privacy: .public)")
        }
        await resultsTask?.value
    }

    func cancel() {
        inputContinuation.finish()
        resultsTask?.cancel()
        Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
    }

    private static func emit(text: AttributedString, range: CMTimeRange, isFinal: Bool, to continuation: AsyncStream<Event>.Continuation) {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            continuation.yield(.volatile(""))
            guard !plain.isEmpty else { return }
            let start = range.start.seconds.isFinite ? range.start.seconds : 0
            let end = CMTimeRangeGetEnd(range).seconds
            continuation.yield(.finalized(Segment(text: plain, start: start, end: end.isFinite ? end : start)))
        } else {
            continuation.yield(.volatile(plain))
        }
    }
}

enum LiveTranscriberError: LocalizedError {
    case unsupported(String)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupported(let id): "On-device transcription doesn't support \(id) yet. The audio is still recorded."
        case .noAudioFormat: "The transcriber couldn't use the microphone's audio format."
        }
    }
}
