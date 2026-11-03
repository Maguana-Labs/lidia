import Foundation
import SwiftData
import Testing
@testable import LidIA

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lidia-capture-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval? = nil) -> TranscriptWord {
    TranscriptWord(word: text, start: start, end: end ?? start + 0.3, confidence: 1, speaker: nil)
}

/// Emits one word per chunk it receives, timed relative to the audio it was fed, and
/// reports which sources it saw. Lets tests check routing without a real model.
private final class ChunkEchoEngine: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _sources: [AudioSource] = []
    var sources: [AudioSource] {
        lock.lock(); defer { lock.unlock() }
        return _sources
    }

    private func record(_ source: AudioSource) {
        lock.withLock { _sources.append(source) }
    }

    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        AsyncStream { continuation in
            Task {
                var fed: TimeInterval = 0
                for await chunk in audioStream {
                    self.record(chunk.source)
                    continuation.yield(TranscriptWord(
                        word: chunk.source.rawValue,
                        start: fed,
                        end: fed + chunk.duration,
                        confidence: 1,
                        speaker: nil
                    ))
                    fed += chunk.duration
                }
                continuation.finish()
            }
        }
    }
}

private final class EngineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var engines: [ChunkEchoEngine] = []
    func make() -> any STTEngine {
        let engine = ChunkEchoEngine()
        lock.lock(); engines.append(engine); lock.unlock()
        return engine
    }
}

private func chunk(_ source: AudioSource, at timestamp: TimeInterval, seconds: Double = 0.5, rate: Int = 16_000) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0.1, count: Int(Double(rate) * seconds)), sampleRate: rate, timestamp: timestamp, source: source)
}

// MARK: - Live stream separation

@Suite("SourceSeparatedTranscriber")
struct SourceSeparatedTranscriberTests {
    @Test func routesEachSourceToItsOwnEngineAndLabelsWords() async {
        let registry = EngineRegistry()
        let start: TimeInterval = 10_000
        let transcriber = SourceSeparatedTranscriber(
            makeEngine: { registry.make() },
            separateSources: true,
            timeline: { $0 - start }
        )
        let input = AsyncStream<AudioChunk> { c in
            c.yield(chunk(.mic, at: start + 0.5))
            c.yield(chunk(.system, at: start + 1.5))  // system starts 1 s in
            c.yield(chunk(.mic, at: start + 1.0))
            c.yield(chunk(.system, at: start + 2.0))
            c.finish()
        }

        var words: [TranscriptWord] = []
        for await w in transcriber.transcribe(input) { words.append(w) }

        #expect(registry.engines.count == 2)
        for engine in registry.engines {
            #expect(Set(engine.sources).count == 1, "an engine received mixed sources")
        }
        let mic = words.filter { $0.word == "mic" }
        let system = words.filter { $0.word == "system" }
        #expect(mic.count == 2 && system.count == 2)
        #expect(mic.allSatisfy { $0.isLocalSpeaker == true })
        #expect(system.allSatisfy { $0.isLocalSpeaker == false })
        // System lane timings are offset by where that lane started on the timeline.
        #expect(abs((system.map(\.start).min() ?? -1) - 1.0) < 0.001)
        #expect(abs((mic.map(\.start).min() ?? -1) - 0.0) < 0.001)
    }

    /// System audio off (or Screen Recording permission missing): the mic is still the
    /// person using LidIA, so live words say "You", never "Others".
    @Test func micOnlyUsesOneEngineAndLabelsWordsAsYou() async {
        let registry = EngineRegistry()
        let transcriber = SourceSeparatedTranscriber(
            makeEngine: { registry.make() },
            separateSources: false,
            timeline: { $0 }
        )
        let input = AsyncStream<AudioChunk> { c in
            c.yield(chunk(.mic, at: 1))
            c.yield(chunk(.unknown, at: 2))
            c.finish()
        }
        var words: [TranscriptWord] = []
        for await w in transcriber.transcribe(input) { words.append(w) }

        #expect(registry.engines.count == 1)
        #expect(words.count == 2)
        #expect(words.allSatisfy { $0.isLocalSpeaker == true })
    }

