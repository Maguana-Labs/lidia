import Foundation
import Testing
@testable import LidIA

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lidia-audio-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sine(frames: Int, frequency: Float = 440, amplitude: Float = 0.5, sampleRate: Int = 16_000) -> [Float] {
    (0..<frames).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(sampleRate)) }
}

@Suite("PCMTrackWriter")
struct PCMTrackWriterTests {
    @Test func flushedSamplesAreReadableBeforeClose() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.pcm")
        let writer = try PCMTrackWriter(url: url)

        writer.append(sine(frames: 16_000))
        try writer.flush()
        // Simulates a force-quit: the writer is never closed, but flushed audio is on disk.
        let read = try PCMTrackWriter.readSamples(from: url)
        #expect(read.count == 16_000)
        #expect(PCMTrackWriter.frameCount(at: url) == 16_000)
    }

    @Test func unflushedSamplesAreNotOnDiskYet() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.pcm")
        let writer = try PCMTrackWriter(url: url)

        writer.append(sine(frames: 800))
        #expect(writer.totalFrames == 800)
        #expect(PCMTrackWriter.frameCount(at: url) == 0)
        try writer.close()
        #expect(PCMTrackWriter.frameCount(at: url) == 800)
    }

    @Test func int16RoundTripStaysClose() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.pcm")
        let writer = try PCMTrackWriter(url: url)
        let input: [Float] = [0, 0.25, -0.25, 0.999, -0.999, 1.5, -1.5, .nan]
        writer.append(input)
        try writer.close()

        let read = try PCMTrackWriter.readSamples(from: url)
        #expect(read.count == input.count)
        for (a, b) in zip(read.prefix(5), input.prefix(5)) {
            #expect(abs(a - b) < 0.001)
        }
        #expect(read[5] == 1)       // clipped
        #expect(read[6] < -0.99)    // clipped
        #expect(read[7] == 0)       // NaN becomes silence
    }

    @Test func padsGapsBeyondToleranceToKeepTimeline() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try PCMTrackWriter(url: dir.appendingPathComponent("s.pcm"))

        writer.append([Float](repeating: 0.1, count: 1_600), timelineFrame: 0)
        // Small jitter (well under 0.25 s) is not padded.
        writer.append([Float](repeating: 0.1, count: 1_600), timelineFrame: 1_600 + 800)
        #expect(writer.totalFrames == 3_200)
        // A 2 s gap is filled with silence.
        writer.append([Float](repeating: 0.1, count: 1_600), timelineFrame: 3_200 + 32_000)
        #expect(writer.totalFrames == 3_200 + 32_000 + 1_600)
        try writer.close()

        let read = try PCMTrackWriter.readSamples(from: writer.url)
        #expect(read[3_200 + 100] == 0)
        #expect(abs(read[3_200 + 32_000 + 10] - 0.1) < 0.001)
    }

    @Test func reopeningAppendsAndDropsTornHalfSample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.pcm")
        let first = try PCMTrackWriter(url: url)
        first.append([Float](repeating: 0.2, count: 100))
        try first.close()
        // Simulate a torn write: one stray byte at the end.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7F]))
        try handle.close()
        #expect(try PCMTrackWriter.readSamples(from: url).count == 100)

        let second = try PCMTrackWriter(url: url)
        #expect(second.totalFrames == 100)
        second.append([Float](repeating: 0.2, count: 50))
        try second.close()
        #expect(PCMTrackWriter.frameCount(at: url) == 150)
    }

    @Test func readerHandlesBlocksSmallerThanFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("b.pcm")
        let writer = try PCMTrackWriter(url: url)
        writer.append(sine(frames: 10_001))
        try writer.close()

        var total = 0
        var blocks = 0
        try PCMTrackWriter.forEachBlock(of: url, blockFrames: 1_000) { block in
            total += block.count
            blocks += 1
        }
        #expect(total == 10_001)
        #expect(blocks == 11)
    }
}

