import AVFoundation
import FluidAudio
import Foundation
import Synchronization
import Testing
@testable import LidIA

// MARK: - Live STT word-error-rate harness
//
// Runs the live engines on a real recording and scores them against a reference transcript
// (for example Granola's, recorded in parallel). Off by default; it needs the models on this
// Mac and takes a few minutes in real-time mode:
//
//   LIDIA_WER_AUDIO=~/path/mic.pcm            # 16 kHz s16le (LidIA's raw track) or any audio file
//   LIDIA_WER_REF=~/path/reference.txt        # plain text of what was said
//   LIDIA_WER_OUT=/tmp/wer                    # optional: writes results.md and transcripts there
//   LIDIA_WER_ENGINES=eou,analyzer,analyzer-fast,tdt-batch   # optional subset
//   LIDIA_WER_REALTIME=1                      # optional: feed audio at real speed (latency numbers)
//   swift test --filter liveSTTHarness
//
// The reference may cover only part of the audio (another app started later): hypothesis
// words before its first and after its last word are not counted (`freeEnds`).
//
// Latency is measured against the batch Parakeet TDT transcript's word end times: each
// engine's words are aligned to it, and a word's latency is when it appeared (first seen
// in the volatile text, or finalized) minus when it was spoken. Real-time mode only.

private let harnessEnv = ProcessInfo.processInfo.environment
private let harnessEnabled = harnessEnv["LIDIA_WER_AUDIO"] != nil && harnessEnv["LIDIA_WER_REF"] != nil

private struct TimedEvent {
    /// Seconds of audio fed when the event arrived.
    var at: Double
    var event: LiveSTTEvent
}

private struct EngineRun {
    var name: String
    var events: [TimedEvent]
    var processingSeconds: Double

    var finalWords: [TranscriptWord] {
        events.flatMap { e -> [TranscriptWord] in
            if case .finalized(let words) = e.event { return words }
            return []
        }
    }

    var finalText: String { finalWords.map(\.word).joined(separator: " ") }

    /// When each final word was first visible: shown in the volatile text at its final
    /// position, or finalized.
    /// Indexed like `finalWords`.
    func firstSeen() -> [Double] {
        var finalizedAt: [Double] = []
        var finalizedKeys: [String] = []
        // Volatile sightings by final-word position: (key, time).
        var candidates: [Int: [(String, Double)]] = [:]
        for e in events {
            switch e.event {
            case .finalized(let words):
                for word in words {
                    finalizedKeys.append(WordErrorRate.normalizedWords(word.word).first ?? "")
                    finalizedAt.append(e.at)
                }
            case .volatile(let text, _):
                for (offset, key) in WordErrorRate.normalizedWords(text).enumerated() {
                    candidates[finalizedKeys.count + offset, default: []].append((key, e.at))
                }
            }
        }
        // A volatile word counts as seen at its position only if it matches the final word.
        return finalizedKeys.indices.map { index in
            let sighting = candidates[index]?.first { $0.0 == finalizedKeys[index] }?.1
            return min(sighting ?? .infinity, finalizedAt[index])
        }
    }
}

private func loadSamples(_ path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    if url.pathExtension == "pcm" {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            return ints.map { Float($0) / 32_768 }
        }
    }
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let source = file.processingFormat
    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    if source.sampleRate == 16_000 && source.channelCount == 1 {
        return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
    }
    let converter = AVAudioConverter(from: source, to: target)!
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / source.sampleRate) + 1024)!
    var supplied = false
    _ = converter.convert(to: output, error: nil) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

/// 100 ms mic chunks with wall-clock timestamps, like the capture stream.
private func chunks(_ samples: [Float], start: Double) -> [AudioChunk] {
    stride(from: 0, to: samples.count, by: 1_600).map { offset in
        let end = min(samples.count, offset + 1_600)
        return AudioChunk(samples: Array(samples[offset..<end]), sampleRate: 16_000,
                          timestamp: start + Double(end) / 16_000, source: .mic)
    }
}