    @Test func unknownSourceGoesToMicLane() {
        #expect(SourceSeparatedTranscriber.lane(for: .unknown, separate: true) == .mic)
        #expect(SourceSeparatedTranscriber.lane(for: .system, separate: true) == .system)
        #expect(SourceSeparatedTranscriber.lane(for: .system, separate: false) == .mic)
    }
}

@Suite("LiveWordTiming")
struct LiveWordTimingTests {
    @Test func relativeTimesAreOffsetByLaneStart() {
        let w = LiveWordTiming.normalize(word("hi", 2.0, 2.5), streamStart: 3, arrival: 99, timeline: { $0 })
        #expect(w.start == 5 && w.end == 5.5)
    }

    @Test func epochTimesGoThroughTheTimeline() {
        let start: TimeInterval = 1_700_000_000
        let w = LiveWordTiming.normalize(word("hi", start + 12, start + 12.4), streamStart: 3, arrival: 99, timeline: { $0 - start })
        #expect(abs(w.start - 12) < 0.0001)
        #expect(abs(w.end - 12.4) < 0.0001)
    }

    @Test func untimedWordsUseArrivalTime() {
        let w = LiveWordTiming.normalize(word("hi", 0, 0), streamStart: 3, arrival: 42, timeline: { $0 })
        #expect(w.start == 42 && w.end == 42)
    }
}

@Suite("SpeakerStreamMerger")
struct SpeakerStreamMergerTests {
    @Test func mergesSortedWithLabels() {
        let merged = SpeakerStreamMerger.merge(
            mic: [word("hello", 0), word("there", 2)],
            system: [word("hi", 1)]
        )
        #expect(merged.map(\.word) == ["hello", "hi", "there"])
        #expect(merged.map(\.isLocalSpeaker) == [true, false, true])
    }

    @Test func dropsMicRunsThatEchoSystemAudio() {
        let system = [word("we", 10), word("should", 10.3), word("ship", 10.6), word("friday", 10.9)]
        // The mic heard the same words from the speakers ~200 ms later, then the user spoke.
        let mic = [word("We", 10.2), word("should", 10.5), word("ship", 10.8), word("Friday.", 11.1), word("agreed", 13)]
        let merged = SpeakerStreamMerger.merge(mic: mic, system: system)
        #expect(merged.filter { $0.isLocalSpeaker == true }.map(\.word) == ["agreed"])
        #expect(merged.filter { $0.isLocalSpeaker == false }.count == 4)
    }

    @Test func keepsIsolatedCoincidentalMatches() {
        let system = [word("yes", 5), word("ok", 20)]
        let mic = [word("yes", 5.5), word("great", 6), word("ok", 20.1)]
        let kept = SpeakerStreamMerger.suppressEchoes(mic: mic, system: system)
        #expect(kept.count == 3)
    }
}

@Suite("ParakeetTokenMerge")
struct ParakeetTokenMergeTests {
    @Test func joinsSubwordTokensIntoWords() {
        let words = ParakeetBatchProcessor.mergeTokens(
            [(" hel", 0.0, 0.2), ("lo", 0.2, 0.4), (" wor", 0.5, 0.7), ("ld", 0.7, 0.9), (".", 0.9, 1.0)],
            confidence: 0.8
        )
        #expect(words.map(\.word) == ["hello", "world."])
        #expect(words[0].start == 0.0 && words[0].end == 0.4)
        #expect(words[1].start == 0.5 && words[1].end == 1.0)
    }

    @Test func handlesLeadingContinuationAndEmptyInput() {
        #expect(ParakeetBatchProcessor.mergeTokens([], confidence: 1).isEmpty)
        let words = ParakeetBatchProcessor.mergeTokens([("Hi", 0, 0.1), (" there", 0.2, 0.3)], confidence: 1)
        #expect(words.map(\.word) == ["Hi", "there"])
    }
}