@Suite("MeetingAudioRecorder")
struct MeetingAudioRecorderTests {
    @Test func routesChunksBySourceAndResamples() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start: TimeInterval = 1_000
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: start, captureMode: "test")

        // 1 s of 48 kHz mic audio arriving at t = 1 s, and 1 s of 16 kHz system audio.
        recorder.append(AudioChunk(samples: sine(frames: 48_000, sampleRate: 48_000), sampleRate: 48_000, timestamp: start + 1, source: .mic))
        recorder.append(AudioChunk(samples: sine(frames: 16_000), sampleRate: 16_000, timestamp: start + 1, source: .system))
        recorder.finish()

        #expect(recorder.micFrames == 16_000)
        #expect(recorder.systemFrames == 16_000)
        #expect(RecordingAudioStore.readManifest(in: recorder.directory)?.captureMode == "test")
    }

    @Test func lateStartingTrackIsAlignedWithSilence() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start: TimeInterval = 500
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: start)

        // Mic runs from 0–3 s; system audio only starts at 2 s.
        for second in 1...3 {
            recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: start + Double(second), source: .mic))
        }
        recorder.append(AudioChunk(samples: [Float](repeating: 0.3, count: 16_000), sampleRate: 16_000, timestamp: start + 3, source: .system))
        recorder.finish()

        let system = try PCMTrackWriter.readSamples(from: recorder.directory.appendingPathComponent(RecordingAudioStore.systemRawName))
        #expect(system.count == 48_000)
        #expect(system[16_000] == 0)
        #expect(abs(system[40_000] - 0.3) < 0.001)
    }

    @Test func pausedTimeIsExcludedFromTimeline() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start: TimeInterval = 0
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: start)

        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 1, source: .mic))
        recorder.pause(at: 1)
        // Arrives while paused: dropped.
        recorder.append(AudioChunk(samples: [Float](repeating: 0.9, count: 16_000), sampleRate: 16_000, timestamp: 5, source: .mic))
        recorder.resume(at: 11)
        #expect(recorder.timelinePosition(at: 12) == 2)
        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 12, source: .mic))
        recorder.finish()

        // No 10 s gap: paused time doesn't count.
        #expect(recorder.micFrames == 32_000)
    }

    @Test func periodicFlushWritesWithoutFinish() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: Date().timeIntervalSince1970)
        recorder.startPeriodicFlush(interval: 0.05, syncEvery: 2)
        recorder.append(AudioChunk(samples: sine(frames: 4_000), sampleRate: 16_000, timestamp: Date().timeIntervalSince1970, source: .mic))

        let micURL = recorder.directory.appendingPathComponent(RecordingAudioStore.micRawName)
        var flushed: Int64 = 0
        for _ in 0..<40 where flushed == 0 {
            try await Task.sleep(for: .milliseconds(50))
            flushed = PCMTrackWriter.frameCount(at: micURL)
        }
        #expect(flushed == 4_000)
        recorder.finish()
    }

    @Test func chunksAfterFinishAreIgnored() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        recorder.append(AudioChunk(samples: [0.1, 0.1], sampleRate: 16_000, timestamp: 0, source: .mic))
        recorder.finish()
        recorder.append(AudioChunk(samples: [0.1, 0.1], sampleRate: 16_000, timestamp: 0, source: .mic))
        recorder.finish()
        #expect(PCMTrackWriter.frameCount(at: recorder.directory.appendingPathComponent(RecordingAudioStore.micRawName)) == 2)
    }
}

@Suite("RecordingFinalizer")
struct RecordingFinalizerTests {
    private func record(mic: [Float], system: [Float], root: URL) throws -> MeetingAudioRecorder {
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        if !mic.isEmpty {
            recorder.append(AudioChunk(samples: mic, sampleRate: 16_000, timestamp: Double(mic.count) / 16_000, source: .mic))
        }
        if !system.isEmpty {
            recorder.append(AudioChunk(samples: system, sampleRate: 16_000, timestamp: Double(system.count) / 16_000, source: .system))
        }
        // Flush but don't finish: the same state a force-quit leaves behind.
        recorder.flush(sync: true)
        return recorder
    }

    @Test func dualTrackProducesMixAndSeparateTracks() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try record(mic: sine(frames: 32_000, frequency: 300), system: sine(frames: 48_000, frequency: 600), root: root)

        let output = try RecordingFinalizer.finalize(directory: recorder.directory, loadSamples: true)
        #expect(output.audioURL.lastPathComponent == "audio.m4a")
        #expect(output.micURL != nil)
        #expect(output.systemURL != nil)
        #expect(abs(output.duration - 3.0) < 0.01)
        #expect(output.micSamples.count == 32_000)
        #expect(output.systemSamples.count == 48_000)
        // Raw tracks are gone once the final files exist.
        #expect(!FileManager.default.fileExists(atPath: recorder.directory.appendingPathComponent(RecordingAudioStore.micRawName).path))
        #expect(!FileManager.default.fileExists(atPath: recorder.directory.appendingPathComponent(RecordingAudioStore.systemRawName).path))

