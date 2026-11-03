import SwiftUI
import SwiftData
import AppKit
import os
import UserNotifications
import Synchronization

@MainActor
@Observable
final class RecordingSession {
    typealias AudioQualityState = CaptureService.AudioQualityState

    private static let logger = Logger(subsystem: "io.lidia.app", category: "RecordingSession")

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var currentMeeting: Meeting?
    /// Final live words, in the order they were finalized (they're only ever appended, so
    /// what's on screen never jumps).
    private(set) var transcriptWords: [TranscriptWord] = []
    /// Each source's current guess for what's being said, refined in place until final.
    private(set) var liveVolatile: [AudioSource: LiveVolatileLine] = [:]
    /// The engine producing live words now (the plan's primary, or its fallback after a
    /// switch). Nil before the first recording.
    private(set) var activeLiveEngine: AppSettings.STTEngineType?

    #if DEBUG
    /// Fixed values for design snapshots of the live page (no capture runs).
    private var snapshotState: (elapsed: TimeInterval, rms: Float, speaking: Set<AudioSource>)?

    /// Shows `meeting` as if it were being recorded, for the snapshot run only.
    func beginSnapshotRecording(
        meeting: Meeting,
        words: [TranscriptWord],
        volatile: [AudioSource: LiveVolatileLine],
        elapsed: TimeInterval,
        speaking: Set<AudioSource> = [],
        paused: Bool = false,
        systemAudioMissing: Bool = false
    ) {
        currentMeeting = meeting
        transcriptWords = words
        liveVolatile = volatile
        isRecording = true
        isPaused = paused
        systemAudioFallbackReason = systemAudioMissing ? "Screen Recording permission is off" : nil
        snapshotState = (elapsed, paused ? 0 : 0.12, speaking)
    }

    func endSnapshotRecording() {
        isRecording = false
        isPaused = false
        currentMeeting = nil
        transcriptWords = []
        liveVolatile = [:]
        systemAudioFallbackReason = nil
        snapshotState = nil
    }
    #endif

    /// Sources someone is speaking on right now (by level), for the typing indicator.
    func speakingSources(threshold: Float = 0.02) -> Set<AudioSource> {
        #if DEBUG
        if let snapshotState { return snapshotState.speaking }
        #endif
        guard isRecording, !isPaused else { return [] }
        let levels = captureService.recentPerSourceRMS()
        var result: Set<AudioSource> = []
        if levels.mic > threshold { result.insert(.mic) }
        if levels.system > threshold { result.insert(.system) }
        return result
    }

    /// Non-nil when an auto-stop is pending confirmation. Shows countdown in the pill.
    private(set) var autoStopCountdown: Int?
    /// Reason for the pending auto-stop (shown in UI).
    private(set) var autoStopReason: String?
    private var autoStopCountdownTask: Task<Void, Never>?

    var elapsedTime: TimeInterval {
        #if DEBUG
        if let snapshotState { return snapshotState.elapsed }
        #endif
        return captureService.elapsedTime
    }

    /// Current audio RMS level for visualization (0.0–1.0 range).
    var currentRMS: Float {
        #if DEBUG
        if let snapshotState { return snapshotState.rms }
        #endif
        return captureService.currentRMS
    }

    /// Minutes past the calendar event's scheduled end time. Nil if no calendar event or not yet past end.
    var calendarOverrunMinutes: Int? {
        guard let endTime = calendarEndTime, isRecording else { return nil }
        let overrun = Date().timeIntervalSince(endTime)
        guard overrun > 0 else { return nil }
        return Int(overrun / 60)
    }

    var activeCaptureMode: AudioCaptureMode {
        captureService.activeCaptureMode
    }

    /// Why system audio isn't being captured in this recording (permission missing, stream
    /// failed), or nil while both sides are captured. Shown as a notification when it happens.
    private(set) var systemAudioFallbackReason: String?

    /// Why live words aren't appearing (engine failed, switched engine, model downloading),
    /// or nil while live transcription is fine. Shown where the live transcript would be.
    var liveTranscriptNotice: String? {
        liveFailureNotice ?? liveDownloadNotice
    }
    private var liveFailureNotice: String?
    private var liveDownloadNotice: String?

    /// Whether this recording's audio is being written to disk (crash-safe).
    var isRecordingAudioToDisk: Bool {
        captureService.isRecordingToDisk
    }

    var captureStatusMessage: String? {
        switch captureService.captureStatus {
        case .healthy:
            return nil
        case .warning(let message), .fallbackToMic(let message), .failed(let message):
            return message
        }
    }

    var audioQualityState: AudioQualityState {
        guard isRecording else { return .good }
        #if DEBUG
        if snapshotState != nil { return .good }
        #endif
        return captureService.audioQualityState
    }

    private let captureService = CaptureService()
    private let transcriptionService = TranscriptionService()
    private let postProcessingService = PostProcessingService()

    /// Whether the meeting is being transcribed, summarised or run through automations now.
    func isProcessing(meetingID: UUID) -> Bool {
        postProcessingService.inFlightMeetingIDs.contains(meetingID)
    }
    private let silenceDetector = SilenceDetector()
    private var sourceEvents: [AudioSourceEvent] = []
    private var recordingStartTime: TimeInterval = 0

    /// Runs capture plus live transcription; its value is every live word of the recording.
    private var recordingTask: Task<[TranscriptWord], Never>?
    /// Identifies the recording whose live words may update `transcriptWords`, so a slow
    /// engine finishing after stop can't leak words into the next recording.
    private var recordingGeneration: UUID?
    /// Interrupted recordings are recovered once per launch (ContentView appears per window).
    private static var hasRecoveredRecordingsThisLaunch = false

