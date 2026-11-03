import Foundation
import os

/// On-disk layout for meeting audio:
///
///     Application Support/LidIA/Recordings/<meeting id>/
///         manifest.json      written when recording starts
///         mic.pcm            raw 16 kHz Int16 mono, appended while recording
///         system.pcm         same, for system (other participants') audio
///         audio.m4a          final playable mix, written when recording stops
///         mic.m4a            final mic track (only when both tracks exist)
///         system.m4a         final system track (only when both tracks exist)
///         transcription.pending   present while the meeting's transcript must still be
///                            rebuilt from this audio (crash recovery)
///
/// The raw `.pcm` files are deleted once the final files are written and verified and the
/// meeting's transcript is saved.
enum RecordingAudioStore {
    static let micRawName = "mic.pcm"
    static let systemRawName = "system.pcm"
    static let manifestName = "manifest.json"
    static let transcriptionPendingName = "transcription.pending"
    static let mixedBaseName = "audio"
    static let micBaseName = "mic"
    static let systemBaseName = "system"

    static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("LidIA", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func directory(for meetingID: UUID, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    struct Manifest: Codable, Sendable, Equatable {
        var version: Int = 1
        var meetingID: UUID
        var sampleRate: Int = PCMTrackWriter.sampleRate
        var encoding: String = "pcm_s16le"
        var startedAt: Date
        var captureMode: String
    }

    static func writeManifest(_ manifest: Manifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Marks that the meeting's saved transcript is partial or missing and must be rebuilt
    /// from this audio, so a crash during transcription is retried rather than summarised.
    static func markTranscriptionPending(in directory: URL) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(transcriptionPendingName).path, contents: nil)
    }

    static func clearTranscriptionPending(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(transcriptionPendingName))
    }

    static func isTranscriptionPending(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(transcriptionPendingName).path)
    }

    static func readManifest(in directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }
}