        // The playable file decodes to roughly the recorded length.
        let decoded = try RecordingFinalizer.readAudioFile(output.audioURL)
        #expect(abs(Double(decoded.count) / 16_000 - 3.0) < 0.2)
    }

    @Test func micOnlyRecordingUsesMicTrackAsPlayableFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try record(mic: sine(frames: 16_000), system: [], root: root)

        let output = try RecordingFinalizer.finalize(directory: recorder.directory, loadSamples: false)
        #expect(output.micURL == output.audioURL)
        #expect(output.systemURL == nil)
        #expect(output.micSamples.isEmpty)
        #expect(RecordingFinalizer.finishedFile(named: RecordingAudioStore.mixedBaseName, in: recorder.directory) == nil)
    }

    @Test func finalizeIsIdempotent() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try record(mic: sine(frames: 16_000), system: sine(frames: 16_000), root: root)

        let first = try RecordingFinalizer.finalize(directory: recorder.directory, loadSamples: false)
        let second = try RecordingFinalizer.finalize(directory: recorder.directory, loadSamples: true)
        #expect(first.audioURL == second.audioURL)
        #expect(abs(Double(second.micSamples.count) / 16_000 - 1.0) < 0.2)
        #expect(abs(second.duration - 1.0) < 0.2)
    }

    @Test func emptyDirectoryThrowsNoAudio() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        recorder.finish()
        #expect(!RecordingFinalizer.hasAudio(in: recorder.directory))
        #expect(throws: RecordingFinalizer.FinalizeError.self) {
            try RecordingFinalizer.finalize(directory: recorder.directory, loadSamples: false)
        }
    }

    @Test func cafFallbackProducesReadableFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = sine(frames: 8_000)
        let url = try RecordingFinalizer.encode(baseName: "x", in: root, preferring: [.caf]) { write in
            try write(input)
        }
        #expect(url.pathExtension == "caf")
        let decoded = try RecordingFinalizer.readAudioFile(url)
        #expect(decoded.count == 8_000)
        #expect(abs(decoded[100] - input[100]) < 0.001)
    }

    @Test func mixClipsAndPadsShorterTrack() {
        let mixed = RecordingFinalizer.mixBlocks([0.8, 0.8, 0.1], [0.5])
        #expect(mixed == [1, 0.8, 0.1])
    }
}

private struct SimulatedDiskFull: Error {}

@Suite("PCMTrackWriter failures and clock jumps")
struct PCMTrackWriterRobustnessTests {
    @Test func failedWriteKeepsSamplesForTheNextFlush() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.pcm")
        let writer = try PCMTrackWriter(url: url)
        let realWrite = writer.writeData

        writer.append([Float](repeating: 0.1, count: 1_000))
        writer.writeData = { _, _ in throw SimulatedDiskFull() }
        #expect(throws: SimulatedDiskFull.self) { try writer.flush() }
        #expect(writer.pendingFrames == 1_000)
        #expect(PCMTrackWriter.frameCount(at: url) == 0)