    static let nothingCapturedMessage =
        "Nothing was captured: no audio reached LidIA and no words were transcribed. "
        + "Check that a microphone is connected and that LidIA has Microphone access in "
        + "System Settings > Privacy & Security > Microphone."
    private var silenceTask: Task<Void, Never>?
    private var liveSummaryTask: Task<Void, Never>?
    private var autoFinishTask: Task<Void, Never>?
    private var calendarEndTime: Date?

    private var storedModelContext: ModelContext?
    private var storedSettings: AppSettings?
    private var storedEventKitManager: EventKitManager?
    private var storedGoogleCalendarMonitor: GoogleCalendarMonitor?
    private var storedModelManager: ModelManager?
    private var storedMeetingDetector: MeetingDetector?

    /// Separate silence detector for extended (meeting-ended) silence check.
    /// Triggers after 2 minutes of both mic AND system audio being silent.
    private let extendedSilenceDetector = SilenceDetector()
    private var extendedSilenceTask: Task<Void, Never>?
    /// How long both channels must be silent before triggering auto-stop (seconds).
    private let extendedSilenceTimeout: TimeInterval = 60

    private let liveSummaryMaxContextWords = 3_000

    private let panelController = FloatingPanelController()
    private let pillController = RecordingPillController()

    @discardableResult
    func startRecording(modelContext: ModelContext, settings: AppSettings, modelManager: ModelManager? = nil, meetingDetector: MeetingDetector? = nil, eventKitManager: EventKitManager? = nil, googleCalendarMonitor: GoogleCalendarMonitor? = nil, into note: Meeting? = nil) -> Meeting {
        // A note the user just created can start transcribing: its notes stay.
        let meeting: Meeting
        if let note, note.rawTranscript.isEmpty {
            meeting = note
            meeting.status = .recording
            if NoteAutoTitle.isPlaceholder(meeting.title) { meeting.title = "" }
        } else {
            meeting = Meeting(date: .now)
            modelContext.insert(meeting)
        }
        // Persist right away so a crash during the meeting leaves a record to recover.
        try? modelContext.save()
        currentMeeting = meeting
        transcriptWords = []
        liveVolatile = [:]
        activeLiveEngine = nil
        isRecording = true
        systemAudioFallbackReason = nil
        liveFailureNotice = nil
        liveDownloadNotice = nil
        storedModelContext = modelContext
        storedSettings = settings
        storedModelManager = modelManager
        storedMeetingDetector = meetingDetector
        storedEventKitManager = eventKitManager
        storedGoogleCalendarMonitor = googleCalendarMonitor
        silenceDetector.reset()
        extendedSilenceDetector.reset()
        // Cancel any in-flight tasks from a previous recording to prevent leaks
        recordingTask?.cancel()
        recordingTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        autoFinishTask?.cancel()
        autoFinishTask = nil
        extendedSilenceTask?.cancel()
        extendedSilenceTask = nil
        autoStopCountdownTask?.cancel()
        autoStopCountdownTask = nil
        liveSummaryTask?.cancel()
        liveSummaryTask = nil

        // Belongs to a calendar meeting on now or starting within 15 minutes. Blocks of
        // time without anyone invited or a call link don't count: the title then comes
        // from the AI notes instead of, say, "Close-down routine".
        if meeting.calendarEventID == nil {
            var candidates: [RecordingCalendarMatch.Candidate] = []
            if let gcMonitor = googleCalendarMonitor, gcMonitor.isSignedIn {
                candidates += gcMonitor.weekEvents.map {
                    .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, attendees: $0.attendees, hasMeetingLink: $0.meetingLink != nil)
                }
            }
            if let ekManager = eventKitManager {
                candidates += ekManager.upcomingEvents.map {
                    .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, attendees: $0.attendees, hasMeetingLink: $0.meetingLink != nil)
                }
            }
            if let event = RecordingCalendarMatch.pick(candidates, currentUserName: settings.displayName) {
                meeting.title = event.title
                meeting.calendarEventID = event.id
                meeting.calendarAttendees = event.attendees
            }
        }

        // Preload MLX model if using local provider
        if settings.llmProvider == .mlx, let modelManager = storedModelManager {
            Task {
                guard !modelManager.isModelLoaded,
                      !settings.selectedMLXModelID.isEmpty else { return }
                try? await modelManager.loadModel(settings.selectedMLXModelID)
            }
        }

        let factory = transcriptionService.makeFactory(
            settings: settings,
            attendees: AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: settings.displayName)
                .filter { !$0.isCurrentUser }
                .map(\.name)
        )
        let generation = UUID()
        recordingGeneration = generation
        captureService.onFallbackToMic = { [weak self] reason in
            self?.handleSystemAudioFallback(reason)
        }

        recordingTask = Task { [weak self] () -> [TranscriptWord] in
            guard let self else { return [] }
            do {
                try await self.captureService.startCapture(mode: settings.audioCaptureMode, meetingID: meeting.id)
                Self.logger.info("Audio capture started (requested: \(settings.audioCaptureMode.rawValue), active: \(self.captureService.activeCaptureMode.rawValue), to disk: \(self.captureService.isRecordingToDisk))")
                self.recordingStartTime = Date().timeIntervalSince1970
            } catch {
                Self.logger.error("Audio capture failed: \(error.localizedDescription)")
                meeting.status = .failed
                meeting.processingError = error.localizedDescription
                try? modelContext.save()
                self.isRecording = false
                return []
            }

            self.pillController.show(session: self, onStop: { [weak self] in
                guard let self,
                      let ctx = self.storedModelContext,
                      let settings = self.storedSettings else { return }
                self.stopRecording(modelContext: ctx, settings: settings, eventKitManager: self.storedEventKitManager)
            })
            self.startSilenceMonitoring()

            // Always enable auto-finish for all recordings (not just calendar-linked ones).
            // For manual recordings this relies on meeting-app-closed and extended silence signals.
            if let detector = self.storedMeetingDetector, self.autoFinishTask == nil {
                self.enableAutoFinish(calendarEndTime: nil, meetingDetector: detector)
            }

            // Batch-only engines (Granite) produce nothing live; the recording is
            // transcribed from disk when it stops. Still drain the stream so unconsumed
            // chunks don't pile up in memory for the whole meeting.
            guard !factory.isBatchOnly else {
                for await _ in self.captureService.audioStream {
                    self.collectSourceEvents()
                }
                return []
            }

            let separate = self.captureService.activeCaptureMode == .micAndSystem
            let plan = await factory.resolvedLivePlan()
            Self.logger.info("Live STT: \(plan.primary.rawValue, privacy: .public), fallback: \(plan.fallback?.rawValue ?? "none", privacy: .public)")
            if self.recordingGeneration == generation { self.activeLiveEngine = plan.primary }
            if let engine = plan.downloadModelFor {
                self.downloadLiveModel(for: engine, meanwhile: plan.primary == engine ? nil : plan.primary, locale: factory.appleSpeechLocale, generation: generation)
            }
            let events = self.transcriptionService.liveTranscriptionEvents(
                of: self.captureService.audioStream,
                factory: factory,
                plan: plan,
                separateSources: separate,
                timeline: self.captureService.timelineMapper(),
                onEvent: { [weak self] event in
                    Task { @MainActor in
                        self?.handleLiveTranscriptionEvent(event, generation: generation)
                    }
                }
            )
            var collected: [TranscriptWord] = []
            for await laneEvent in events {
                let isCurrent = self.recordingGeneration == generation
                switch laneEvent.event {
                case .finalized(let words):
                    let fixed = words.map { word -> TranscriptWord in
                        var w = word
                        w.word = settings.applyVocabulary(to: w.word)
                        return w
                    }
                    collected += fixed
                    guard isCurrent else { continue }
                    self.collectSourceEvents()
                    self.transcriptWords += fixed
                    self.currentMeeting?.rawTranscript = self.transcriptWords
                case .volatile(let text, let start):
                    guard isCurrent else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.liveVolatile[laneEvent.lane] = nil
                    } else {
                        self.liveVolatile[laneEvent.lane] = LiveVolatileLine(
                            text: settings.applyVocabulary(to: trimmed),
                            start: start,
                            isLocalSpeaker: SourceSeparatedTranscriber.isLocalSpeaker(lane: laneEvent.lane)
                        )
                    }
                }
            }

            Self.logger.info("STT stream ended with \(collected.count) words")
            return collected
        }

        return meeting
    }

    /// Start recording and populate meeting metadata from an Apple Calendar event.
    @discardableResult
    func startRecordingFromEvent(
        _ event: EventKitManager.CalendarEvent,
        modelContext: ModelContext,
        settings: AppSettings,
        modelManager: ModelManager? = nil,
        meetingDetector: MeetingDetector? = nil
    ) -> Meeting {
        let meeting = startRecording(modelContext: modelContext, settings: settings, modelManager: modelManager, meetingDetector: meetingDetector)
        meeting.title = event.title
        meeting.calendarEventID = event.id
        meeting.calendarAttendees = event.attendees
        if let detector = meetingDetector {
            enableAutoFinish(calendarEndTime: event.end, meetingDetector: detector)
        }
        return meeting
    }

    /// Start recording and populate meeting metadata from a Google Calendar event.
    @discardableResult
    func startRecordingFromGoogleEvent(
        _ event: GoogleCalendarClient.CalendarEvent,
        notes: String = "",
        modelContext: ModelContext,
        settings: AppSettings,
        modelManager: ModelManager? = nil,
        meetingDetector: MeetingDetector? = nil
    ) -> Meeting {
        let meeting = startRecording(modelContext: modelContext, settings: settings, modelManager: modelManager, meetingDetector: meetingDetector)
        meeting.title = event.title
        meeting.calendarEventID = event.id
        meeting.calendarAttendees = event.attendees
        if !notes.isEmpty {
            meeting.notes = notes
        }
        if let detector = meetingDetector {
            enableAutoFinish(calendarEndTime: event.end, meetingDetector: detector)
        }
        return meeting
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        captureService.pauseCapture()
        Self.logger.info("Recording paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        isPaused = false
        captureService.resumeCapture()
        Self.logger.info("Recording resumed")
    }

    func enableAutoFinish(calendarEndTime: Date?, meetingDetector: MeetingDetector) {
        self.calendarEndTime = calendarEndTime
        self.storedMeetingDetector = meetingDetector
        autoFinishTask?.cancel()

        // Start window/process-based active monitoring on MeetingDetector.
        // This supplements the CoreAudio listener which is masked by LidIA's own recording.
        meetingDetector.startActiveMonitoring()

        // Watch for meeting app going inactive via polling
        autoFinishTask = Task { [weak self] in
            guard let self else { return }

            // Poll MeetingDetector every 5 seconds for inactive signal
            while !Task.isCancelled && self.isRecording {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.isRecording else { return }

                if meetingDetector.meetingAppBecameInactive {
                    meetingDetector.meetingAppBecameInactive = false
                    Self.logger.info("Meeting app became inactive, starting 15s grace period")

                    // Grace period
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, self.isRecording else { return }

                    // Check if still inactive
                    if meetingDetector.detectedApp == nil {
                        Self.logger.info("Auto-stop requested: meeting app inactive for 15s")
                        self.requestAutoStop(reason: "Meeting app closed")
                        return
                    } else {
                        Self.logger.info("Meeting app reactivated, cancelling auto-finish")
                    }
                }
            }
        }

        // Start extended silence monitoring (2+ min of both mic AND system silence)
        startExtendedSilenceMonitoring()
    }

    /// Start a 30-second countdown before auto-stopping. The user can cancel via `cancelAutoStop()`.
    /// Audio-alive suppression: if either channel has audio above threshold, the auto-stop is suppressed.
    /// During countdown, audio is re-checked each second — countdown cancels if audio resumes.
    private func requestAutoStop(reason: String) {
        guard autoStopCountdown == nil else { return } // Already pending

        // Audio-alive suppression: if either channel has audio, don't auto-stop
        let perSource = captureService.recentPerSourceRMS()
        let aliveThreshold: Float = 0.01
        if perSource.mic > aliveThreshold || perSource.system > aliveThreshold {
            Self.logger.info("Auto-stop suppressed: audio still active (mic=\(perSource.mic), system=\(perSource.system))")
            return
        }

        Self.logger.info("Auto-stop requested: \(reason) — starting 30s countdown")
        autoStopReason = reason
        autoStopCountdown = 30

        autoStopCountdownTask?.cancel()
        autoStopCountdownTask = Task { [weak self] in
            for remaining in stride(from: 29, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRecording else { return }

                // Re-check audio each second — cancel countdown if audio resumes
                let currentRMS = self.captureService.recentPerSourceRMS()
                if currentRMS.mic > aliveThreshold || currentRMS.system > aliveThreshold {
                    Self.logger.info("Auto-stop cancelled: audio resumed during countdown")
                    self.cancelAutoStop()
                    return
                }

                self.autoStopCountdown = remaining
            }

            // Countdown reached zero — stop for real
            guard let self, self.isRecording else { return }
            self.confirmAutoStop()
        }
    }

    /// User chose to keep recording — cancel the pending auto-stop.
    func cancelAutoStop() {
        Self.logger.info("Auto-stop cancelled by user")
        autoStopCountdownTask?.cancel()
        autoStopCountdownTask = nil
        autoStopCountdown = nil
        autoStopReason = nil
    }

    /// Immediately stop recording (from countdown expiry or explicit confirm).
    func confirmAutoStop() {
        autoStopCountdownTask?.cancel()
        autoStopCountdownTask = nil
        autoStopCountdown = nil
        autoStopReason = nil

        guard let ctx = storedModelContext, let settings = storedSettings else { return }

        Task {
            let content = UNMutableNotificationContent()
            content.title = "Meeting Ended"
            content.body = "Recording stopped — processing your transcript"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "lidia.autofinish.\(currentMeeting?.id.uuidString ?? "")",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }

        stopRecording(modelContext: ctx, settings: settings, eventKitManager: storedEventKitManager)
    }

    func stopRecording(modelContext: ModelContext, settings: AppSettings, eventKitManager: EventKitManager? = nil) {
        autoFinishTask?.cancel()
        autoFinishTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        extendedSilenceTask?.cancel()
        extendedSilenceTask = nil
        liveSummaryTask?.cancel()
        liveSummaryTask = nil
        autoStopCountdownTask?.cancel()
        autoStopCountdownTask = nil
        autoStopCountdown = nil
        autoStopReason = nil
        silenceDetector.reset()
        extendedSilenceDetector.reset()

        // Stop window/process-based active monitoring
        storedMeetingDetector?.stopActiveMonitoring()
        storedMeetingDetector = nil

        let stop = captureService.stopCapture()
        sourceEvents.append(contentsOf: stop.sourceEvents)
        let wasSeparated = captureService.activeCaptureMode == .micAndSystem

        // === DIAGNOSTIC: Audio capture analysis ===
        let micDuration = Double(stop.recordedMicFrames + Int64(stop.inMemoryMic.count)) / 16000.0
        let sysDuration = Double(stop.recordedSystemFrames + Int64(stop.inMemorySystem.count)) / 16000.0
        let micEvents = sourceEvents.filter { $0.source == .mic }
        let sysEvents = sourceEvents.filter { $0.source == .system }
        let avgMicRMS = micEvents.isEmpty ? 0 : micEvents.map(\.rms).reduce(0, +) / Float(micEvents.count)
        let avgSysRMS = sysEvents.isEmpty ? 0 : sysEvents.map(\.rms).reduce(0, +) / Float(sysEvents.count)
        let wordCount = self.transcriptWords.count
        let localTrue = self.transcriptWords.filter { $0.isLocalSpeaker == true }.count
        let localFalse = self.transcriptWords.filter { $0.isLocalSpeaker == false }.count
        let localNil = self.transcriptWords.filter { $0.isLocalSpeaker == nil }.count
        Self.logger.warning("""
            📊 AUDIO CAPTURE DIAGNOSTIC:
            Capture mode: \(wasSeparated ? "Mic+System" : "Mic Only")
            Recorded to disk: \(stop.recordingDirectory != nil)
            Mic audio: \(String(format: "%.1f", micDuration))s
            System audio: \(String(format: "%.1f", sysDuration))s
            Source events: \(micEvents.count) mic, \(sysEvents.count) system
            Avg RMS: mic=\(String(format: "%.4f", avgMicRMS)), system=\(String(format: "%.4f", avgSysRMS))
            Live words captured: \(wordCount)
            Words with isLocalSpeaker=true: \(localTrue)
            Words with isLocalSpeaker=false: \(localFalse)
            Words with isLocalSpeaker=nil: \(localNil)
            """)
        // === END DIAGNOSTIC ===

        // Don't cancel live transcription: the capture stream has ended, so the engines are
        // finishing their last words. The post-processing task below waits for them.
        let liveTask = recordingTask
        recordingTask = nil
        recordingGeneration = nil
        let liveSnapshot = transcriptWords
        let liveEngine = activeLiveEngine
        liveVolatile = [:]
        liveFailureNotice = nil
        liveDownloadNotice = nil
        isRecording = false
        isPaused = false
        storedModelContext = nil
        storedSettings = nil
        storedEventKitManager = eventKitManager
        let capturedModelManager = storedModelManager
        storedModelManager = nil

        // Free MLX model memory after post-processing completes (see Task below)
        // Model will be re-loaded on next recording start if needed
        pillController.close()

        guard let meeting = currentMeeting else {
            liveTask?.cancel()
            return
        }
        // Save through the meeting's own context. A recording started from a notification
        // or a banner lives in another context than the window that stops it, and the
        // task below keeps that context alive while it processes the meeting.
        let context = meeting.modelContext ?? modelContext
        let meetingID = meeting.id
        meeting.duration = captureService.elapsedTime
        meeting.rawTranscript = Self.finalLiveTranscript(liveSnapshot, separated: wasSeparated, meetingDuration: meeting.duration)

        let factory = transcriptionService.makeFactory(settings: settings)
        if meeting.rawTranscript.isEmpty && !stop.hasAudio {
            // Nothing to reprocess: no words and no audio on disk or in memory.
            liveTask?.cancel()
            if let directory = stop.recordingDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
            meeting.status = .failed
            meeting.processingError = Self.nothingCapturedMessage
            try? context.save()
            currentMeeting = nil
            return
        }

        meeting.status = .processing
        try? context.save()
        if meeting.userEditedSummary?.isEmpty != false {
            meeting.summary = ""
            startPostProcessingLiveSummary(meeting: meeting, settings: settings)
        }

        let eventsSnapshot = sourceEvents
        Task { [weak self] in
            // Free MLX model memory once post-processing is done (or abandoned).
            defer { capturedModelManager?.unloadModel() }
            // 1. Let the live engines flush their final words (bounded wait).
            if let liveTask {
                let finalWords = await Self.value(of: liveTask, timeout: .seconds(20))
                guard LiveModel.meetingExists(meetingID, in: context) else { return }
                if let finalWords, finalWords.count > liveSnapshot.count {
                    meeting.rawTranscript = Self.finalLiveTranscript(finalWords, separated: wasSeparated, meetingDuration: meeting.duration)
                }
            }

            // 2. Encode the recorded audio and attach the playable file. The raw tracks stay
            //    on disk until the transcript is saved, so a crash while transcribing can
            //    start again from them (ProcessingRecovery requeues the meeting and the
            //    drain re-transcribes it).
            var micSamples = stop.inMemoryMic
            var systemSamples = stop.inMemorySystem
            var rawTracksDirectory: URL?
            if let directory = stop.recordingDirectory {
                let needsSamples = factory.needsRecordedSamples || meeting.rawTranscript.isEmpty || settings.enableDiarization
                do {
                    let output = try await CaptureService.finalizeRecording(
                        directory: directory,
                        loadSamples: needsSamples,
                        keepRawTracks: true
                    )
                    guard LiveModel.meetingExists(meetingID, in: context) else { return }
                    meeting.audioFilePath = output.audioURL.path
                    rawTracksDirectory = directory
                    if needsSamples {
                        micSamples = output.micSamples
                        systemSamples = output.systemSamples
                    }
                    try? context.save()
                } catch {
                    // The raw tracks stay; the next launch's recovery encodes them again.
                    Self.logger.error("Finalizing recorded audio failed: \(error.localizedDescription)")
                }
            }

            guard LiveModel.meetingExists(meetingID, in: context) else { return }
            // 3. A live engine that produced nothing (crashed, unauthorised, model failed to
            //    load): transcribe the recording instead of summarising an empty transcript.
            if meeting.rawTranscript.isEmpty && !factory.needsRecordedSamples && (!micSamples.isEmpty || !systemSamples.isEmpty) {
                Self.logger.info("No live transcript; transcribing the recorded audio")
                var words = await TranscriptionService.transcribeRecorded(
                    mic: micSamples,
                    system: systemSamples,
                    factory: factory,
                    vocabulary: settings.customVocabulary
                )
                guard LiveModel.meetingExists(meetingID, in: context) else { return }
                for i in words.indices {
                    words[i].word = settings.applyVocabulary(to: words[i].word)
                }
                meeting.rawTranscript = words
                try? context.save()
            }

            guard let self, LiveModel.meetingExists(meetingID, in: context) else { return }
            // Apple's live transcript is kept as the final one (see
            // `liveTranscriptIsFinal`); the batch engines re-transcribe otherwise.
            let keepLive = STTEngineFactory.liveTranscriptIsFinal(engine: liveEngine) && !meeting.rawTranscript.isEmpty
            let reTranscribe = factory.needsRecordedSamples && !keepLive
            await self.postProcessingService.processAfterCapture(
                meeting: meeting,
                micSamples: reTranscribe || settings.enableDiarization ? micSamples : [],
                systemSamples: reTranscribe || settings.enableDiarization ? systemSamples : [],
                reTranscribe: reTranscribe,
                sourceEvents: eventsSnapshot,
                modelContext: context,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: capturedModelManager,
                rawTracksDirectory: rawTracksDirectory
            )
        }

        sourceEvents.removeAll()
        currentMeeting = nil
    }

    /// Normalises live words into the stored transcript. With separate mic/system lanes,
    /// mic words that merely echo the other side (no headphones) are dropped.
    private static func finalLiveTranscript(_ words: [TranscriptWord], separated: Bool, meetingDuration: TimeInterval) -> [TranscriptWord] {
        var merged = words
        if separated {
            let mic = words.filter { $0.isLocalSpeaker == true }
            let system = words.filter { $0.isLocalSpeaker == false }
            let unlabelled = words.filter { $0.isLocalSpeaker == nil }
            merged = SpeakerStreamMerger.merge(mic: mic, system: system) + unlabelled
        }
        return normalizeWordTimings(merged, meetingDuration: meetingDuration)
    }

    /// Awaits a task's value, cancelling it after `timeout` and returning whatever it
    /// produced by then.
    private static func value<T: Sendable>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { task.cancel() }
                return nil
            }
            var result: T?
            for await value in group {
                if let value {
                    result = value
                    group.cancelAll()
                }
            }
            return result
        }
    }

    private func handleSystemAudioFallback(_ reason: String) {
        guard isRecording, systemAudioFallbackReason == nil else { return }
        systemAudioFallbackReason = reason
        Self.logger.warning("Recording mic-only: \(reason)")
        let meetingID = currentMeeting?.id.uuidString ?? ""
        Task {
            let content = UNMutableNotificationContent()
            content.title = "Recording microphone only"
            content.body = reason
            let request = UNNotificationRequest(
                identifier: "lidia.capture.miconly.\(meetingID)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Shows why live words aren't appearing, and notifies once per recording when the
    /// engine fails or is switched (the meeting page may not be on screen).
    private func handleLiveTranscriptionEvent(_ event: LiveTranscriptionEvent, generation: UUID) {
        guard isRecording, recordingGeneration == generation else { return }
        switch event {
        case .downloadingModel:
            liveDownloadNotice = event.message
        case .modelReady:
            liveDownloadNotice = nil
        case .switchedEngine, .unavailable:
            if case let .switchedEngine(_, to, _) = event { activeLiveEngine = to }
            if case .unavailable = event { activeLiveEngine = nil }
            Self.logger.warning("Live transcription: \(event.message, privacy: .public)")
            let alreadyNotified = liveFailureNotice != nil
            liveFailureNotice = event.message
            guard !alreadyNotified else { return }
            let meetingID = currentMeeting?.id.uuidString ?? ""
            let body = event.message
            Task {
                let content = UNMutableNotificationContent()
                content.title = "Live transcript"
                content.body = body
                let request = UNNotificationRequest(
                    identifier: "lidia.capture.livestt.\(meetingID)",
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }

    /// Downloads the live model in the background, with progress in the live notice.
    private func downloadLiveModel(
        for engine: AppSettings.STTEngineType,
        meanwhile: AppSettings.STTEngineType?,
        locale: Locale,
        generation: UUID
    ) {
        if engine == .appleSpeech {
            // macOS downloads its speech model (a shared system asset); the next
            // recording uses it.
            handleLiveTranscriptionEvent(.downloadingModel(engine: engine, fraction: nil, meanwhile: meanwhile), generation: generation)
            Task { [weak self] in
                do {
                    try await SpeechAnalyzerEngine.installModel(for: locale)
                    self?.handleLiveTranscriptionEvent(.modelReady(engine: engine), generation: generation)
                } catch {
                    Self.logger.error("Speech model download failed: \(error.localizedDescription, privacy: .public)")
                    self?.liveDownloadNotice = nil
                }
            }
            return
        }
        guard engine == .parakeet else { return }
        handleLiveTranscriptionEvent(.downloadingModel(engine: engine, fraction: nil, meanwhile: meanwhile), generation: generation)
        Task { [weak self] in
            let lastPercent = Mutex(-1)
            do {
                // Shared with ParakeetEngine's own load, so the model downloads once.
                try await ParakeetLiveModelDownloader.shared.ensureDownloaded { fraction in
                    let percent = Int(fraction * 100)
                    let changed = lastPercent.withLock { last in
                        guard percent != last else { return false }
                        last = percent
                        return true
                    }
                    guard changed else { return }
                    Task { @MainActor in
                        self?.handleLiveTranscriptionEvent(
                            .downloadingModel(engine: engine, fraction: fraction, meanwhile: meanwhile),
                            generation: generation
                        )
                    }
                }
                self?.handleLiveTranscriptionEvent(.modelReady(engine: engine), generation: generation)
            } catch {
                Self.logger.error("Live model download failed: \(error.localizedDescription, privacy: .public)")
                self?.liveDownloadNotice = nil
            }
        }
    }

    func resumeQueuedProcessing(modelContext: ModelContext, settings: AppSettings, eventKitManager: EventKitManager?, modelManager: ModelManager? = nil) {
        storedModelContext = modelContext
        storedSettings = settings
        storedEventKitManager = eventKitManager
        storedModelManager = modelManager

        postProcessingService.startQueueDrainLoop { [weak self] in
            guard let self,
                  !self.isRecording,
                  let context = self.storedModelContext,
                  let settings = self.storedSettings else {
                return nil
            }
            return (context, settings, self.storedEventKitManager, self.storedModelManager)
        }

        Task {
            await recoverInterruptedRecordings(modelContext: modelContext, settings: settings)
            await postProcessingService.drainQueuedMeetings(
                modelContext: modelContext,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: modelManager
            )
        }
    }

    /// Retries a meeting that has recorded audio but no transcript (for example one failed
    /// with "nothing to summarize" after a crash): queues it so the drain transcribes the
    /// recording and then summarises it. Returns false when there is no audio to use.
    @discardableResult
    func retryFromRecordedAudio(
        _ meeting: Meeting,
        modelContext: ModelContext,
        settings: AppSettings,
        eventKitManager: EventKitManager?,
        modelManager: ModelManager? = nil
    ) -> Bool {
        guard meeting.status != .recording,
              RecordingRecovery.needsTranscriptionFromAudio(meeting) else { return false }
        // Already being transcribed or processed in this launch.
        if meeting.status == .processing || postProcessingService.inFlightMeetingIDs.contains(meeting.id) { return true }
        meeting.status = .queued
        meeting.processingError = nil
        meeting.processingRetryCount = 0
        try? modelContext.save()
        let id = meeting.id
        Task {
            await DeferredMeetingProcessingQueue.shared.enqueue(id)
            resumeQueuedProcessing(
                modelContext: modelContext,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: modelManager
            )
        }
        return true
    }

    /// Finishes meetings left in `.recording` by a crash or force-quit: finalises their audio
    /// from disk, transcribes it and queues them for the normal processing pipeline.
    /// Runs once per launch, next to the pipeline's `ProcessingRecovery` (which handles
    /// `.processing` / `.queued` meetings and leaves `.recording` ones to this).
    func recoverInterruptedRecordings(modelContext: ModelContext, settings: AppSettings) async {
        guard !Self.hasRecoveredRecordingsThisLaunch else { return }
        Self.hasRecoveredRecordingsThisLaunch = true

        let factory = transcriptionService.makeFactory(settings: settings)
        let vocabulary = settings.customVocabulary
        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: modelContext,
            excluding: currentMeeting?.id,
            transcribe: { mic, system in
                await TranscriptionService.transcribeRecorded(mic: mic, system: system, factory: factory, vocabulary: vocabulary)
            },
            applyVocabulary: { settings.applyVocabulary(to: $0) }
        )
        if !outcome.queued.isEmpty || !outcome.failed.isEmpty {
            Self.logger.warning("Recovered interrupted recordings: \(outcome.queued.count) queued, \(outcome.failed.count) failed")
        }
    }

    // MARK: - Source Events

    /// Moves RMS events from the capture service into `sourceEvents`, keeping the last 30 s.
    /// Speaker labels now come from the separate mic/system transcription lanes.
    private func collectSourceEvents() {
        let newEvents = captureService.drainSourceEvents()
        sourceEvents.append(contentsOf: newEvents)
        let cutoff = (sourceEvents.last?.timestamp ?? 0) - 30
        sourceEvents.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - Silence Monitoring

    private func startSilenceMonitoring() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      let self,
                      self.isRecording,
                      let settings = self.storedSettings,
                      settings.autoStopOnSilence else { continue }

                let rms = self.captureService.currentRMS
                let exceeded = self.silenceDetector.update(
                    rms: rms,
                    timeout: settings.silenceTimeoutSeconds
                )
                if exceeded {
                    Self.logger.info("Auto-stop requested: silence timeout (\(settings.silenceTimeoutSeconds)s)")
                    self.requestAutoStop(reason: "Silence detected")
                    return
                }
            }
        }
    }

    // MARK: - Extended Silence Monitoring (Meeting-End Detection)

    /// Monitors for prolonged silence on BOTH mic and system audio simultaneously.
    /// Unlike the regular silence detector (which catches brief pauses), this detects
    /// when the call has truly ended — both sides silent for 2+ minutes.
    private func startExtendedSilenceMonitoring() {
        extendedSilenceTask?.cancel()
        extendedSilenceDetector.reset()

        extendedSilenceTask = Task { [weak self] in
            // Track how long both channels have been simultaneously silent
            var bothSilentSince: Date?

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled,
                      let self,
                      self.isRecording else { return }

                let perSource = self.captureService.recentPerSourceRMS()
                let silenceThreshold: Float = 0.01

                let micSilent = perSource.mic < silenceThreshold
                let systemSilent = perSource.system < silenceThreshold

                if micSilent && systemSilent {
                    if bothSilentSince == nil {
                        bothSilentSince = Date()
                        Self.logger.debug("Extended silence: both channels silent — tracking started")
                    }

                    let duration = Date().timeIntervalSince(bothSilentSince!)
                    if duration >= self.extendedSilenceTimeout {
                        Self.logger.info("Auto-stop requested: extended silence (\(Int(duration))s on both channels)")
                        self.requestAutoStop(reason: "Extended silence — meeting may have ended")
                        return
                    }
                } else {
                    if bothSilentSince != nil {
                        Self.logger.debug("Extended silence: audio resumed after \(Int(Date().timeIntervalSince(bothSilentSince!)))s")
                        bothSilentSince = nil
                    }
                }
            }
        }
    }

    // MARK: - Live Summary

    private func startPostProcessingLiveSummary(meeting: Meeting, settings: AppSettings) {
        liveSummaryTask?.cancel()
        let meetingID = meeting.id
        let home = meeting.modelContext
        liveSummaryTask = Task { [weak self] in
            guard let self, let home, LiveModel.meetingExists(meetingID, in: home) else { return }
            guard meeting.status == .processing else { return }
            guard meeting.userEditedSummary?.isEmpty != false else { return }

            let transcriptSnippet = buildLiveSummaryTranscript(from: meeting.rawTranscript)
            guard !transcriptSnippet.isEmpty else { return }

            let model = effectiveModel(for: .summary, settings: settings, taskType: .summarization)
            guard !model.isEmpty else { return }

            await streamLiveSummaryDraft(
                meeting: meeting,
                transcriptSnippet: transcriptSnippet,
                settings: settings,
                model: model
            )
        }
    }

    private func buildLiveSummaryTranscript(from words: [TranscriptWord]) -> String {
        guard !words.isEmpty else { return "" }
        let excerptWords: [TranscriptWord]
        if words.count <= liveSummaryMaxContextWords {
            excerptWords = words
        } else {
            let headCount = Int(Double(liveSummaryMaxContextWords) * 0.6)
            let tailCount = liveSummaryMaxContextWords - headCount
            excerptWords = Array(words.prefix(headCount)) + Array(words.suffix(tailCount))
        }
        return excerptWords.map(\.word).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func streamLiveSummaryDraft(
        meeting: Meeting,
        transcriptSnippet: String,
        settings: AppSettings,
        model: String
    ) async {
        let llm = makeLLMClient(settings: settings, modelManager: storedModelManager, taskType: .summarization)
        let existing = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked before each write: the stream outlives awaits, and the meeting can be
        // deleted (or finish processing) meanwhile.
        let meetingID = meeting.id
        let home = meeting.modelContext
        func stillProcessing() -> Bool {
            guard let home, LiveModel.meetingExists(meetingID, in: home) else { return false }
            return meeting.status == .processing
        }

        let systemPrompt = """
        You are generating a LIVE meeting summary while the call is still in progress.
        Return concise markdown with:
        - A short overview paragraph
        - 3-8 bullet points for key updates
        - Optional section "Open Questions" when unresolved items appear
        Keep it factual, avoid inventing details, and improve the draft incrementally as new transcript arrives.
        Do not mention that you are an AI.
        """

        var userPrompt = "Meeting title: \(meeting.title.isEmpty ? "Untitled Meeting" : meeting.title)\n\n"
        if !existing.isEmpty {
            userPrompt += "Current draft summary:\n\(existing)\n\n"
        }
        userPrompt += """
        Latest transcript excerpt:
        \(transcriptSnippet)
        """

        let messages: [LLMChatMessage] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: userPrompt),
        ]

        var streamed = ""
        var lastUIRefresh = Date.distantPast

        do {
            for try await token in await llm.chatStream(messages: messages, model: model) {
                if Task.isCancelled {
                    return
                }
                streamed += token

                if Date().timeIntervalSince(lastUIRefresh) > 0.15 {
                    guard stillProcessing() else { return }
                    let draft = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !draft.isEmpty {
                        meeting.summary = draft
                    }
                    lastUIRefresh = .now
                }
            }

            let finalDraft = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalDraft.isEmpty, stillProcessing() {
                meeting.summary = finalDraft
            }
        } catch {
            Self.logger.debug("Live summary refresh skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Floating Panel

    private func showFloatingPanel() {
        let view = FloatingTranscriptView(
            session: self,
            onClose: { [weak self] in
                self?.hideFloatingPanel()
            }
        )
        panelController.show(rootView: view)
    }

    func hideFloatingPanel() {
        panelController.close()
    }

    static func normalizeWordTimings(_ words: [TranscriptWord], meetingDuration: TimeInterval) -> [TranscriptWord] {
        guard !words.isEmpty else { return [] }
        var normalized = words

        if let minStart = normalized.map(\.start).min() {
            let looksEpochBased = minStart > max(10_000, meetingDuration + 60)
            if looksEpochBased {
                for i in normalized.indices {
                    normalized[i].start -= minStart
                    normalized[i].end -= minStart
                }
            }
        }

        // If timing is unusable (all zero/negative), synthesize an even timeline.
        let hasUsefulTiming = normalized.contains { $0.end > $0.start || $0.start > 0.01 }
        if !hasUsefulTiming {
            let total = meetingDuration > 1 ? meetingDuration : max(1, Double(normalized.count) * 0.25)
            let step = total / Double(max(1, normalized.count))
            for i in normalized.indices {
                normalized[i].start = Double(i) * step
                normalized[i].end = Double(i + 1) * step
            }
        }

        for i in normalized.indices {
            if normalized[i].start < 0 { normalized[i].start = 0 }
            if normalized[i].end < normalized[i].start {
                normalized[i].end = normalized[i].start + 0.05
            }
        }

        return normalized.sorted { $0.start < $1.start }
    }
}
