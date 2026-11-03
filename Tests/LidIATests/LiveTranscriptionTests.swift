import AVFoundation
import CoreAudioTypes
import Foundation
import Speech
import Synchronization
import Testing
@testable import LidIA

// MARK: - Test engines

/// Emits one word per chunk ("w0", "w1", ...) timed relative to the audio it was fed.
private final class ChunkWordEngine: STTEngine, @unchecked Sendable {
    let prefix: String
    private let seen = Mutex<[TimeInterval]>([])
    var chunkTimestamps: [TimeInterval] { seen.withLock { $0 } }

    init(prefix: String = "w") { self.prefix = prefix }

    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        AsyncStream { continuation in
            Task {
                var fed: TimeInterval = 0
                var index = 0
                for await chunk in audioStream {
                    self.seen.withLock { $0.append(chunk.timestamp) }
                    continuation.yield(TranscriptWord(
                        word: "\(self.prefix)\(index)", start: fed, end: fed + chunk.duration,
                        confidence: 1, speaker: nil
                    ))
                    fed += chunk.duration
                    index += 1
                }
                continuation.finish()
            }
        }
    }
}

/// Reads `failAfter` chunks, then stops early like an engine whose model rejects audio.
private final class FailingEngine: STTEngine, STTFailureReporting, @unchecked Sendable {
    let failAfter: Int
    private let reason = Mutex<String?>(nil)
    var failureReason: String? { reason.withLock { $0 } }

    init(failAfter: Int) { self.failAfter = failAfter }

    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        AsyncStream { continuation in
            Task {
                var count = 0
                for await _ in audioStream {
                    count += 1
                    if count >= self.failAfter {
                        self.reason.withLock { $0 = "the live model rejected the audio" }
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
        }
    }
}

private func chunks(count: Int, seconds: TimeInterval = 0.5, rate: Int = 16_000) -> [AudioChunk] {
    let frames = Int(seconds * Double(rate))
    return (0..<count).map { i in
        AudioChunk(samples: [Float](repeating: 0.1, count: frames), sampleRate: rate, timestamp: Double(i) * seconds, source: .mic)
    }
}

/// Feeds chunks with a short pause between them, as live capture does, so the wrapper
/// notices a primary that stopped before the input ends.
private func paced(_ input: [AudioChunk]) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
        Task {
            for chunk in input {
                continuation.yield(chunk)
                try? await Task.sleep(for: .milliseconds(20))
            }
            continuation.finish()
        }
    }
}

private final class EventLog: Sendable {
    private let events = Mutex<[LiveTranscriptionEvent]>([])
    var all: [LiveTranscriptionEvent] { events.withLock { $0 } }
    func record(_ event: LiveTranscriptionEvent) { events.withLock { $0.append(event) } }
}

// MARK: - Engine plan

@Test func livePlanUsesParakeetWithAppleFallbackWhenModelPresent() {
    let plan = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: true, appleOnDeviceAvailable: true)
    #expect(plan == LiveEnginePlan(primary: .parakeet, fallback: .appleSpeech, downloadModelFor: nil))
}

@Test func livePlanStartsWithAppleWhileParakeetDownloads() {
    let plan = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: false, appleOnDeviceAvailable: true)
    #expect(plan == LiveEnginePlan(primary: .appleSpeech, fallback: nil, downloadModelFor: .parakeet))
}

@Test func livePlanDownloadsParakeetWithProgressWhenNothingElseRuns() {
    let plan = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: false, appleOnDeviceAvailable: false)
    #expect(plan == LiveEnginePlan(primary: .parakeet, fallback: nil, downloadModelFor: .parakeet))
}

@Test func livePlanNeverFallsBackToServerAppleSpeech() {
    let parakeet = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: true, appleOnDeviceAvailable: false)
    #expect(parakeet.fallback == nil)
    let whisper = LiveEnginePlan.make(requested: .whisperKit, parakeetLiveModelPresent: true, appleOnDeviceAvailable: false)
    #expect(whisper == LiveEnginePlan(primary: .whisperKit, fallback: nil, downloadModelFor: nil))
}

@Test func livePlanForAppleSpeechFallsBackToParakeetOnlyWhenPresent() {
    #expect(LiveEnginePlan.make(requested: .appleSpeech, parakeetLiveModelPresent: true, appleOnDeviceAvailable: true).fallback == .parakeet)
    #expect(LiveEnginePlan.make(requested: .appleSpeech, parakeetLiveModelPresent: false, appleOnDeviceAvailable: true).fallback == nil)
}