        // Space frees up: nothing counted in totalFrames was lost.
        writer.writeData = realWrite
        writer.append([Float](repeating: 0.2, count: 500))
        try writer.flush()
        #expect(writer.pendingFrames == 0)
        #expect(PCMTrackWriter.frameCount(at: url) == writer.totalFrames)
        let read = try PCMTrackWriter.readSamples(from: url)
        #expect(read.count == 1_500)
        #expect(abs(read[999] - 0.1) < 0.001)
        #expect(abs(read[1_000] - 0.2) < 0.001)
    }

    @Test func partialWriteIsRolledBackBeforeRetry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.pcm")
        let writer = try PCMTrackWriter(url: url)
        let realWrite = writer.writeData

        writer.append([Float](repeating: 0.1, count: 400))
        try writer.flush()
        writer.append([Float](repeating: 0.2, count: 600))
        // Half the bytes land, then the disk fills up.
        writer.writeData = { handle, data in
            try handle.write(contentsOf: data.prefix(data.count / 2))
            throw SimulatedDiskFull()
        }
        #expect(throws: SimulatedDiskFull.self) { try writer.flush() }
        #expect(PCMTrackWriter.frameCount(at: url) == 400)

        writer.writeData = realWrite
        try writer.close()
        #expect(PCMTrackWriter.frameCount(at: url) == 1_000)
    }

    @Test func tracksStayAlignedWhenOneTrackFailsToWrite() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        let realWrite = recorder.micWriter.writeData

        for second in 1...2 {
            recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: Double(second), source: .mic))
            recorder.append(AudioChunk(samples: [Float](repeating: 0.3, count: 16_000), sampleRate: 16_000, timestamp: Double(second), source: .system))
        }
        recorder.micWriter.writeData = { _, _ in throw SimulatedDiskFull() }
        recorder.flush()
        // The system track still flushed even though the mic write failed first.
        #expect(PCMTrackWriter.frameCount(at: recorder.systemWriter.url) == 32_000)
        #expect(PCMTrackWriter.frameCount(at: recorder.micWriter.url) == 0)

        recorder.micWriter.writeData = realWrite
        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 3, source: .mic))
        recorder.append(AudioChunk(samples: [Float](repeating: 0.3, count: 16_000), sampleRate: 16_000, timestamp: 3, source: .system))
        recorder.finish()
        #expect(PCMTrackWriter.frameCount(at: recorder.micWriter.url) == 48_000)
        #expect(PCMTrackWriter.frameCount(at: recorder.systemWriter.url) == 48_000)
    }

    @Test func finishClosesSystemTrackEvenWhenMicCloseFails() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 1, source: .mic))
        recorder.append(AudioChunk(samples: [Float](repeating: 0.3, count: 16_000), sampleRate: 16_000, timestamp: 1, source: .system))
        recorder.micWriter.writeData = { _, _ in throw SimulatedDiskFull() }

        recorder.finish()
        #expect(PCMTrackWriter.frameCount(at: recorder.systemWriter.url) == 16_000)
        // Both tracks are closed: later chunks are ignored.
        recorder.systemWriter.append([0.5, 0.5])
        #expect(recorder.systemWriter.totalFrames == 16_000)
    }

    @Test func clockJumpCostsOneCappedFillAndTracksStayAligned() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap: Int64 = 16_000  // 1 s, to keep the test small
        let timeline = PCMTrackTimeline(maxGapFillFrames: cap)
        let mic = try PCMTrackWriter(url: dir.appendingPathComponent("mic.pcm"), timeline: timeline)
        let system = try PCMTrackWriter(url: dir.appendingPathComponent("system.pcm"), timeline: timeline)
        let second = 16_000

        // 0–2 s of audio on both tracks.
        for s in 0..<2 {
            mic.append([Float](repeating: 0.1, count: second), timelineFrame: Int64(s * second))
            system.append([Float](repeating: 0.3, count: second), timelineFrame: Int64(s * second))
        }
        // The Mac sleeps for an hour; both tracks resume.
        let wake = Int64(3_600 * second)
        for s in 0..<3 {
            mic.append([Float](repeating: 0.1, count: second), timelineFrame: wake + Int64(s * second))
            system.append([Float](repeating: 0.3, count: second), timelineFrame: wake + Int64(s * second))
        }

        // 2 s + one 1 s capped fill + 3 s — not an hour of zeros, and no re-padding per chunk.
        #expect(mic.totalFrames == Int64(6 * second))
        #expect(system.totalFrames == mic.totalFrames)
        #expect(timeline.shiftFrames == wake - Int64(3 * second))
        try mic.close()
        try system.close()
        let read = try PCMTrackWriter.readSamples(from: mic.url)
        #expect(read[2 * second + 100] == 0)               // the capped fill
        #expect(abs(read[3 * second + 100] - 0.1) < 0.001) // first chunk after wake
        #expect(abs(read[5 * second + 100] - 0.1) < 0.001) // later chunks follow directly
    }

    @Test func oneTrackDroppingOutIsStillPaddedToTheSharedTimeline() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let timeline = PCMTrackTimeline(maxGapFillFrames: 16_000)
        let mic = try PCMTrackWriter(url: dir.appendingPathComponent("mic.pcm"), timeline: timeline)
        let system = try PCMTrackWriter(url: dir.appendingPathComponent("system.pcm"), timeline: timeline)
        let second = 16_000

        system.append([Float](repeating: 0.3, count: second), timelineFrame: 0)
        for s in 0..<5 {
            mic.append([Float](repeating: 0.1, count: second), timelineFrame: Int64(s * second))
        }
        // System audio was silent for 3 s (longer than the cap) while the mic kept going:
        // that's real time, not a clock jump, so it's padded in full.
        system.append([Float](repeating: 0.3, count: second), timelineFrame: Int64(4 * second))
        #expect(timeline.shiftFrames == 0)
        #expect(system.totalFrames == mic.totalFrames)
    }

    @Test func recorderTimelineSkipsTheCutTimeForLiveTranscript() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingAudioRecorder(meetingID: UUID(), root: root, startTime: 0)
        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 1, source: .mic))
        // Woke up two hours later.
        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 7_201, source: .mic))
        recorder.append(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 7_202, source: .mic))
        recorder.append(AudioChunk(samples: [Float](repeating: 0.2, count: 16_000), sampleRate: 16_000, timestamp: 7_202, source: .system))

        let cap = Double(PCMTrackWriter.maxGapFillFrames) / 16_000
        #expect(recorder.micFrames == Int64((1 + cap + 2) * 16_000))
        #expect(recorder.systemFrames == recorder.micFrames)
        // A word spoken at the end lines up with the end of the files.
        #expect(abs(recorder.timelinePosition(at: 7_202) - (1 + cap + 2)) < 0.01)
        recorder.finish()
    }
}