@Suite("TranscriptionService")
struct TranscriptionServiceTests {
    @Test func recordedChunksCoverAllSamplesFromZero() async {
        var total = 0
        var first: TimeInterval?
        for await c in TranscriptionService.recordedChunks([Float](repeating: 0, count: 20_000), chunkFrames: 8_000) {
            total += c.samples.count
            if first == nil { first = c.timestamp }
        }
        #expect(total == 20_000)
        #expect(first == 0)
    }

    @Test func factoryFlags() {
        let granite = STTEngineFactory(engineType: .graniteSpeech, language: "", whisperKitModel: "")
        #expect(granite.isBatchOnly && granite.needsRecordedSamples)
        let parakeet = STTEngineFactory(engineType: .parakeet, language: "", whisperKitModel: "")
        #expect(!parakeet.isBatchOnly && parakeet.needsRecordedSamples)
        let apple = STTEngineFactory(engineType: .appleSpeech, language: "es-ES", whisperKitModel: "")
        #expect(!apple.isBatchOnly && !apple.needsRecordedSamples)
    }
}

// MARK: - Recovery

private actor EnqueueLog {
    var ids: [UUID] = []
    func add(_ id: UUID) { ids.append(id) }
}

@MainActor
@Suite("RecordingRecovery")
struct RecordingRecoveryTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, ActionItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Writes audio the way a recording does, then "crashes" (flush without finish).
    private func leaveCrashedAudio(for id: UUID, root: URL, micSeconds: Int = 2, systemSeconds: Int = 2) throws {
        let recorder = try MeetingAudioRecorder(meetingID: id, root: root, startTime: 0)
        if micSeconds > 0 {
            recorder.append(AudioChunk(samples: [Float](repeating: 0.2, count: 16_000 * micSeconds), sampleRate: 16_000, timestamp: Double(micSeconds), source: .mic))
        }
        if systemSeconds > 0 {
            recorder.append(AudioChunk(samples: [Float](repeating: 0.2, count: 16_000 * systemSeconds), sampleRate: 16_000, timestamp: Double(systemSeconds), source: .system))
        }
        recorder.flush()
    }

    @Test func interruptedRecordingWithAudioIsFinalizedTranscribedAndQueued() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Crashed")
        meeting.rawTranscript = [word("partial", 0)]
        context.insert(meeting)
        try context.save()
        try leaveCrashedAudio(for: meeting.id, root: root)

        let log = EnqueueLog()
        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context,
            excluding: nil,
            recordingsRoot: root,
            transcribe: { mic, system in
                #expect(mic.count == 32_000)
                #expect(system.count == 32_000)
                return SpeakerStreamMerger.merge(mic: [word("me", 0)], system: [word("them", 1)])
            },
            applyVocabulary: { $0.uppercased() },
            enqueue: { await log.add($0) }
        )

        #expect(outcome.queued == [meeting.id])
        #expect(await log.ids == [meeting.id])
        #expect(meeting.status == .queued)
        #expect(meeting.processingError == nil)
        #expect(meeting.rawTranscript.map(\.word) == ["ME", "THEM"])
        #expect(meeting.rawTranscript.map(\.isLocalSpeaker) == [true, false])
        #expect(abs(meeting.duration - 2) < 0.01)
        let path = try #require(meeting.audioFilePath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasSuffix("audio.m4a"))
    }

    @Test func interruptedRecordingWithoutAudioOrTranscriptFails() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Nothing")
        context.insert(meeting)
        try context.save()

        let log = EnqueueLog()
        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { await log.add($0) }
        )
        #expect(outcome.failed == [meeting.id])
        #expect(meeting.status == .failed)
        #expect(meeting.processingError == RecordingRecovery.noAudioMessage)
        #expect(await log.ids.isEmpty)
    }

    @Test func interruptedRecordingWithOnlyLiveTranscriptIsQueued() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Old build", rawTranscript: [word("saved", 0)])
        context.insert(meeting)
        try context.save()

        let log = EnqueueLog()
        _ = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { await log.add($0) }
        )
        #expect(meeting.status == .queued)
        #expect(await log.ids == [meeting.id])
    }

    @Test func audioWithNoSpeechFailsButKeepsTheAudio() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Silent")
        context.insert(meeting)
        try context.save()
        try leaveCrashedAudio(for: meeting.id, root: root, micSeconds: 1, systemSeconds: 0)

        _ = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { _ in }
        )
        #expect(meeting.status == .failed)
        #expect(meeting.processingError == RecordingRecovery.noSpeechMessage)
        #expect(meeting.audioFilePath?.hasSuffix("mic.m4a") == true)
    }

    @Test func activeRecordingIsLeftAlone() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let active = Meeting(title: "Live now")
        context.insert(active)
        try context.save()
        try leaveCrashedAudio(for: active.id, root: root)

        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: active.id, recordingsRoot: root,
            transcribe: { _, _ in [word("x", 0)] }, enqueue: { _ in }
        )
        #expect(outcome == RecordingRecovery.Outcome())
        #expect(active.status == .recording)
        #expect(active.audioFilePath == nil)
        // Its raw tracks are still being written, so they must not be touched.
        #expect(RecordingFinalizer.rawFrames(in: RecordingAudioStore.directory(for: active.id, root: root)).mic > 0)
    }

    @Test func stoppedMeetingWithUnencodedAudioGetsItsFile() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Quit while encoding", status: .complete)
        context.insert(meeting)
        try context.save()
        try leaveCrashedAudio(for: meeting.id, root: root)

        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { _ in }
        )
        #expect(outcome.finalizedOrphans == [meeting.id])
        #expect(meeting.status == .complete)
        #expect(meeting.audioFilePath != nil)
    }
}