/// Feeds chunks (at real speed when `realtime`) and records each event with the audio
/// position at which it arrived.
private func runLive(name: String, engine: any STTEngine, samples: [Float], realtime: Bool) async -> EngineRun {
    let fed = Mutex(0.0)
    let clockStart = Date()
    let input = chunks(samples, start: clockStart.timeIntervalSince1970)
    let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    let feeder = Task {
        for chunk in input {
            if realtime {
                let due = chunk.timestamp - clockStart.timeIntervalSince1970
                let wait = due - Date().timeIntervalSince(clockStart)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            fed.withLock { $0 += chunk.duration }
            continuation.yield(chunk)
        }
        continuation.finish()
    }
    var events: [TimedEvent] = []
    for await event in engine.liveEvents(audioStream: stream) {
        let at = realtime ? Date().timeIntervalSince(clockStart) : fed.withLock { $0 }
        events.append(TimedEvent(at: at, event: event))
    }
    await feeder.value
    return EngineRun(name: name, events: events, processingSeconds: Date().timeIntervalSince(clockStart))
}

/// The previous Parakeet live stitching, kept here only to measure what it cost: it sent
/// the copy of the last word it had held back from an earlier partial.
private struct LegacyParakeetStitcher {
    var emitted = 0
    var held: String?

    mutating func partial(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var out: [String] = []
        let confirmed = words.count - 1
        if confirmed > emitted {
            if let held { out.append(held) }
            let startIndex = held != nil ? emitted + 1 : emitted
            if startIndex < confirmed { out += words[startIndex..<confirmed] }
            emitted = confirmed
        }
        held = words.last
        return out
    }

    mutating func finish(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        let out = emitted < words.count ? Array(words[emitted...]) : []
        emitted = 0
        held = nil
        return out
    }
}

/// Drives the Parakeet EOU streaming model exactly like `ParakeetEngine`, recording the raw
/// partials, then replays them through the old and the new stitching.
private func runParakeetEOU(samples: [Float], realtime: Bool) async throws -> (legacy: EngineRun, fixed: EngineRun) {
    enum Raw { case partial(String), finish(String) }
    let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 800)
    try await manager.loadModels(from: ParakeetEngine.streamingModelsDirectory())
    let clockStart = Date()
    let fed = Mutex(0.0)
    let trace = Mutex<[(Double, Raw)]>([])
    func now() -> Double { realtime ? Date().timeIntervalSince(clockStart) : fed.withLock { $0 } }
    await manager.setPartialCallback { partial in
        let at = realtime ? Date().timeIntervalSince(clockStart) : fed.withLock { $0 }
        trace.withLock { $0.append((at, .partial(partial))) }
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    for chunk in chunks(samples, start: clockStart.timeIntervalSince1970) {
        if realtime {
            let wait = (chunk.timestamp - clockStart.timeIntervalSince1970) - Date().timeIntervalSince(clockStart)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        fed.withLock { $0 += chunk.duration }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count))!
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        _ = try await manager.process(audioBuffer: buffer)
        if await manager.eouDetected {
            let text = try await manager.finish()
            trace.withLock { $0.append((now(), .finish(text))) }
            await manager.reset()
        }
    }
    let last = try await manager.finish()
    trace.withLock { $0.append((now(), .finish(last))) }
    let elapsed = Date().timeIntervalSince(clockStart)

    var legacy = LegacyParakeetStitcher()
    var fixed = ParakeetPartialStitcher()
    var legacyEvents: [TimedEvent] = []
    var fixedEvents: [TimedEvent] = []
    func words(_ list: [String]) -> [TranscriptWord] {
        list.map { TranscriptWord(word: $0, start: 0, end: 0, confidence: 0.9, speaker: nil) }
    }
    for (at, raw) in trace.withLock({ $0 }) {
        switch raw {
        case .partial(let text):
            let old = legacy.partial(text)
            if !old.isEmpty { legacyEvents.append(TimedEvent(at: at, event: .finalized(words(old)))) }
            let update = fixed.update(partial: text)
            if !update.confirmed.isEmpty { fixedEvents.append(TimedEvent(at: at, event: .finalized(words(update.confirmed)))) }
            fixedEvents.append(TimedEvent(at: at, event: .volatile(text: update.volatile, start: nil)))
        case .finish(let text):
            let old = legacy.finish(text)
            if !old.isEmpty { legacyEvents.append(TimedEvent(at: at, event: .finalized(words(old)))) }
            let rest = fixed.finish(utterance: text)
            if !rest.isEmpty { fixedEvents.append(TimedEvent(at: at, event: .finalized(words(rest)))) }
            fixedEvents.append(TimedEvent(at: at, event: .volatile(text: "", start: nil)))
        }
    }
    return (
        EngineRun(name: "Parakeet EOU 120M live (old stitching)", events: legacyEvents, processingSeconds: elapsed),
        EngineRun(name: "Parakeet EOU 120M live (fixed stitching)", events: fixedEvents, processingSeconds: elapsed)
    )
}

private func percentile(_ values: [Double], _ p: Double) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
}

private func fmt(_ value: Double?, _ digits: Int = 1) -> String {
    guard let value, value.isFinite else { return "–" }
    return String(format: "%.\(digits)f", value)
}

