import Foundation
import os

struct AudioSourceEvent: Sendable {
    let source: AudioSource
    let timestamp: TimeInterval
    let rms: Float
}

@MainActor
@Observable
final class CaptureService {
    enum AudioQualityState {
        case good
        case lowInput
        case clipping
        case noInput
    }

    /// What `stopCapture()` hands back to the recording session.
    struct StopResult: Sendable {
        /// Directory holding the meeting's audio tracks, when disk recording was active.
        var recordingDirectory: URL?
        /// Samples kept in memory only when disk recording could not be started.
        var inMemoryMic: [Float]
        var inMemorySystem: [Float]
        var sourceEvents: [AudioSourceEvent]
        /// Frames written to disk per track (16 kHz).
        var recordedMicFrames: Int64
        var recordedSystemFrames: Int64

        var hasAudio: Bool {
            !inMemoryMic.isEmpty || !inMemorySystem.isEmpty || recordedMicFrames > 0 || recordedSystemFrames > 0
        }
    }

    private static let logger = Logger(subsystem: "io.lidia.app", category: "CaptureService")

    private let audioManager = AudioCaptureManager()
    private var recorder: MeetingAudioRecorder?

    var elapsedTime: TimeInterval {
        audioManager.elapsedTime
    }

    var currentRMS: Float {
        audioManager.currentRMS
    }

    /// Returns recent per-source (mic/system) RMS values from the last few seconds.
    /// Used by extended silence detection to check both channels independently.
    struct PerSourceRMS: Sendable {
        var mic: Float = 0
        var system: Float = 0
    }

    func recentPerSourceRMS() -> PerSourceRMS {
        audioManager.recentPerSourceRMS()
    }

    var activeCaptureMode: AudioCaptureMode {
        audioManager.activeCaptureMode
    }

    var captureStatus: AudioCaptureManager.CaptureStatus {
        audioManager.captureStatus
    }

    /// Called when system audio is unavailable and the recording continues mic-only.
    var onFallbackToMic: (@MainActor (String) -> Void)? {
        get { audioManager.onFallbackToMic }
        set { audioManager.onFallbackToMic = newValue }
    }

    var audioQualityState: AudioQualityState {
        let rms = audioManager.currentRMS
        if rms < 0.003 { return .noInput }
        if rms > 0.65 { return .clipping }
        if rms < 0.015 { return .lowInput }
        return .good
    }

    var audioStream: AsyncStream<AudioChunk> {
        audioManager.audioStream
    }

    /// Whether audio is being written to disk for the current recording.
    var isRecordingToDisk: Bool {
        recorder != nil
    }

    /// Maps a wall-clock time to seconds into the recording (pauses excluded), matching
    /// positions in the recorded audio files.
    func timelineMapper() -> @Sendable (TimeInterval) -> TimeInterval {
        if let recorder {
            return { recorder.timelinePosition(at: $0) }
        }
        let start = Date().timeIntervalSince1970
        return { max(0, $0 - start) }
    }

    /// Starts capture. With a `meetingID`, audio is also written incrementally to
    /// `RecordingAudioStore.directory(for:)`, so a crash loses at most about a second.
    /// If the recording directory can't be created, capture still starts and keeps audio in
    /// memory as before.
    func startCapture(mode: AudioCaptureMode, meetingID: UUID? = nil, recordingsRoot: URL = RecordingAudioStore.defaultRoot) async throws {
        if let meetingID {
            do {
                let recorder = try MeetingAudioRecorder(meetingID: meetingID, root: recordingsRoot, captureMode: mode.rawValue)
                recorder.startPeriodicFlush()
                self.recorder = recorder
            } catch {
                Self.logger.error("Can't record audio to disk, keeping it in memory: \(error.localizedDescription)")
                recorder = nil
            }
        }
        do {
            try await audioManager.startCapture(mode: mode, recorder: recorder)
        } catch {
            if let recorder {
                recorder.finish()
                if !RecordingFinalizer.hasAudio(in: recorder.directory) {
                    try? FileManager.default.removeItem(at: recorder.directory)
                }
            }
            recorder = nil
            throw error
        }
    }

    /// Stops capture and closes the disk tracks. Finalising the files (encoding) is done
    /// separately with `finalizeRecording(directory:loadSamples:)`, off the main actor.
    func stopCapture() -> StopResult {
        let mic = audioManager.drainAccumulatedMicSamples()
        let system = audioManager.drainAccumulatedSystemSamples()
        let events = audioManager.drainSourceEvents()
        audioManager.stopCapture()
        let recorder = self.recorder
        self.recorder = nil
        let directory = recorder?.finish()
        return StopResult(
            recordingDirectory: directory,
            inMemoryMic: mic,
            inMemorySystem: system,
            sourceEvents: events,
            recordedMicFrames: recorder?.micFrames ?? 0,
            recordedSystemFrames: recorder?.systemFrames ?? 0
        )
    }

    /// Encodes the recorded tracks to playable files and optionally loads them as 16 kHz
    /// samples for batch transcription. With `keepRawTracks`, the raw tracks stay on disk
    /// until the caller has saved a transcript (`RecordingFinalizer.discardRawTracks`).
    nonisolated static func finalizeRecording(
        directory: URL,
        loadSamples: Bool,
        keepRawTracks: Bool = false
    ) async throws -> RecordingFinalizer.Output {
        try await Task.detached(priority: .userInitiated) {
            try RecordingFinalizer.finalize(directory: directory, loadSamples: loadSamples, keepRawTracks: keepRawTracks)
        }.value
    }

    func drainSourceEvents() -> [AudioSourceEvent] {
        audioManager.drainSourceEvents()
    }

    func pauseCapture() {
        audioManager.pauseCapture()
    }

    func resumeCapture() {
        audioManager.resumeCapture()
    }
}
