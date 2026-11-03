import Foundation
import SwiftData
import os

/// Finishes recordings that were interrupted by a crash, force-quit or power loss.
///
/// A meeting still marked `.recording` at launch was never stopped. Its audio is on disk
/// (written incrementally by `MeetingAudioRecorder`), so recovery:
/// 1. finalises the raw tracks into playable files and sets `audioFilePath`,
/// 2. transcribes the recorded audio (mic and system separately),
/// 3. marks the meeting `.queued` and adds it to the deferred processing queue, so the
///    normal pipeline produces the summary.
///
/// The raw tracks stay on disk until the transcript is saved, and a
/// `transcription.pending` marker records that the saved transcript is still partial. A
/// crash during step 2 therefore leaves everything needed to transcribe again: the next
/// launch requeues the meeting (`ProcessingRecovery`) and the drain re-transcribes it from
/// disk (`transcribeFromRecordedAudio`) instead of summarising a partial live transcript.
///
/// With no audio on disk, a meeting that still has a live transcript is queued as is;
/// otherwise it is marked `.failed` with an explanation.
@MainActor
enum RecordingRecovery {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "RecordingRecovery")

    struct Outcome: Equatable, Sendable {
        /// Meetings handed to the deferred processing queue.
        var queued: [UUID] = []
        /// Meetings marked `.failed`.
        var failed: [UUID] = []
        /// Meetings that weren't recording but had unfinished audio, now finalised.
        var finalizedOrphans: [UUID] = []
    }

    typealias Transcriber = @Sendable (_ mic: [Float], _ system: [Float]) async -> [TranscriptWord]
    typealias Enqueuer = @Sendable (_ meetingID: UUID) async -> Void

    static let noAudioMessage =
        "Recording was interrupted (LidIA quit or crashed) before any audio was saved."
    static let noSpeechMessage =
        "Recording was interrupted. The audio was recovered, but no speech could be transcribed from it."

    /// Recovers every interrupted recording except `activeMeetingID` (a recording in progress).
    @discardableResult
    static func recoverInterruptedRecordings(
        modelContext: ModelContext,
        excluding activeMeetingID: UUID?,
        recordingsRoot: URL = RecordingAudioStore.defaultRoot,
        transcribe: @escaping Transcriber,
        applyVocabulary: (String) -> String = { $0 },
        enqueue: @escaping Enqueuer = RecordingRecovery.enqueueForProcessing,
        progressCenter: ProcessingProgressCenter? = nil
    ) async -> Outcome {
        var outcome = Outcome()
        guard let meetings = try? modelContext.fetch(FetchDescriptor<Meeting>()) else { return outcome }
        let center = progressCenter ?? .shared

        // Only this Mac's meetings: one that another device is recording right now arrives
        // through iCloud as `.recording`, and its audio isn't here.
        for meeting in meetings where meeting.id != activeMeetingID && meeting.isOwnedByThisDevice {
            let directory = RecordingAudioStore.directory(for: meeting.id, root: recordingsRoot)
            if meeting.status == .recording {
                logger.warning("Recovering interrupted recording \(meeting.id.uuidString)")
                let queued = await recover(
                    meeting: meeting,
                    directory: directory,
                    modelContext: modelContext,
                    transcribe: transcribe,
                    applyVocabulary: applyVocabulary
                )
                if queued {
                    await enqueue(meeting.id)
                    outcome.queued.append(meeting.id)
                } else {
                    outcome.failed.append(meeting.id)
                }
                continue
            }

            // Being processed in this launch: its audio belongs to that run.
            if center.progress(for: meeting.id) != nil { continue }

            if needsTranscriptionFromAudio(meeting, recordingsRoot: recordingsRoot) {
                // Stopped, but the transcript was never built from the audio (batch-only
                // engine, a live engine that produced nothing, or a crash mid-transcription).
                // The drain transcribes it from disk, raw tracks included, so don't touch
                // the files here.
                switch meeting.status {
                case .queued, .processing:
                    continue
                case .failed where meeting.processingError == ProcessingRecovery.interruptedNoTranscriptMessage:
                    // Failed by an older build for "no transcript" although audio was saved.
                    meeting.status = .queued
                    meeting.processingError = nil
                    meeting.processingRetryCount = 0
                    try? modelContext.save()
                    await enqueue(meeting.id)
                    outcome.queued.append(meeting.id)
                    continue
                default:
                    break
                }
            }

            if hasRawAudio(in: directory) {
                // Stopped normally, but the app quit before the audio was encoded or before
                // the raw tracks were cleaned up. The transcript is final, so the raw tracks
                // can go once the encoded files check out.
                if let output = try? await finalize(directory: directory, loadSamples: false, keepRawTracks: false) {
                    meeting.audioFilePath = output.audioURL.path
                    try? modelContext.save()
                    outcome.finalizedOrphans.append(meeting.id)
                }
            }
        }
        return outcome
    }

    /// Hands a meeting to the pipeline's deferred processing queue.
    nonisolated static func enqueueForProcessing(_ meetingID: UUID) async {
        await DeferredMeetingProcessingQueue.shared.enqueue(meetingID)
    }

    // MARK: - Recorded audio

    /// Whether a meeting has recorded audio on disk: raw or finished tracks in its recording
    /// directory, or the file `audioFilePath` points to.
    static func hasRecordedAudio(_ meeting: Meeting, recordingsRoot: URL = RecordingAudioStore.defaultRoot) -> Bool {
        if RecordingFinalizer.hasAudio(in: RecordingAudioStore.directory(for: meeting.id, root: recordingsRoot)) {
            return true
        }
        if let path = meeting.audioFilePath, FileManager.default.fileExists(atPath: path) {
            return true
        }
        return false
    }

    /// Whether the meeting's transcript has to be (re)built from its recorded audio before
    /// it can be summarised: it has audio, and either no transcript at all or a transcript
    /// marked partial by an interrupted recovery.
    static func needsTranscriptionFromAudio(_ meeting: Meeting, recordingsRoot: URL = RecordingAudioStore.defaultRoot) -> Bool {
        guard hasRecordedAudio(meeting, recordingsRoot: recordingsRoot) else { return false }
        let directory = RecordingAudioStore.directory(for: meeting.id, root: recordingsRoot)
        if RecordingAudioStore.isTranscriptionPending(in: directory) { return true }
        let edited = meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return meeting.rawTranscript.isEmpty && edited.isEmpty
    }

    /// Transcribes a stopped meeting from its recorded audio and saves the transcript.
    ///
    /// Encodes any raw tracks that are left (keeping them until the transcript is saved),
    /// loads the samples, transcribes them, replaces `rawTranscript` when words came back,
    /// then clears the pending marker and drops the raw tracks. Returns true when words
    /// were produced. Safe to repeat after a crash at any step.
    @discardableResult
    static func transcribeFromRecordedAudio(
        meeting: Meeting,
        recordingsRoot: URL = RecordingAudioStore.defaultRoot,
        modelContext: ModelContext,
        transcribe: Transcriber,
        applyVocabulary: (String) -> String = { $0 }
    ) async -> Bool {
        // The meeting may be deleted during the long awaits below; it's re-fetched by ID
        // before each write.
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        let directory = RecordingAudioStore.directory(for: meetingID, root: recordingsRoot)
        var mic: [Float] = []
        var system: [Float] = []
        var encoded = false

        if RecordingFinalizer.hasAudio(in: directory) {
            do {
                let output = try await finalize(directory: directory, loadSamples: true, keepRawTracks: true)
                guard LiveModel.meetingExists(meetingID, in: home) else { return false }
                meeting.audioFilePath = output.audioURL.path
                if meeting.duration <= 0 { meeting.duration = output.duration }
                try? modelContext.save()
                mic = output.micSamples
                system = output.systemSamples
                encoded = true
            } catch {
                logger.error("Encoding recorded audio for \(meetingID.uuidString) failed: \(error.localizedDescription)")
                // Still transcribe straight from the raw tracks, and keep them.
                mic = (try? await readRaw(directory.appendingPathComponent(RecordingAudioStore.micRawName))) ?? []
                system = (try? await readRaw(directory.appendingPathComponent(RecordingAudioStore.systemRawName))) ?? []
            }
        }
        guard LiveModel.meetingExists(meetingID, in: home) else { return false }
        if mic.isEmpty && system.isEmpty, let path = meeting.audioFilePath, FileManager.default.fileExists(atPath: path) {
            // Only a playable file outside the recording directory; transcribe it as one track.
            let url = URL(fileURLWithPath: path)
            mic = (try? await Task.detached(priority: .userInitiated) { try RecordingFinalizer.readAudioFile(url) }.value) ?? []
            encoded = true
        }
        guard !mic.isEmpty || !system.isEmpty else { return false }

        var words = await transcribe(mic, system)
        guard LiveModel.meetingExists(meetingID, in: home) else { return false }
        for i in words.indices {
            words[i].word = applyVocabulary(words[i].word)
        }
        if !words.isEmpty {
            meeting.rawTranscript = words
        }
        try? modelContext.save()
        RecordingAudioStore.clearTranscriptionPending(in: directory)
        if encoded {
            RecordingFinalizer.discardRawTracks(in: directory)
        }
        return !words.isEmpty
    }

    // MARK: - Interrupted recordings

    /// Returns true when the meeting was queued for processing.
    private static func recover(
        meeting: Meeting,
        directory: URL,
        modelContext: ModelContext,
        transcribe: Transcriber,
        applyVocabulary: (String) -> String
    ) async -> Bool {
        guard RecordingFinalizer.hasAudio(in: directory) else {
            if meeting.rawTranscript.isEmpty {
                markFailed(meeting, message: noAudioMessage, modelContext: modelContext)
                return false
            }
            // The live transcript was saved even though no audio was (older builds, or the
            // audio directory couldn't be created). Summarise what we have.
            meeting.status = .queued
            meeting.processingError = nil
            try? modelContext.save()
            return true
        }

        let output: RecordingFinalizer.Output
        do {
            // Raw tracks stay until the transcript below is saved.
            output = try await finalize(directory: directory, loadSamples: true, keepRawTracks: true)
        } catch {
            markFailed(
                meeting,
                message: "Recording was interrupted and its audio couldn't be recovered: \(error.localizedDescription)",
                modelContext: modelContext
            )
            return false
        }

        meeting.audioFilePath = output.audioURL.path
        if meeting.duration <= 0 {
            meeting.duration = output.duration
        }
        // Whatever live transcript was saved is partial until the recording is transcribed.
        RecordingAudioStore.markTranscriptionPending(in: directory)
        meeting.status = .processing
        try? modelContext.save()

        var words = await transcribe(output.micSamples, output.systemSamples)
        for i in words.indices {
            words[i].word = applyVocabulary(words[i].word)
        }
        if !words.isEmpty {
            // The recording covers the whole meeting and has per-source labels, so it beats
            // whatever part of the live transcript was saved before the crash.
            meeting.rawTranscript = words
        }
        try? modelContext.save()
        RecordingAudioStore.clearTranscriptionPending(in: directory)
        RecordingFinalizer.discardRawTracks(in: directory)

        guard !meeting.rawTranscript.isEmpty else {
            markFailed(meeting, message: noSpeechMessage, modelContext: modelContext)
            return false
        }
        meeting.status = .queued
        meeting.processingError = nil
        try? modelContext.save()
        return true
    }

    private static func markFailed(_ meeting: Meeting, message: String, modelContext: ModelContext) {
        meeting.status = .failed
        meeting.processingError = message
        try? modelContext.save()
    }

    private static func hasRawAudio(in directory: URL) -> Bool {
        let frames = RecordingFinalizer.rawFrames(in: directory)
        return frames.mic > 0 || frames.system > 0
    }

    private static func finalize(directory: URL, loadSamples: Bool, keepRawTracks: Bool) async throws -> RecordingFinalizer.Output {
        try await CaptureService.finalizeRecording(directory: directory, loadSamples: loadSamples, keepRawTracks: keepRawTracks)
    }

    private nonisolated static func readRaw(_ url: URL) async throws -> [Float] {
        guard PCMTrackWriter.frameCount(at: url) > 0 else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try PCMTrackWriter.readSamples(from: url)
        }.value
    }
}