@Test(.enabled(if: harnessEnabled), .timeLimit(.minutes(30)))
func liveSTTHarnessScoresEnginesOnARealRecording() async throws {
    let samples = try loadSamples(harnessEnv["LIDIA_WER_AUDIO"]!)
    let reference = try String(contentsOfFile: (harnessEnv["LIDIA_WER_REF"]! as NSString).expandingTildeInPath, encoding: .utf8)
    let referenceWords = WordErrorRate.normalizedWords(reference)
    let realtime = harnessEnv["LIDIA_WER_REALTIME"] == "1"
    let selected = Set((harnessEnv["LIDIA_WER_ENGINES"] ?? "eou,analyzer,analyzer-fast,tdt-batch")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    let audioSeconds = Double(samples.count) / 16_000
    print("HARNESS audio \(fmt(audioSeconds))s, reference \(referenceWords.count) words, realtime=\(realtime)")

    // The batch transcript is the clock for latency (word end times) and a contender itself.
    let batchStart = Date()
    let batchWords = try await ParakeetBatchProcessor().transcribeOnly(samples: samples)
    let batchRun = EngineRun(
        name: "Parakeet TDT 0.6B v3 batch (after the meeting)",
        events: [TimedEvent(at: audioSeconds, event: .finalized(batchWords))],
        processingSeconds: Date().timeIntervalSince(batchStart)
    )
    let batchKeys = batchWords.map { WordErrorRate.normalizedWords($0.word).first ?? "" }

    var runs: [EngineRun] = []
    if selected.contains("tdt-batch") { runs.append(batchRun) }
    if selected.contains("eou") {
        try #require(ParakeetEngine.streamingModelsAvailable(), "Parakeet live model not on this Mac")
        let (legacy, fixed) = try await runParakeetEOU(samples: samples, realtime: realtime)
        runs += [legacy, fixed]
    }
    if selected.contains("analyzer") {
        runs.append(await runLive(name: "Apple SpeechAnalyzer live", engine: SpeechAnalyzerEngine(locale: Locale(identifier: "en-US")), samples: samples, realtime: realtime))
    }
    if selected.contains("analyzer-fast") {
        runs.append(await runLive(name: "Apple SpeechAnalyzer live (fastResults)", engine: SpeechAnalyzerEngine(locale: Locale(identifier: "en-US"), fastResults: true), samples: samples, realtime: realtime))
    }

    var table = """
    | Engine | WER | Sub | Del | Ins | Cut words | . ? ! /100w | , /100w | Capitalised | Digits | Final latency p50 / p90 | First seen p50 / p90 | Processing |
    |---|---|---|---|---|---|---|---|---|---|---|---|---|

    """
    var transcripts = ""
    for run in runs {
        let hypothesis = run.finalWords.flatMap { WordErrorRate.normalizedWords($0.word) }
        let score = WordErrorRate.compute(reference: referenceWords, hypothesis: hypothesis, freeEnds: true)
        let cut = WordErrorRate.truncatedWords(reference: referenceWords, hypothesis: hypothesis, alignment: score)
        let format = WordErrorRate.Formatting.measure(run.finalText)

        var finalLatency: [Double] = []
        var seenLatency: [Double] = []
        if realtime && !run.name.contains("batch") {
            let finalKeys = run.finalWords.map { WordErrorRate.normalizedWords($0.word).first ?? "" }
            let toBatch = WordErrorRate.compute(reference: batchKeys, hypothesis: finalKeys)
            var finalizedAt: [Double] = []
            for e in run.events {
                if case .finalized(let words) = e.event { finalizedAt += Array(repeating: e.at, count: words.count) }
            }
            let seen = run.firstSeen()
            for (j, i) in toBatch.hypothesisToReference.enumerated() {
                guard let i, finalKeys[j] == batchKeys[i] else { continue }
                let spoken = batchWords[i].end
                if j < finalizedAt.count { finalLatency.append(finalizedAt[j] - spoken) }
                if j < seen.count { seenLatency.append(seen[j] - spoken) }
            }
        }
        let row = "| \(run.name) | \(fmt(score.wer * 100))% | \(score.substitutions) | \(score.deletions) | \(score.insertions) | \(cut.count) | \(fmt(format.sentenceMarksPer100Words)) | \(fmt(format.commasPer100Words)) | \(fmt(format.capitalizedSentenceShare * 100, 0))% | \(format.usesDigits ? "yes" : "no") | \(fmt(percentile(finalLatency, 0.5))) / \(fmt(percentile(finalLatency, 0.9))) s | \(fmt(percentile(seenLatency, 0.5))) / \(fmt(percentile(seenLatency, 0.9))) s | \(fmt(run.processingSeconds)) s |"
        table += row + "\n"
        transcripts += "### \(run.name)\n\n\(run.finalText)\n\n"
        if !cut.isEmpty { transcripts += "Cut words: \(cut.joined(separator: ", "))\n\n" }
        print("HARNESS \(row)")
        print("HARNESS TEXT \(run.name): \(run.finalText)")
    }

    if let out = harnessEnv["LIDIA_WER_OUT"] {
        let dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = "Audio: \(fmt(audioSeconds)) s, reference: \(referenceWords.count) words, realtime feed: \(realtime)\n\n"
        try (header + table + "\n" + transcripts).write(to: dir.appendingPathComponent(realtime ? "results-realtime.md" : "results.md"), atomically: true, encoding: .utf8)
    }
    #expect(!runs.isEmpty)
}