// MARK: - Audio-only meetings interrupted after stop

@MainActor
@Suite("Audio-only crash recovery")
struct AudioOnlyRecoveryTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, ActionItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeQueue() -> DeferredMeetingProcessingQueue {
        DeferredMeetingProcessingQueue(defaults: UserDefaults(suiteName: "lidia.tests.audio-queue.\(UUID().uuidString)")!)
    }

    /// Synthetic recording left on disk, flushed but never finished (the app died).
    private func leaveRawAudio(for id: UUID, root: URL, seconds: Int = 2, system: Bool = true) throws -> URL {
        let recorder = try MeetingAudioRecorder(meetingID: id, root: root, startTime: 0)
        recorder.append(AudioChunk(samples: [Float](repeating: 0.2, count: 16_000 * seconds), sampleRate: 16_000, timestamp: Double(seconds), source: .mic))
        if system {
            recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000 * seconds), sampleRate: 16_000, timestamp: Double(seconds), source: .system))
        }
        recorder.flush(sync: true)
        return recorder.directory
    }

    private func rawExists(_ directory: URL) -> Bool {
        RecordingFinalizer.rawFrames(in: directory).mic > 0
    }

    @Test func batchOnlyMeetingInterruptedWhileEncodingIsRequeuedNotFailed() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        // Granite: no live words. The app died while the audio was being encoded.
        let meeting = Meeting(title: "Granite", status: .processing)
        let noAudio = Meeting(title: "Nothing", status: .processing)
        context.insert(meeting)
        context.insert(noAudio)
        try context.save()
        let directory = try leaveRawAudio(for: meeting.id, root: root)

        let report = await ProcessingRecovery.recover(
            in: context, queue: makeQueue(), progressCenter: ProcessingProgressCenter(), recordingsRoot: root
        )
        #expect(report.requeued == [meeting.id])
        #expect(report.failed == [noAudio.id])
        #expect(meeting.status == .queued)
        #expect(noAudio.processingError == ProcessingRecovery.interruptedNoTranscriptMessage)
        #expect(RecordingRecovery.needsTranscriptionFromAudio(meeting, recordingsRoot: root))

        // Launch recovery leaves the files to the drain (no double encode, raw tracks kept).
        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { _ in }, progressCenter: ProcessingProgressCenter()
        )
        #expect(outcome == RecordingRecovery.Outcome())
        #expect(rawExists(directory))

        // The drain transcribes it from the recording before summarising.
        let produced = await RecordingRecovery.transcribeFromRecordedAudio(
            meeting: meeting, recordingsRoot: root, modelContext: context,
            transcribe: { mic, system in
                #expect(mic.count == 32_000)
                #expect(system.count == 32_000)
                return SpeakerStreamMerger.merge(mic: [word("hello", 0)], system: [word("there", 1)])
            }
        )
        #expect(produced)
        #expect(meeting.rawTranscript.map(\.word) == ["hello", "there"])
        #expect(meeting.audioFilePath?.hasSuffix("audio.m4a") == true)
        #expect(!RecordingRecovery.needsTranscriptionFromAudio(meeting, recordingsRoot: root))
        // Transcript saved and encoded file verified: now the raw tracks go.
        #expect(!rawExists(directory))
    }

    @Test func meetingWithOnlyTheFinishedFileIsRequeuedAndTranscribedFromIt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Died while transcribing", status: .processing)
        context.insert(meeting)
        try context.save()
        let directory = try leaveRawAudio(for: meeting.id, root: root, system: false)
        // An older build encoded the audio and deleted the raw tracks, then died transcribing.
        let output = try RecordingFinalizer.finalize(directory: directory, loadSamples: false)
        meeting.audioFilePath = output.audioURL.path
        try context.save()

        let report = await ProcessingRecovery.recover(
            in: context, queue: makeQueue(), progressCenter: ProcessingProgressCenter(), recordingsRoot: root
        )
        #expect(report.requeued == [meeting.id])

        let produced = await RecordingRecovery.transcribeFromRecordedAudio(
            meeting: meeting, recordingsRoot: root, modelContext: context,
            transcribe: { mic, system in
                #expect(abs(mic.count - 32_000) < 3_200)
                #expect(system.isEmpty)
                return [word("recovered", 0)]
            },
            applyVocabulary: { $0.uppercased() }
        )
        #expect(produced)
        #expect(meeting.rawTranscript.map(\.word) == ["RECOVERED"])
    }

    @Test func crashDuringRecoveryTranscriptionIsRetriedFromTheRecording() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Crashed twice", rawTranscript: [word("partial", 0)])
        context.insert(meeting)
        try context.save()
        let directory = try leaveRawAudio(for: meeting.id, root: root)

        // While recovery transcribes, the raw tracks and the pending marker are still there.
        let probe = RecoveryProbe()
        _ = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in
                await probe.record(
                    raw: RecordingFinalizer.rawFrames(in: directory).mic > 0,
                    pending: RecordingAudioStore.isTranscriptionPending(in: directory)
                )
                return [word("full", 0)]
            },
            enqueue: { _ in }
        )
        #expect(await probe.raw == true)
        #expect(await probe.pending == true)
        #expect(meeting.status == .queued)
        #expect(!rawExists(directory))
        #expect(!RecordingAudioStore.isTranscriptionPending(in: directory))

        // The state that crash would have left: `.processing`, the partial live transcript,
        // raw tracks and marker still on disk.
        let second = Meeting(title: "Crashed mid-transcription", rawTranscript: [word("partial", 0)], status: .processing)
        context.insert(second)
        try context.save()
        let secondDir = try leaveRawAudio(for: second.id, root: root)
        RecordingAudioStore.markTranscriptionPending(in: secondDir)

        let report = await ProcessingRecovery.recover(
            in: context, queue: makeQueue(), progressCenter: ProcessingProgressCenter(), recordingsRoot: root
        )
        #expect(report.requeued.contains(second.id))
        // The partial transcript must not be summarised as is.
        #expect(RecordingRecovery.needsTranscriptionFromAudio(second, recordingsRoot: root))
        await RecordingRecovery.transcribeFromRecordedAudio(
            meeting: second, recordingsRoot: root, modelContext: context,
            transcribe: { _, _ in [word("whole", 0), word("meeting", 1)] }
        )
        #expect(second.rawTranscript.map(\.word) == ["whole", "meeting"])
        #expect(!RecordingAudioStore.isTranscriptionPending(in: secondDir))
        #expect(!rawExists(secondDir))
        #expect(!RecordingRecovery.needsTranscriptionFromAudio(second, recordingsRoot: root))
    }

    @Test func meetingFailedForNoTranscriptButWithAudioIsRequeuedAtLaunch() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Failed by old build", status: .failed, processingError: ProcessingRecovery.interruptedNoTranscriptMessage)
        let otherFailure = Meeting(title: "LLM down", status: .failed, processingError: "Summary generation failed")
        context.insert(meeting)
        context.insert(otherFailure)
        try context.save()
        let directory = try leaveRawAudio(for: meeting.id, root: root)
        _ = try RecordingFinalizer.finalize(directory: directory, loadSamples: false)

        let log = EnqueueLog()
        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { await log.add($0) }, progressCenter: ProcessingProgressCenter()
        )
        #expect(outcome.queued == [meeting.id])
        #expect(await log.ids == [meeting.id])
        #expect(meeting.status == .queued)
        #expect(meeting.processingError == nil)
        #expect(otherFailure.status == .failed)
        // The UI retry (RecordingSession.retryFromRecordedAudio) checks the same condition.
        #expect(RecordingRecovery.needsTranscriptionFromAudio(meeting, recordingsRoot: root))
    }

    @Test func noSpeechStillDropsRawTracksOnceEncoded() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let meeting = Meeting(title: "Silence", status: .processing)
        context.insert(meeting)
        try context.save()
        let directory = try leaveRawAudio(for: meeting.id, root: root)

        let produced = await RecordingRecovery.transcribeFromRecordedAudio(
            meeting: meeting, recordingsRoot: root, modelContext: context,
            transcribe: { _, _ in [] }
        )
        #expect(!produced)
        #expect(meeting.rawTranscript.isEmpty)
        #expect(meeting.audioFilePath != nil)
        #expect(!rawExists(directory))
    }
}

