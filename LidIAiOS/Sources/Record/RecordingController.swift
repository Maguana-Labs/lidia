@preconcurrency import AVFoundation
import Foundation
import LidIAAppIntents
import LidIAKit
import Observation
import SwiftData
import UIKit
import os

/// One recording, from tap to notes: microphone → file on disk + live
/// transcript → meeting in the library → notes on this iPhone.
@MainActor
@Observable
final class RecordingController {
    /// For App Intents, which run outside the view hierarchy.
    static weak var current: RecordingController?

    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case finishing
        case processing
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .recording, .paused, .finishing: true
            default: false
            }
        }
    }

    struct Draft: Equatable {
        var title = ""
        var attendees: [String] = []
        var calendarEventID: String?
        var joinURL: URL?
    }

    private static let logger = Logger(subsystem: "io.lidia.ios", category: "Recording")

    // Observed state
    private(set) var phase: Phase = .idle
    private(set) var meetingID: UUID?
    private(set) var segments: [LiveTranscriber.Segment] = []
    private(set) var volatileText = ""
    private(set) var levels: [Float] = Array(repeating: 0, count: 56)
    private(set) var transcriberNote: String?
    private(set) var moments: [TimeInterval] = []
    /// Lines said to Siri during the recording ("Add Note to Live Meeting"), with the time.
    private(set) var spokenNotes: [(at: TimeInterval, text: String)] = []
    var draft = Draft()

    // Timing: accumulated + (now - segmentStart) while recording.
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?

    // Machinery
    private let container: ModelContainer
    private let settings: AppSettings
    private let processor: MeetingProcessor
    private let liveActivity = LiveActivityController()
    private var capture: AudioCapture?
    private var transcriber: LiveTranscriber?
    private var eventsTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var interruptedWhileRecording = false
    private var startedAt = Date.now
    private var demoIndex = 0

    /// DEBUG demo builds simulate the microphone and transcript.
    var demoScript: [String]?

    init(container: ModelContainer, settings: AppSettings, processor: MeetingProcessor) {
        self.container = container
        self.settings = settings
        self.processor = processor
        RecordingIntentBridge.handler = { [weak self] command in
            guard let self, self.isLive else { return false }
            switch command {
            case .pause: self.pause()
            case .resume: self.resume()
            case .stop: self.stop()
            case .bookmark: self.markMoment()
            case .note(let text): self.addNote(text)
            }
            return true
        }
        observeSession()
    }

    // MARK: - Derived

    func elapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (segmentStart.map { date.timeIntervalSince($0) } ?? 0)
    }

    var isLive: Bool { phase == .recording || phase == .paused }

    var displayTitle: String {
        draft.title.isEmpty ? "New recording" : draft.title
    }

    var lastLine: String {
        if !volatileText.isEmpty { return volatileText }
        return segments.last?.text ?? ""
    }

    var meeting: Meeting? {
        guard let meetingID else { return nil }
        return Self.fetch(meetingID, in: container.mainContext)
    }

    // MARK: - Commands

    func start() async {
        guard !phase.isActive else { return }
        SiriDonations.donate(StartRecordingIntent())
        phase = .preparing
        segments = []
        volatileText = ""
        moments = []
        spokenNotes = []
        accumulated = 0
        transcriberNote = nil
        startedAt = .now

        if demoScript == nil {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                phase = .failed("LidIA needs the microphone to record. Turn it on in Settings → Privacy → Microphone.")
                return
            }
        }

        let id = UUID()
        let url = AudioStorage.newRecordingURL(id: id)
        let context = container.mainContext
        let meeting = Meeting(
            title: draft.title,
            date: .now,
            status: .recording,
            audioFilePath: demoScript == nil ? AudioStorage.storedPath(for: url) : nil,
            calendarEventID: draft.calendarEventID,
            calendarAttendees: draft.attendees.isEmpty ? nil : draft.attendees
        )
        meeting.id = id
        context.insert(meeting)
        try? context.save()
        meetingID = id

        if let demoScript {
            startDemo(script: demoScript)
        } else {
            do {
                try AudioCapture.activateSession()
                let transcriber = LiveTranscriber(locale: settings.transcriptionLocale, contextualStrings: draft.attendees)
                self.transcriber = transcriber
                let capture = AudioCapture(
                    onBuffer: { [weak transcriber] buffer in transcriber?.append(buffer) },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.push(level: level) }
                    }
                )
                try capture.start(writingTo: url)
                self.capture = capture
                startTranscriber(transcriber)
            } catch {
                Self.logger.error("Start failed: \(error.localizedDescription, privacy: .public)")
                capture?.stop()
                AudioCapture.deactivateSession()
                context.delete(meeting)
                try? context.save()
                meetingID = nil
                phase = .failed(error.localizedDescription)
                return
            }
        }

        segmentStart = .now
        phase = .recording
        UIApplication.shared.isIdleTimerDisabled = true
        Haptics.heavy()
        if settings.showLiveActivity {
            liveActivity.start(title: displayTitle, meetingID: id, state: activityState())
        }
    }

    func pause() {
        guard phase == .recording else { return }
        accumulated = elapsed()
        segmentStart = nil
        capture?.setPaused(true)
        phase = .paused
        Haptics.firm()
        liveActivity.update(activityState())
    }

    func resume() {
        guard phase == .paused else { return }
        segmentStart = .now
        capture?.setPaused(false)
        phase = .recording
        Haptics.firm()
        liveActivity.update(activityState())
    }

    func markMoment() {
        guard isLive else { return }
        moments.append(elapsed())
        Haptics.tap()
    }

    /// A line for the notes, stamped with the recording time.
    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLive, !trimmed.isEmpty else { return }
        spokenNotes.append((elapsed(), trimmed))
        Haptics.tap()
    }

    func stop() {
        guard isLive else { return }
        SiriDonations.donate(StopRecordingIntent())
        accumulated = elapsed()
        segmentStart = nil
        phase = .finishing
        Haptics.success()
        UIApplication.shared.isIdleTimerDisabled = false
        liveActivity.update(activityState(phase: .saving))

        Task {
            demoTask?.cancel()
            capture?.stop()
            capture = nil
            await transcriber?.finish()
            await eventsTask?.value
            transcriber = nil
            AudioCapture.deactivateSession()
            finishMeeting()
        }
    }

    /// Throws the recording away (from the confirmation dialog).
    func discard() {
        demoTask?.cancel()
        capture?.stop()
        capture = nil
        transcriber?.cancel()
        transcriber = nil
        eventsTask?.cancel()
        AudioCapture.deactivateSession()
        UIApplication.shared.isIdleTimerDisabled = false
        if let meeting {
            if let url = meeting.audioURL { try? FileManager.default.removeItem(at: url) }
            container.mainContext.delete(meeting)
            try? container.mainContext.save()
        }
        liveActivity.end(activityState(phase: .saved), after: 0)
        reset()
    }

    /// Back to idle after the user leaves the finished screen.
    func reset() {
        phase = .idle
        meetingID = nil
        segments = []
        volatileText = ""
        moments = []
        spokenNotes = []
        accumulated = 0
        segmentStart = nil
        levels = Array(repeating: 0, count: levels.count)
        draft = Draft()
    }

    /// Called by the processor when notes are done, to close the Live Activity.
    func notesFinished(for id: UUID, succeeded: Bool) {
        guard id == meetingID else { return }
        liveActivity.end(activityState(phase: .saved))
    }

    // MARK: - Transcript

    private func startTranscriber(_ transcriber: LiveTranscriber) {
        eventsTask = Task { [weak self] in
            do {
                let events = try await transcriber.start()
                for await event in events {
                    self?.handle(event)
                }
            } catch {
                self?.transcriberNote = error.localizedDescription
            }
        }
    }

    private func handle(_ event: LiveTranscriber.Event) {
        switch event {
        case .volatile(let text):
            volatileText = text
        case .finalized(let segment):
            segments.append(segment)
            persistTranscript(force: false)
        case .failed(let message):
            transcriberNote = "Live transcript stopped: \(message). The audio is still recording."
        }
        liveActivity.update(activityState())
    }

    private func persistTranscript(force: Bool) {
        guard let meeting, force || Date.now.timeIntervalSince(lastSave) > 8 else { return }
        meeting.refinedTranscript = Self.paragraphs(from: segments)
        meeting.duration = elapsed()
        try? container.mainContext.save()
        lastSave = .now
    }

    private func finishMeeting() {
        guard let meeting else { reset(); return }
        meeting.duration = accumulated
        meeting.refinedTranscript = Self.paragraphs(from: segments)
        meeting.rawTranscript = Self.words(from: segments)
        if !moments.isEmpty || !spokenNotes.isEmpty {
            let lines = moments.map { (at: $0, line: "- Marked moment at \(Format.clock($0))") }
                + spokenNotes.map { (at: $0.at, line: "- [\(Format.clock($0.at))] \($0.text)") }
            let marks = lines.sorted { $0.at < $1.at }.map(\.line).joined(separator: "\n")
            meeting.notes = meeting.notes.isEmpty ? marks : meeting.notes + "\n" + marks
        }
        meeting.status = .processing
        try? container.mainContext.save()
        phase = .processing
        processor.process(meeting, in: container.mainContext)
    }

    /// Paragraph breaks at pauses longer than 2.5 s, or every ~6 sentences.
    static func paragraphs(from segments: [LiveTranscriber.Segment]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        var lastEnd: TimeInterval = 0
        for segment in segments {
            if !current.isEmpty, segment.start - lastEnd > 2.5 || current.count >= 6 {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
            current.append(segment.text)
            lastEnd = segment.end
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Words with times spread across each segment (SpeechAnalyzer reports runs, not words).
    static func words(from segments: [LiveTranscriber.Segment]) -> [TranscriptWord] {
        segments.flatMap { segment -> [TranscriptWord] in
            let words = segment.text.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return [] }
            let step = max(0.05, (segment.end - segment.start) / Double(words.count))
            return words.enumerated().map { index, word in
                let start = segment.start + Double(index) * step
                return TranscriptWord(word: word, start: start, end: start + step, confidence: 1, isLocalSpeaker: nil)
            }
        }
    }

    // MARK: - Levels

    private func push(level: Float) {
        var next = levels
        next.removeFirst()
        // Smooth a little so the waveform breathes rather than jitters.
        let previous = next.last ?? 0
        next.append(previous * 0.35 + level * 0.65)
        levels = next
    }

    // MARK: - Live Activity

    private func activityState(phase override: RecordingActivityAttributes.ContentState.Phase? = nil) -> RecordingActivityAttributes.ContentState {
        let elapsed = elapsed()
        let phase: RecordingActivityAttributes.ContentState.Phase = override ?? (self.phase == .paused ? .paused : .recording)
        let line = lastLine
        let trimmed = line.count > 90 ? "…" + line.suffix(88) : line
        return .init(phase: phase, timerAnchor: .now.addingTimeInterval(-elapsed), elapsed: elapsed, lastLine: trimmed)
    }

    // MARK: - Audio session events

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    // A phone call: pause, keep everything so far.
                    if self.phase == .recording {
                        self.interruptedWhileRecording = true
                        self.pause()
                    }
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                    if self.interruptedWhileRecording, options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.capture?.restart()
                        self.resume()
                    }
                    self.interruptedWhileRecording = false
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLive else { return }
                self.capture?.restart()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLive else { return }
                try? AudioCapture.activateSession()
                self.capture?.restart()
            }
        })
    }

    // MARK: - Demo

    private func startDemo(script: [String]) {
        demoIndex = 0
        demoTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                guard let self else { return }
                tick += 1
                if self.phase == .recording {
                    let speaking = (tick / 18) % 4 != 3
                    let base: Float = speaking ? 0.45 : 0.08
                    self.push(level: base + Float.random(in: 0...(speaking ? 0.5 : 0.08)))
                    let index = self.demoIndex
                    if tick % 26 == 0, index < script.count {
                        let words = script[index].split(separator: " ")
                        self.volatileText = words.prefix(max(1, words.count / 2)).joined(separator: " ")
                    }
                    if tick % 26 == 13, index < script.count {
                        let start = self.elapsed() - 6
                        self.handle(.finalized(.init(text: script[index], start: start, end: start + 5)))
                        self.volatileText = ""
                        self.demoIndex += 1
                    }
                }
            }
        }
    }

    /// Demo: jump to a state mid-meeting, for screenshots.
    func seedDemo(elapsed: TimeInterval, segments seeded: [String], volatile: String) {
        accumulated = elapsed
        segmentStart = .now
        segments = seeded.enumerated().map { index, text in
            .init(text: text, start: Double(index) * 9, end: Double(index) * 9 + 8)
        }
        volatileText = volatile
        demoIndex = seeded.count
        levels = (0..<levels.count).map { index -> Float in
            let wave: Double = abs(sin(Double(index) * 0.55))
            let accent: Double = index % 7 == 0 ? 0.4 : 1
            return Float(0.25 + 0.6 * wave * accent)
        }
    }

    // MARK: - Helpers

    static func fetch(_ id: UUID, in context: ModelContext) -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Meetings left in `.recording` by a crash: keep what was saved and write their notes.
    static func recoverInterrupted(in context: ModelContext, processor: MeetingProcessor) {
        let descriptor = FetchDescriptor<Meeting>()
        let stuck = ((try? context.fetch(descriptor)) ?? []).filter { $0.status == .recording && $0.recordedOnThisDevice }
        for meeting in stuck {
            if meeting.duration == 0, let url = meeting.audioURL,
               let file = try? AVAudioFile(forReading: url) {
                meeting.duration = Double(file.length) / file.processingFormat.sampleRate
            }
            meeting.processingError = nil
            processor.process(meeting, in: context)
        }
    }
}
