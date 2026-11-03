import AVFoundation
import Foundation
import os
import Speech

/// Speech-to-text for dictation: live partial text while you talk, the final
/// text once the audio stream ends.
protocol DictationRecognizer: Sendable {
    /// Downloads/loads whatever the recogniser needs for `locale` so the first
    /// dictation is quick. Safe to call repeatedly.
    func prepare(locale: Locale) async throws

    /// Transcribes `audio` (16 kHz mono chunks) until the stream finishes.
    /// - Parameters:
    ///   - hints: words to favour (names and acronyms from the user's vocabulary).
    ///   - onPartial: the whole text so far, every time it changes.
    /// - Returns: the final text.
    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        locale: Locale,
        hints: [String],
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

// MARK: - Engine selection hook

/// Which recogniser dictation (and the voice assistant's ears) use.
///
/// After the live-engine evaluation lands, point `liveEngineFactory` at the
/// winner, for example `{ _ in ParakeetStreamingEngine() }`. Dictation then
/// uses it whenever the user picks "Same as live meeting transcripts"; the
/// default ("Apple, on this Mac") keeps using SpeechAnalyzer.
@MainActor
enum DictationEngineRegistry {
    /// Builds the live STT engine. Defaults to the engine chosen for meetings.
    static var liveEngineFactory: @MainActor (AppSettings) -> (any STTEngine)? = { settings in
        TranscriptionService().makeEngine(settings: settings)
    }

    static func makeRecognizer(_ choice: DictationEngineChoice, settings: AppSettings) -> any DictationRecognizer {
        switch choice {
        case .appleOnDevice:
            return AppleDictationRecognizer()
        case .liveEngine:
            if let engine = liveEngineFactory(settings) {
                return STTEngineDictationRecognizer(engine: engine)
            }
            return AppleDictationRecognizer()
        }
    }
}

// MARK: - Apple SpeechAnalyzer

/// Apple's on-device SpeechAnalyzer + SpeechTranscriber (macOS 26). No audio
/// leaves the Mac; the language model is a one-time system download shared
/// with other apps. Partial ("volatile") text streams while you speak.
final class AppleDictationRecognizer: DictationRecognizer {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "AppleDictation")

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// The supported locale closest to `locale`, or nil.
    static func supportedLocale(for locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        guard let supported = await supportedLocale(for: locale) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
    }

    func prepare(locale: Locale) async throws {
        _ = try await makeTranscriber(locale: locale)
    }

    private func makeTranscriber(locale: Locale) async throws -> SpeechTranscriber {
        guard Self.isAvailable else {
            throw DictationError.recognizerFailed("On-device speech recognition isn't available on this Mac.")
        }
        guard let supported = await Self.supportedLocale(for: locale) else {
            throw DictationError.languageUnavailable(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) < .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Self.logger.info("Downloading the on-device speech model for \(supported.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        locale: Locale,
        hints: [String],
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let transcriber = try await makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            let context = AnalysisContext()
            // The analyzer accepts a bounded list; the most specific terms come first.
            context.contextualStrings[.general] = Array(hints.prefix(100))
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.recognizerFailed("No audio format for on-device speech recognition.")
        }
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputs)

        let results = Task { () throws -> String in
            var finalized = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    onPartial(finalized)
                } else {
                    onPartial(finalized + text)
                }
            }
            return finalized
        }

        return try await withTaskCancellationHandler {
            let converter = ChunkConverter(target: format)
            for await chunk in audio {
                if Task.isCancelled { break }
                if let buffer = converter.convert(chunk) {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
            inputContinuation.finish()
            if Task.isCancelled {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                throw CancellationError()
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } onCancel: {
            inputContinuation.finish()
            results.cancel()
        }
    }
}

/// Converts 16 kHz Float chunks to the analyzer's preferred format.
/// Used from one task at a time.
private final class ChunkConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceRate = 0

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard !chunk.samples.isEmpty,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(chunk.sampleRate), channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        if source == target { return input }

        if converter == nil || sourceRate != chunk.sampleRate {
            converter = AVAudioConverter(from: source, to: target)
            sourceRate = chunk.sampleRate
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / source.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

// MARK: - Any STTEngine

/// Runs dictation through any `STTEngine` (Parakeet, WhisperKit, …). Partial
/// text is the words recognised so far.
struct STTEngineDictationRecognizer: DictationRecognizer {
    let engine: any STTEngine

    func prepare(locale: Locale) async throws {
        try await engine.preload()
    }

    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        locale: Locale,
        hints: [String],
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var words: [String] = []
        for await word in engine.transcribe(audioStream: audio) {
            try Task.checkCancellation()
            words.append(word.word)
            onPartial(Self.join(words))
        }
        try Task.checkCancellation()
        return Self.join(words)
    }

    /// Joins words, keeping punctuation tokens attached ("Hello" "," → "Hello,").
    static func join(_ words: [String]) -> String {
        var text = ""
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if text.isEmpty || trimmed.first.map({ ",.;:!?".contains($0) }) == true {
                text += trimmed
            } else {
                text += " " + trimmed
            }
        }
        return text
    }
}

// MARK: - As an STTEngine (voice assistant)

/// SpeechAnalyzer behind the `STTEngine` protocol, so the voice assistant can
/// use the same on-device ears as dictation: no model download, many
/// languages. Yields words as each phrase is finalized.
final class AppleDictationSTTEngine: STTEngine {
    private let locale: Locale
    private let hints: [String]

    init(locale: Locale, hints: [String] = []) {
        self.locale = locale
        self.hints = hints
    }

    func preload() async throws {
        try await AppleDictationRecognizer().prepare(locale: locale)
    }

    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        let locale = locale
        let hints = hints
        return AsyncStream { continuation in
            let task = Task {
                let text = (try? await AppleDictationRecognizer().transcribe(audioStream, locale: locale, hints: hints) { _ in }) ?? ""
                for word in text.split(whereSeparator: \.isWhitespace) {
                    continuation.yield(TranscriptWord(word: String(word), start: 0, end: 0, confidence: 1, speaker: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