private actor RecoveryProbe {
    var raw: Bool?
    var pending: Bool?
    func record(raw: Bool, pending: Bool) {
        self.raw = raw
        self.pending = pending
    }
}

@Suite("RecordingFinalizer raw-track safety")
struct RecordingFinalizerRawTrackTests {
    private func rawRecording(root: URL) throws -> URL {
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        recorder.append(AudioChunk(samples: [Float](repeating: 0.2, count: 16_000), sampleRate: 16_000, timestamp: 1, source: .mic))
        recorder.flush(sync: true)
        return recorder.directory
    }

    @Test func keepRawTracksLeavesThemUntilDiscarded() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try rawRecording(root: root)

        let output = try RecordingFinalizer.finalize(directory: directory, loadSamples: true, keepRawTracks: true)
        #expect(output.micSamples.count == 16_000)
        #expect(RecordingFinalizer.rawFrames(in: directory).mic == 16_000)
        // Finalizing again still reads the raw tracks (a retry after a crash).
        let again = try RecordingFinalizer.finalize(directory: directory, loadSamples: true, keepRawTracks: true)
        #expect(again.micSamples.count == 16_000)

        RecordingFinalizer.discardRawTracks(in: directory)
        #expect(RecordingFinalizer.rawFrames(in: directory).mic == 0)
        #expect(RecordingFinalizer.hasAudio(in: directory))
    }

    @Test func rawTracksAreNotDiscardedWithoutAFinishedFile() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try rawRecording(root: root)
        RecordingFinalizer.discardRawTracks(in: directory)
        #expect(RecordingFinalizer.rawFrames(in: directory).mic == 16_000)
    }

    @Test func verifyRejectsUnreadableOrShortFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appendingPathComponent("bad.m4a")
        try Data(repeating: 0x42, count: 1_000).write(to: garbage)
        #expect(throws: RecordingFinalizer.FinalizeError.self) {
            try RecordingFinalizer.verify(garbage, expectedFrames: 16_000)
        }

        let url = try RecordingFinalizer.encode(baseName: "short", in: root) { write in
            try write([Float](repeating: 0.1, count: 16_000))
        }
        try RecordingFinalizer.verify(url, expectedFrames: 16_000)
        #expect(throws: RecordingFinalizer.FinalizeError.self) {
            try RecordingFinalizer.verify(url, expectedFrames: 16_000 * 60)
        }
    }
}

