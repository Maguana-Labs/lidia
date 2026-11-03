import AVFoundation
import Foundation
import Testing
@testable import LidIA

/// Speech generated with `say` goes through the real dictation path:
/// 16 kHz chunks at real-time pace → Apple's on-device recogniser (with the
/// user's vocabulary as hints) → cleanup. Skipped when `say` or the on-device
/// English speech model isn't on this Mac (nothing is downloaded by the test).
@Suite("Dictation end to end (say → text)", .serialized)
struct DictationIntegrationTests {
    private static let sayPath = "/usr/bin/say"

    private static func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sayPath)
        process.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try process.run()
        process.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// Feeds `samples` as 100 ms chunks, in real time like the microphone.
    private static func liveStream(_ samples: [Float], realTime: Bool, trailingSilence: Int = 8_000) -> (AsyncStream<AudioChunk>, Task<ContinuousClock.Instant, Never>) {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let feeder = Task { () -> ContinuousClock.Instant in
            let chunk = 1_600
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunk, samples.count)
                continuation.yield(AudioChunk(samples: Array(samples[offset..<end]), sampleRate: 16_000, timestamp: Double(offset) / 16_000, source: .mic))
                offset = end
                if realTime { try? await Task.sleep(for: .milliseconds(100)) }
            }
            // Silence after the last word (0.5 s by default), then the key is released.
            continuation.yield(AudioChunk(samples: Array(repeating: 0, count: trailingSilence), sampleRate: 16_000, timestamp: Double(offset) / 16_000, source: .mic))
            let released = ContinuousClock.now
            continuation.finish()
            return released
        }
        return (stream, feeder)
    }

    private static func onDeviceEnglishReady() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: sayPath), AppleDictationRecognizer.isAvailable else { return false }
        return await AppleDictationRecognizer.isInstalled(Locale(identifier: "en-US"))
    }

    @Test("Spoken dictation with a filler and a self-correction becomes clean text")
    func sayToCleanText() async throws {
        guard await Self.onDeviceEnglishReady() else {
            print("DictationIntegrationTests: on-device English speech model not installed; skipped")
            return
        }
        let samples = try Self.synthesize("Um, so the TAPR review with Acme is on, uh, Tuesday, no wait, Thursday at three.")
        let vocabulary = [AppSettings.VocabularyEntry(heardAs: "taper", replaceTo: "TAPR")]
        let cleaner = DictationTextCleaner(vocabulary: vocabulary, personalTerms: ["Acme"])

        let (audio, feeder) = Self.liveStream(samples, realTime: true)
        let partials = PartialLog()
        let raw = try await AppleDictationRecognizer().transcribe(
            audio, locale: Locale(identifier: "en-US"), hints: cleaner.recognitionHints
        ) { partials.append($0) }
        let finalTextAt = ContinuousClock.now
        let released = await feeder.value
        let text = cleaner.clean(raw)
        let cleanedAt = ContinuousClock.now

        print("DictationIntegrationTests raw: \(raw)")
        print("DictationIntegrationTests clean: \(text)")
        print("DictationIntegrationTests release→final text: \(DictationController.milliseconds(finalTextAt - released)) ms, cleanup: \(DictationController.milliseconds(cleanedAt - finalTextAt)) ms, partial updates: \(partials.count)")

        #expect(partials.count > 3, "partial text streamed while speaking")
        #expect(text.contains("TAPR"))
        #expect(text.contains("Thursday"))
        #expect(!text.contains("Tuesday"), "the self-correction was applied: \(text)")
        #expect(!text.lowercased().hasPrefix("um"))
        #expect(finalTextAt - released < .seconds(2), "final text soon after release")
    }

    @Test("Letting go right on the last word still gets it, quickly")
    func releaseOnLastWord() async throws {
        guard await Self.onDeviceEnglishReady() else { return }
        let samples = try Self.synthesize("Please send the contract to Maria before Friday")
        let (audio, feeder) = Self.liveStream(samples, realTime: true, trailingSilence: 0)
        let raw = try await AppleDictationRecognizer().transcribe(audio, locale: Locale(identifier: "en-US"), hints: []) { _ in }
        let finalTextAt = ContinuousClock.now
        let released = await feeder.value
        let text = DictationTextCleaner().clean(raw)
        print("DictationIntegrationTests no-tail: \(text) — release→final text \(DictationController.milliseconds(finalTextAt - released)) ms")
        #expect(text.lowercased().contains("friday"), "last word kept: \(text)")
        #expect(finalTextAt - released < .seconds(2))
    }

    @Test("A spoken list becomes a numbered list")
    func sayList() async throws {
        guard await Self.onDeviceEnglishReady() else { return }
        let samples = try Self.synthesize("Next steps. First, share the deck. Second, book the follow up.")
        let (audio, _) = Self.liveStream(samples, realTime: false)
        let raw = try await AppleDictationRecognizer().transcribe(audio, locale: Locale(identifier: "en-US"), hints: []) { _ in }
        let text = DictationTextCleaner().clean(raw)
        print("DictationIntegrationTests list: \(raw) → \(text)")
        #expect(text.contains("1. Share the deck"))
        #expect(text.contains("2. Book the follow"))
    }

    @Test("The voice assistant's ears (STTEngine) hear the same audio")
    func assistantEars() async throws {
        guard await Self.onDeviceEnglishReady() else { return }
        let samples = try Self.synthesize("What did we decide about the budget?")
        let (audio, _) = Self.liveStream(samples, realTime: false)
        var words: [String] = []
        for await word in AppleDictationSTTEngine(locale: Locale(identifier: "en-US")).transcribe(audioStream: audio) {
            words.append(word.word)
        }
        let heard = words.joined(separator: " ").lowercased()
        #expect(heard.contains("budget"), "heard: \(heard)")
    }
}

/// Thread-safe counter for partial-text callbacks.
private final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var count: Int { lock.withLock { values.count } }
}