@Test func livePlanLeavesBatchOnlyGraniteAlone() {
    let plan = LiveEnginePlan.make(requested: .graniteSpeech, parakeetLiveModelPresent: true, appleOnDeviceAvailable: true)
    #expect(plan == LiveEnginePlan(primary: .graniteSpeech, fallback: nil, downloadModelFor: nil))
}

@Test func appleFallbackNeedsOnDeviceAndPermission() {
    #expect(AppleSpeechEngine.isUsableFallback(authorization: .authorized, supportsOnDevice: true))
    #expect(AppleSpeechEngine.isUsableFallback(authorization: .notDetermined, supportsOnDevice: true))
    #expect(!AppleSpeechEngine.isUsableFallback(authorization: .denied, supportsOnDevice: true))
    #expect(!AppleSpeechEngine.isUsableFallback(authorization: .restricted, supportsOnDevice: true))
    #expect(!AppleSpeechEngine.isUsableFallback(authorization: .authorized, supportsOnDevice: false))
}

@Test func liveEventMessagesNameTheEnginesAndTheReason() {
    let switched = LiveTranscriptionEvent.switchedEngine(from: .parakeet, to: .appleSpeech, reason: "model rejected audio")
    #expect(switched.message.contains("Parakeet"))
    #expect(switched.message.contains("Apple Speech"))
    #expect(switched.message.contains("model rejected audio"))
    let unavailable = LiveTranscriptionEvent.unavailable(engine: .parakeet, reason: "no model")
    #expect(unavailable.message.contains("will be transcribed when you stop"))
    let downloading = LiveTranscriptionEvent.downloadingModel(engine: .parakeet, fraction: 0.42, meanwhile: .appleSpeech)
    #expect(downloading.message.contains("42%"))
    #expect(downloading.message.contains("Apple Speech"))
    let waiting = LiveTranscriptionEvent.downloadingModel(engine: .parakeet, fraction: nil, meanwhile: nil)
    #expect(waiting.message.contains("Live words start when it finishes"))
}

// MARK: - Fallback engine

@Test func fallbackEngineSwitchesWhenPrimaryStopsAndReplaysRecentAudio() async {
    let events = EventLog()
    let fallback = ChunkWordEngine(prefix: "f")
    let engine = FallbackSTTEngine(
        primary: FailingEngine(failAfter: 3),
        primaryType: .parakeet,
        fallbackType: .appleSpeech,
        makeFallback: { fallback },
        onEvent: { events.record($0) },
        replaySeconds: 10
    )
    var words: [TranscriptWord] = []
    for await word in engine.transcribe(audioStream: paced(chunks(count: 10))) {
        words.append(word)
    }

    #expect(events.all == [.switchedEngine(from: .parakeet, to: .appleSpeech, reason: "the live model rejected the audio")])
    // Nothing was dropped: the fallback heard every chunk (replayed + the rest).
    #expect(fallback.chunkTimestamps == chunks(count: 10).map(\.timestamp))
    #expect(words.map(\.word) == (0..<10).map { "f\($0)" })
}

@Test func fallbackWordTimesStayOnTheLaneTimelineAfterReplayTrimming() async {
    let fallback = ChunkWordEngine(prefix: "f")
    let engine = FallbackSTTEngine(
        primary: FailingEngine(failAfter: 8),
        primaryType: .parakeet,
        fallbackType: .appleSpeech,
        makeFallback: { fallback },
        onEvent: { _ in },
        replaySeconds: 1 // keep ~2 chunks of 0.5 s
    )
    var words: [TranscriptWord] = []
    for await word in engine.transcribe(audioStream: paced(chunks(count: 12))) {
        words.append(word)
    }
    let firstReplayed = try? #require(fallback.chunkTimestamps.first)
    let first = try? #require(words.first)
    // The fallback's first word starts where its first (replayed) chunk sits in the lane.
    #expect(abs((first?.start ?? -1) - (firstReplayed ?? -2)) < 0.001)
    #expect((firstReplayed ?? 0) > 0)
}

@Test func fallbackEngineReportsUnavailableWithoutAFallback() async {
    let events = EventLog()
    let engine = FallbackSTTEngine(
        primary: FailingEngine(failAfter: 2),
        primaryType: .parakeet,
        fallbackType: nil,
        makeFallback: { nil },
        onEvent: { events.record($0) }
    )
    var count = 0
    for await _ in engine.transcribe(audioStream: paced(chunks(count: 6))) { count += 1 }
    #expect(count == 0)
    #expect(events.all == [.unavailable(engine: .parakeet, reason: "the live model rejected the audio")])
}