// MARK: - Default engine by language

@Suite("STTEngineDefaults")
struct STTEngineDefaultsTests {
    @Test func englishGetsParakeet() {
        #expect(STTEngineDefaults.recommendedEngine(languageCode: "en", appleOnDeviceAvailable: true) == .parakeet)
        #expect(STTEngineDefaults.recommendedEngine(languageCode: nil, appleOnDeviceAvailable: false) == .parakeet)
        #expect(STTEngineDefaults.recommendedEngine(sttLanguage: "en-GB") == .parakeet)
        #expect(STTEngineDefaults.recommendedEngine(sttLanguage: "", preferredLanguages: ["en-US"]) == .parakeet)
    }

    @Test func otherLanguagesNeverGetTheEnglishOnlyEngine() {
        #expect(STTEngineDefaults.recommendedEngine(languageCode: "es", appleOnDeviceAvailable: true) == .appleSpeech)
        #expect(STTEngineDefaults.recommendedEngine(languageCode: "es", appleOnDeviceAvailable: false) == .whisperKit)
        #expect(STTEngineDefaults.recommendedEngine(sttLanguage: "es-ES") != .parakeet)
        #expect(STTEngineDefaults.recommendedEngine(sttLanguage: "", preferredLanguages: ["es-MX", "en"]) != .parakeet)
    }
}