/// Writes a meeting's mic and system audio to disk while it is being recorded.
///
/// Chunks arrive from the capture callbacks with wall-clock timestamps. The recorder maps
/// them onto one shared timeline (wall-clock time since start, minus paused time) so both
/// tracks line up sample-for-sample with each other and with live transcript timings.
/// Buffered audio is flushed every second and synced to storage every ten seconds.
final class MeetingAudioRecorder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "MeetingAudioRecorder")

    let meetingID: UUID
    let directory: URL
    let startTime: TimeInterval

    /// Shared by both tracks, so a capped clock jump shifts them together.
    let timeline = PCMTrackTimeline()
    let micWriter: PCMTrackWriter
    let systemWriter: PCMTrackWriter

    private struct Clock {
        var pausedTotal: TimeInterval = 0
        var pauseStart: TimeInterval?
        var finished = false
    }

    private let clock = OSAllocatedUnfairLock(initialState: Clock())
    private let flushQueue = DispatchQueue(label: "io.lidia.app.recorder.flush", qos: .utility)
    private let timerLock = NSLock()
    private var timer: DispatchSourceTimer?

    /// Creates the meeting's recording directory and opens both track files.
    init(
        meetingID: UUID,
        root: URL = RecordingAudioStore.defaultRoot,
        startTime: TimeInterval = Date().timeIntervalSince1970,
        captureMode: String = AudioCaptureMode.micOnly.rawValue
    ) throws {
        self.meetingID = meetingID
        self.startTime = startTime
        let directory = RecordingAudioStore.directory(for: meetingID, root: root)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordingAudioStore.writeManifest(
            .init(meetingID: meetingID, startedAt: Date(timeIntervalSince1970: startTime), captureMode: captureMode),
            in: directory
        )
        micWriter = try PCMTrackWriter(url: directory.appendingPathComponent(RecordingAudioStore.micRawName), timeline: timeline)
        systemWriter = try PCMTrackWriter(url: directory.appendingPathComponent(RecordingAudioStore.systemRawName), timeline: timeline)
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Timeline

    /// Seconds of recorded (unpaused) time at a wall-clock instant, matching positions in
    /// the track files (time cut by a capped clock jump is excluded too).
    func timelinePosition(at wallClock: TimeInterval) -> TimeInterval {
        let skipped = Double(timeline.shiftFrames) / Double(PCMTrackWriter.sampleRate)
        return clock.withLock { c in
            var paused = c.pausedTotal
            if let pauseStart = c.pauseStart, wallClock > pauseStart {
                paused += wallClock - pauseStart
            }
            return max(0, wallClock - startTime - paused - skipped)
        }
    }

    var isPaused: Bool {
        clock.withLock { $0.pauseStart != nil }
    }

    func pause(at wallClock: TimeInterval = Date().timeIntervalSince1970) {
        clock.withLock { c in
            guard c.pauseStart == nil, !c.finished else { return }
            c.pauseStart = wallClock
        }
    }

    func resume(at wallClock: TimeInterval = Date().timeIntervalSince1970) {
        clock.withLock { c in
            guard let pauseStart = c.pauseStart else { return }
            c.pausedTotal += max(0, wallClock - pauseStart)
            c.pauseStart = nil
        }
    }

    // MARK: - Writing

    /// Routes a captured chunk to its track. Dropped while paused or after `finish()`.
    /// `chunk.timestamp` is the wall-clock time the buffer arrived (its end).
    func append(_ chunk: AudioChunk) {
        guard !chunk.samples.isEmpty, chunk.sampleRate > 0 else { return }
        let (skip, position) = clock.withLock { c -> (Bool, TimeInterval) in
            if c.finished || c.pauseStart != nil { return (true, 0) }
            let bufferStart = chunk.timestamp - chunk.duration
            return (false, max(0, bufferStart - startTime - c.pausedTotal))
        }
        guard !skip else { return }
        let samples = chunk.sampleRate == PCMTrackWriter.sampleRate
            ? chunk.samples
            : AudioResampler.resample(chunk.samples, from: chunk.sampleRate, to: PCMTrackWriter.sampleRate)
        let frame = Int64((position * Double(PCMTrackWriter.sampleRate)).rounded())
        writer(for: chunk.source).append(samples, timelineFrame: frame)
    }

    private func writer(for source: AudioSource) -> PCMTrackWriter {
        source == .system ? systemWriter : micWriter
    }

    var micFrames: Int64 { micWriter.totalFrames }
    var systemFrames: Int64 { systemWriter.totalFrames }

    /// Writes buffered audio to disk now. Each track is flushed on its own, so a failure on
    /// one doesn't hold back the other; failed samples stay buffered for the next flush.
    func flush(sync: Bool = false) {
        for writer in [micWriter, systemWriter] {
            do {
                try writer.flush(sync: sync)
            } catch {
                Self.logger.error("Audio flush failed for \(writer.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Starts flushing every `interval` seconds and syncing every `syncEvery` flushes.
    func startPeriodicFlush(interval: TimeInterval = 1, syncEvery: Int = 10) {
        timerLock.lock()
        defer { timerLock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: flushQueue)
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let syncEvery = max(1, syncEvery)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            let tick = ticks.withLock { value -> Int in
                value += 1
                return value
            }
            self?.flush(sync: tick % syncEvery == 0)
        }
        source.resume()
        timer = source
    }

    /// Stops the flush timer and closes both tracks. Returns the recording directory.
    @discardableResult
    func finish() -> URL {
        let alreadyFinished = clock.withLock { c -> Bool in
            defer { c.finished = true }
            return c.finished
        }
        guard !alreadyFinished else { return directory }
        timerLock.lock()
        timer?.cancel()
        timer = nil
        timerLock.unlock()
        // Wait for any in-flight timer flush before closing the files.
        flushQueue.sync {}
        // Close each track on its own: a failure on one must not leave the other open.
        for writer in [micWriter, systemWriter] {
            do {
                try writer.close()
            } catch {
                Self.logger.error("Closing \(writer.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        return directory
    }
}