@Test func fallbackEngineStaysQuietWhenPrimaryWorks() async {
    let events = EventLog()
    let engine = FallbackSTTEngine(
        primary: ChunkWordEngine(),
        primaryType: .parakeet,
        fallbackType: .appleSpeech,
        makeFallback: { Issue.record("fallback should not start"); return nil },
        onEvent: { events.record($0) }
    )
    var words: [String] = []
    for await word in engine.transcribe(audioStream: paced(chunks(count: 5))) { words.append(word.word) }
    #expect(words == ["w0", "w1", "w2", "w3", "w4"])
    #expect(events.all.isEmpty)
}

@Test func fallbackShiftLeavesUntimedAndWallClockWordsAlone() {
    let untimed = TranscriptWord(word: "a", start: 0, end: 0, confidence: 1, speaker: nil)
    #expect(FallbackSTTEngine.shift(untimed, by: 5).start == 0)
    let wall = TranscriptWord(word: "b", start: 1_800_000_000, end: 1_800_000_001, confidence: 1, speaker: nil)
    #expect(FallbackSTTEngine.shift(wall, by: 5).start == 1_800_000_000)
    let relative = TranscriptWord(word: "c", start: 1, end: 1.5, confidence: 1, speaker: nil)
    #expect(FallbackSTTEngine.shift(relative, by: 5).start == 6)
    #expect(FallbackSTTEngine.shift(relative, by: 5).end == 6.5)
}

// MARK: - Parakeet utterance flush

@Test func parakeetStitcherSendsTheGrownWordNotTheHeldCopy() {
    // The bug behind "wor on", "te you", "se eight": a partial grows the held word and adds
    // the next one in the same callback.
    var stitcher = ParakeetPartialStitcher()
    var sent: [String] = []
    for partial in ["this actually", "this actually wor", "this actually working on", "this actually working on it"] {
        sent += stitcher.update(partial: partial).confirmed
    }
    #expect(sent == ["this", "actually", "working", "on"])
    sent += stitcher.finish(utterance: "this actually working on it")
    #expect(sent == ["this", "actually", "working", "on", "it"])
}

@Test func parakeetStitcherReportsTheUnconfirmedTailAsVolatile() {
    var stitcher = ParakeetPartialStitcher()
    #expect(stitcher.update(partial: "six se") == .init(confirmed: ["six"], volatile: "se"))
    #expect(stitcher.update(partial: "six seven") == .init(confirmed: [], volatile: "seven"))
    #expect(stitcher.update(partial: "six seven eight") == .init(confirmed: ["seven"], volatile: "eight"))
}

@Test func parakeetStitcherFinishSendsEachWordOnceAndResets() {
    var stitcher = ParakeetPartialStitcher()
    _ = stitcher.update(partial: "we will review")
    #expect(stitcher.finish(utterance: "we will review the budget") == ["review", "the", "budget"])
    // Next utterance starts clean.
    #expect(stitcher.update(partial: "next steps").confirmed == ["next"])
    // No final text (finish failed): the last partial's unsent words.
    #expect(stitcher.finish(utterance: nil) == ["steps"])
    #expect(stitcher.finish(utterance: "") == [])
}

// MARK: - System audio formats

private func asbd(float: Bool, bits: UInt32, channels: UInt32 = 1, rate: Double = 48_000) -> AudioStreamBasicDescription {
    var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
    flags |= float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
    return AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
    )
}

@Test func pcmDecoderReadsFloat32() {
    let values: [Float] = [0, 0.5, -0.25]
    let out = values.withUnsafeBytes {
        PCMSampleDecoder.decode($0.baseAddress!, byteCount: $0.count, format: asbd(float: true, bits: 32), channelsInBuffer: 1)
    }
    #expect(out == values)
}

@Test func pcmDecoderConvertsInt16InsteadOfDroppingIt() {
    let values: [Int16] = [0, 16_384, -32_768]
    let out = values.withUnsafeBytes {
        PCMSampleDecoder.decode($0.baseAddress!, byteCount: $0.count, format: asbd(float: false, bits: 16), channelsInBuffer: 1)
    }
    #expect(out == [0, 0.5, -1])
}

@Test func pcmDecoderMixesInterleavedStereoToMono() {
    let values: [Float] = [1, 0, 0.5, 0.5]
    let out = values.withUnsafeBytes {
        PCMSampleDecoder.decode($0.baseAddress!, byteCount: $0.count, format: asbd(float: true, bits: 32, channels: 2), channelsInBuffer: 2)
    }
    #expect(out == [0.5, 0.5])
}