// MARK: - VAD timeline

@Suite("SpeechTimeMap")
struct SpeechTimeMapTests {
    @Test func extractRecordsWhereEachSpeechRangeCameFrom() {
        // 10 s of audio, speech at 1–2 s and 6–8 s.
        let samples = [Float](repeating: 0.1, count: 160_000)
        let (filtered, map) = VADFilter.extract(samples: samples, sampleRate: 16_000, ranges: [(6, 8), (1, 2)])
        #expect(filtered.count == 48_000)
        #expect(map.spans.count == 2)
        #expect(map.originalTime(0) == 1)
        #expect(map.originalTime(0.5) == 1.5)
        // 1.5 s into the filtered audio is 0.5 s into the second range (6 s).
        #expect(abs(map.originalTime(1.5) - 6.5) < 0.0001)
    }

    @Test func remapRestoresInterleavingOfSeparatelyTrimmedTracks() {
        // Mic speaks at 1 s and 9 s; system speaks at 5 s. After trimming, the mic's second
        // word sits at 0.5 s and would sort before the system word without remapping.
        let micMap = SpeechTimeMap(spans: [
            .init(filteredStart: 0, originalStart: 1, duration: 0.5),
            .init(filteredStart: 0.5, originalStart: 9, duration: 0.5),
        ])
        let systemMap = SpeechTimeMap(spans: [.init(filteredStart: 0, originalStart: 5, duration: 0.5)])
        let mic = micMap.remap([word("first", 0.1, 0.3), word("third", 0.6, 0.8)])
        let system = systemMap.remap([word("second", 0.1, 0.3)])
        let merged = SpeakerStreamMerger.merge(mic: mic, system: system)
        #expect(merged.map(\.word) == ["first", "second", "third"])
        #expect(abs(merged[2].start - 9.1) < 0.0001)
    }

    @Test func identityLeavesTimesAlone() {
        let words = [word("a", 3, 4)]
        #expect(SpeechTimeMap.identity.remap(words) == words)
    }
}
