import AVFoundation
import CoreMedia
import Foundation
import os
import Speech
import Synchronization

/// Live transcription with Apple's SpeechAnalyzer and SpeechTranscriber (macOS 26).
///
/// Runs on this Mac (the model is a system asset, downloaded once by macOS), punctuates and
/// capitalises, writes numbers as digits, and reports a volatile guess that refines in place
/// before each stretch of speech is finalized. Final words carry audio times.
final class SpeechAnalyzerEngine: LiveSTTEngine, STTFailureReporting {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "SpeechAnalyzerEngine")

    private let locale: Locale
    /// Names and terms the recogniser should prefer (custom vocabulary, attendees).
    private let contextualStrings: [String]
    /// `.fastResults` makes volatile guesses arrive sooner, at some cost in accuracy.
    private let fastResults: Bool
    private let failureReasonMutex = Mutex<String?>(nil)

    var failureReason: String? { failureReasonMutex.withLock { $0 } }

    private func fail(_ reason: String) {
        failureReasonMutex.withLock { $0 = reason }
    }

    init(locale: Locale = .current, contextualStrings: [String] = [], fastResults: Bool = false) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.fastResults = fastResults
    }

    /// Whether SpeechTranscriber runs on this Mac for `locale` (its model may still need
    /// downloading, which `transcribeLive` does).
    static func isAvailable(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    /// Whether the model for `locale` is on this Mac, needs downloading, or doesn't exist.
    static func availability(for locale: Locale) async -> AnalyzerAvailability {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .supported, .downloading: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Has macOS download the on-device model for `locale` (a system asset, shared by apps).
    static func installModel(for locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        try await installAssets(for: SpeechTranscriber(locale: supported, preset: .transcription))
    }

    func preload() async throws {
        try await Self.installModel(for: locale)
    }

    private static func installAssets(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            logger.info("Downloading the on-device speech model")
            try await request.downloadAndInstall()
        }
    }

    func transcribeLive(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<LiveSTTEvent> {
        let locale = locale
        let contextualStrings = contextualStrings
        let fastResults = fastResults
        return AsyncStream { continuation in
            let task = Task {
                guard SpeechTranscriber.isAvailable,
                      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    self.fail("Apple's on-device transcriber doesn't support \(locale.identifier)")
                    for await _ in audioStream {}
                    continuation.finish()
                    return
                }
                var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
                if fastResults { reporting.insert(.fastResults) }
                let transcriber = SpeechTranscriber(
                    locale: supported,
                    transcriptionOptions: [],
                    reportingOptions: reporting,
                    attributeOptions: [.audioTimeRange]
                )
                let analyzer = SpeechAnalyzer(
                    modules: [transcriber],
                    options: .init(priority: .userInitiated, modelRetention: .lingering)
                )
                let format: AVAudioFormat
                do {
                    try await Self.installAssets(for: transcriber)
                    guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        throw SpeechAnalyzerEngineError.noAudioFormat
                    }
                    format = best
                    if !contextualStrings.isEmpty {
                        let context = AnalysisContext()
                        context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
                        try await analyzer.setContext(context)
                    }
                    try await analyzer.prepareToAnalyze(in: format)
                } catch {
                    Self.logger.error("SpeechAnalyzer setup failed: \(error.localizedDescription, privacy: .public)")
                    self.fail("Apple's on-device transcriber couldn't start: \(error.localizedDescription)")
                    for await _ in audioStream {}
                    continuation.finish()
                    return
                }

                let resultsTask = Task {
                    do {
                        for try await result in transcriber.results {
                            let runs = Self.runs(of: result.text)
                            let rangeStart = result.range.start.seconds.isFinite ? result.range.start.seconds : nil
                            let rangeEnd = CMTimeRangeGetEnd(result.range).seconds
                            if result.isFinal {
                                let words = SpeechAnalyzerWords.words(
                                    from: runs,
                                    fallbackStart: rangeStart ?? 0,
                                    fallbackEnd: rangeEnd.isFinite ? rangeEnd : (rangeStart ?? 0)
                                )
                                if !words.isEmpty { continuation.yield(.finalized(words)) }
                                continuation.yield(.volatile(text: "", start: nil))
                            } else {
                                let text = String(result.text.characters)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                continuation.yield(.volatile(text: text, start: rangeStart))
                            }
                        }
                    } catch {
                        Self.logger.error("SpeechAnalyzer results failed: \(error.localizedDescription, privacy: .public)")
                        self.fail("Apple's on-device transcriber stopped: \(error.localizedDescription)")
                    }
                }

                let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                do {
                    try await analyzer.start(inputSequence: inputs)
                } catch {
                    self.fail("Apple's on-device transcriber couldn't start: \(error.localizedDescription)")
                    resultsTask.cancel()
                    for await _ in audioStream {}
                    continuation.finish()
                    return
                }

                let converter = AnalyzerInputConverter(outputFormat: format)
                var fedFrames: Int64 = 0
                for await chunk in audioStream {
                    guard let buffer = converter.buffer(from: chunk) else { continue }
                    let start = CMTime(value: fedFrames, timescale: CMTimeScale(format.sampleRate))
                    inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
                    fedFrames += Int64(buffer.frameLength)
                }
                inputContinuation.finish()
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Self.logger.error("SpeechAnalyzer finish failed: \(error.localizedDescription, privacy: .public)")
                }
                await resultsTask.value
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The text runs of a result with their audio times in seconds.
    private static func runs(of text: AttributedString) -> [SpeechAnalyzerWords.Run] {
        text.runs.map { run in
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                let end = CMTimeRangeGetEnd(range)
                return .init(text: piece, start: range.start.seconds, end: end.seconds)
            }
            return .init(text: piece, start: nil, end: nil)
        }
    }
}