@Test func pcmDecoderRejectsUnreadableFormats() {
    let values: [UInt8] = [1, 2, 3, 4]
    var format = asbd(float: false, bits: 8)
    let out8 = values.withUnsafeBytes {
        PCMSampleDecoder.decode($0.baseAddress!, byteCount: $0.count, format: format, channelsInBuffer: 1)
    }
    #expect(out8 == nil)
    format = asbd(float: true, bits: 32)
    format.mFormatID = kAudioFormatMPEG4AAC
    let aac = values.withUnsafeBytes {
        PCMSampleDecoder.decode($0.baseAddress!, byteCount: $0.count, format: format, channelsInBuffer: 1)
    }
    #expect(aac == nil)
}

@Test func pcmDecoderReplacesNaNWithSilence() {
    let values: [Float] = [.nan, 0.25]
    let out = values.withUnsafeBytes {
        PCMSampleDecoder.decode($0.baseAddress!, byteCount: $0.count, format: asbd(float: true, bits: 32), channelsInBuffer: 1)
    }
    #expect(out == [0, 0.25])
}

// MARK: - Live harness (real models, real speech)

/// Feeds synthesized speech through the same live path the app uses while recording
/// (`TranscriptionService.liveTranscription`, one lane, 48 kHz mic-sized chunks) and
/// checks words come out. Needs the models on this Mac, so it's off by default:
/// `LIDIA_LIVE_STT=1 swift test --filter liveSTT`.
///
/// Apple Speech can't be exercised here: the test runner has no Speech Recognition usage
/// description, so TCC aborts the process. Check that fallback from an app bundle.
private let liveSTTEnabled = ProcessInfo.processInfo.environment["LIDIA_LIVE_STT"] == "1"

private let harnessSentence = "Good morning everyone. Today we will review the budget for the marketing project and agree on the next steps."

/// `say` → AIFF → 16 kHz mono WAV, read back as Float samples.
private func synthesizedSpeech() throws -> [Float] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-live-stt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let aiff = dir.appendingPathComponent("speech.aiff")
    let wav = dir.appendingPathComponent("speech.wav")
    for (tool, args) in [
        ("/usr/bin/say", ["-o", aiff.path, harnessSentence]),
        ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path]),
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) failed")
    }
    let file = try AVAudioFile(forReading: wav)
    let format = file.processingFormat
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// Mic-tap-shaped chunks: 48 kHz, 4096 frames, wall-clock timestamps, plus trailing
/// silence so end-of-utterance logic runs.
private func micChunks(from samples16k: [Float]) -> [AudioChunk] {
    let audio = AudioResampler.resample(samples16k + [Float](repeating: 0, count: 16_000 * 2), from: 16_000, to: 48_000)
    let start = Date().timeIntervalSince1970
    var result: [AudioChunk] = []
    var offset = 0
    while offset < audio.count {
        let end = min(audio.count, offset + 4096)
        result.append(AudioChunk(
            samples: Array(audio[offset..<end]), sampleRate: 48_000,
            timestamp: start + Double(end) / 48_000, source: .mic
        ))
        offset = end
    }
    return result
}

private func normalized(_ words: [TranscriptWord]) -> Set<String> {
    Set(words.map { SpeakerStreamMerger.normalizedKey($0.word) })
}

@MainActor
@Test(.enabled(if: liveSTTEnabled), .timeLimit(.minutes(5)))
func liveSTTParakeetProducesWordsThroughTheAppLivePath() async throws {
    try #require(ParakeetEngine.streamingModelsAvailable(), "Parakeet live model not downloaded on this Mac")
    let chunks = micChunks(from: try synthesizedSpeech())
    let input = AsyncStream<AudioChunk> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
    let events = EventLog()
    let factory = STTEngineFactory(engineType: .parakeet, language: "en-US", whisperKitModel: "")
    // No fallback: the words must come from Parakeet itself.
    let plan = LiveEnginePlan(primary: .parakeet, fallback: nil, downloadModelFor: nil)
    let start = chunks[0].timestamp
    let stream = TranscriptionService().liveTranscription(
        of: input, factory: factory, plan: plan, separateSources: false,
        timeline: { max(0, $0 - start) }, onEvent: { events.record($0) }
    )
    var words: [TranscriptWord] = []
    for await word in stream { words.append(word) }
    print("LIVE parakeet words:", words.map(\.word).joined(separator: " "))
    #expect(events.all.isEmpty, "engine reported: \(events.all.map(\.message))")
    let heard = normalized(words)
    #expect(words.count >= 10)
    #expect(heard.contains("budget"))
    #expect(heard.contains("marketing"))
    // The utterance's last word is sent once, not again when the stream ends.
    let keys = words.map { SpeakerStreamMerger.normalizedKey($0.word) }
    #expect(keys.suffix(2) != ["steps", "steps"])
}