/// "Apple Speech (on-device)": SpeechAnalyzer where macOS supports the language, otherwise
/// the older SFSpeechRecognizer (`AppleSpeechEngine`), which needs the Speech Recognition
/// permission and is never sent to Apple's servers by LidIA unless the user picked it.
final class AppleOnDeviceSpeechEngine: LiveSTTEngine, STTFailureReporting {
    let locale: Locale
    let contextualStrings: [String]
    let fastResults: Bool

    init(locale: Locale, contextualStrings: [String] = [], fastResults: Bool = false) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.fastResults = fastResults
    }

    var failureReason: String? { engineBox.withLock { $0?.failureReason } }

    func preload() async throws {
        if await SpeechAnalyzerEngine.availability(for: locale) != .unsupported {
            try await SpeechAnalyzerEngine.installModel(for: locale)
        }
    }

    func transcribeLive(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<LiveSTTEvent> {
        let locale = locale
        let contextualStrings = contextualStrings
        let fastResults = fastResults
        return AsyncStream { continuation in
            let task = Task {
                let engine: any STTEngine
                if await SpeechAnalyzerEngine.availability(for: locale) != .unsupported {
                    engine = SpeechAnalyzerEngine(locale: locale, contextualStrings: contextualStrings, fastResults: fastResults)
                } else {
                    engine = AppleSpeechEngine(locale: locale)
                }
                let failing = engine as? any STTFailureReporting
                self.engineBox.withLock { $0 = failing }
                for await event in engine.liveEvents(audioStream: audioStream) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The engine picked for the current run, so failures can be reported.
    private let engineBox = Mutex<(any STTFailureReporting)?>(nil)
}

enum SpeechAnalyzerEngineError: LocalizedError {
    case noAudioFormat
    var errorDescription: String? { "no audio format is compatible with the transcriber" }
}

/// Turns SpeechTranscriber's attributed text into words with times.
enum SpeechAnalyzerWords {
    struct Run: Equatable, Sendable {
        var text: String
        var start: Double?
        var end: Double?
    }

    /// Runs are usually one word each, with the space before it ("Hello", ",", " world").
    /// A run that doesn't start with whitespace continues the previous word, so trailing
    /// punctuation stays attached ("Hello,"). Words without a time get one spread over
    /// `fallbackStart...fallbackEnd`.
    static func words(from runs: [Run], fallbackStart: Double, fallbackEnd: Double) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        var timed: [Bool] = []
        for run in runs {
            let startsWord = run.text.first?.isWhitespace ?? false
            let pieces = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !pieces.isEmpty else { continue }
            let start = run.start.flatMap { $0.isFinite ? $0 : nil }
            let end = run.end.flatMap { $0.isFinite ? $0 : nil }
            for (index, piece) in pieces.enumerated() {
                let continues = index == 0 && !startsWord && !words.isEmpty
                if continues {
                    words[words.count - 1].word += piece
                    if let end { words[words.count - 1].end = max(words[words.count - 1].end, end) }
                    if !timed[timed.count - 1], let start {
                        words[words.count - 1].start = start
                        timed[timed.count - 1] = true
                    }
                } else {
                    words.append(TranscriptWord(word: piece, start: start ?? 0, end: end ?? start ?? 0, confidence: 0.9, speaker: nil))
                    timed.append(start != nil)
                }
            }
        }
        // Spread untimed words between their timed neighbours (or the result's range).
        var i = 0
        while i < words.count {
            guard !timed[i] else { i += 1; continue }
            var j = i
            while j < words.count && !timed[j] { j += 1 }
            let lower = i > 0 ? words[i - 1].end : fallbackStart
            let upper = j < words.count ? words[j].start : max(fallbackEnd, lower)
            let step = (upper - lower) / Double(j - i + 1)
            for k in i..<j {
                words[k].start = lower + step * Double(k - i + 1)
                words[k].end = words[k].start
            }
            i = j
        }
        return words
    }
}

/// Converts capture chunks (Float32 mono, any rate) to the analyzer's input format,
/// keeping the resampler's state between chunks so there are no clicks at chunk edges.
final class AnalyzerInputConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputRate: Double = 0

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func buffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard !chunk.samples.isEmpty, chunk.sampleRate > 0,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(chunk.sampleRate), channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        if inputFormat == outputFormat { return input }
        if converter == nil || inputRate != inputFormat.sampleRate {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputRate = inputFormat.sampleRate
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
