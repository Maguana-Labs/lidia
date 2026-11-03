import AppKit
import Foundation
import LidIAAppIntents
import LidIAKit
import SwiftData
import os

/// The Mac's side of the shared Siri intents: its library, its window, and
/// its Ask (the agent harness, routed and gated exactly like Ask in the app).
///
/// Built in `LidIAApp.init`, before any window exists, so an intent that
/// launches the app finds everything ready.
@MainActor
final class MacSiriHost: LidIASiriHost {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "Siri")

    /// Set by `MacSiri.configure`; the Mac-only intents read it.
    static private(set) var shared: MacSiriHost?

    let container: ModelContainer
    let settings: AppSettings
    let session: RecordingSession
    let modelManager: ModelManager?
    let meetingDetector: MeetingDetector?
    let eventKitManager: EventKitManager?
    let googleCalendarMonitor: GoogleCalendarMonitor?

    init(
        container: ModelContainer,
        settings: AppSettings,
        session: RecordingSession,
        modelManager: ModelManager? = nil,
        meetingDetector: MeetingDetector? = nil,
        eventKitManager: EventKitManager? = nil,
        googleCalendarMonitor: GoogleCalendarMonitor? = nil
    ) {
        self.container = container
        self.settings = settings
        self.session = session
        self.modelManager = modelManager
        self.meetingDetector = meetingDetector
        self.eventKitManager = eventKitManager
        self.googleCalendarMonitor = googleCalendarMonitor
    }

    var context: ModelContext { container.mainContext }

    // MARK: LidIASiriHost

    var userName: String { settings.displayName }

    func openMeeting(id: UUID) async throws {
        guard SiriStore.meeting(id, in: context) != nil else { throw LidIASiriError.meetingNotFound }
        SiriRouter.shared.request(.openMeeting(id))
    }

    /// Ask through the agent harness with the Ask route (Hybrid, the cloud
    /// gate and Local-only mode all apply in `AgentEndpoints.resolve`). Changes
    /// the agent proposes are never made from Siri: the answer says to open LidIA.
    func ask(_ question: String) async throws -> String {
        guard !question.isEmpty else { throw LidIASiriError.unavailable("What do you want to know?") }
        let endpoint = AgentEndpoints.resolve(settings: settings, modelManager: modelManager, taskType: .ask)
        let configuration = AgentHarness.Configuration.standard(for: endpoint.family, locality: endpoint.locality)
        let destinations = AgentEndpoints.destinations(settings: settings)
        let harness = AgentHarness(endpoint: endpoint, tools: LidIATools.all(destinations: destinations), configuration: configuration)
        let prompt = AgentPromptContext(
            task: .ask, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps,
            userName: settings.displayName,
            userInstructions: AgentEndpoints.userInstructions(settings: settings)
        )
        let result = await harness.run(
            prompt: prompt, history: [], userMessage: question,
            context: AgentToolContext(modelContext: context, settings: settings, destinations: destinations)
        )
        Self.logger.info("Siri Ask finished: \(result.outcome.rawValue, privacy: .public) via \(endpoint.locality.label, privacy: .public)")
        return Self.spokenAnswer(result.answer, sources: result.sources.map(\.title), hasPendingChanges: !result.pendingActions.isEmpty || !result.proposals.isEmpty)
    }

    /// The answer without markdown, with its sources and a note about changes
    /// that need confirming in the app.
    static func spokenAnswer(_ answer: String, sources: [String], hasPendingChanges: Bool) -> String {
        var text = SiriRecap.plainSummary(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        // Citation markers like [1] or [a1b2c3d4] read badly aloud.
        text = text.replacingOccurrences(of: #"\s?\[[0-9a-f]{1,8}\]"#, with: "", options: .regularExpression)
        if text.isEmpty { text = "LidIA couldn't find an answer in your meetings." }
        var unique: [String] = []
        for title in sources where !unique.contains(title) { unique.append(title) }
        if !unique.isEmpty { text += "\n\nFrom: " + unique.prefix(3).joined(separator: "; ") }
        if hasPendingChanges { text += "\n\nOpen Ask in LidIA to confirm the changes it suggested." }
        return text
    }

    func libraryDidChange(meetingID: UUID?) {
        guard let meetingID, let meeting = SiriStore.meeting(meetingID, in: context) else { return }
        SpotlightIndexer.indexMeeting(meeting)
    }

    // MARK: Recording (Mac-only intents)

    /// Starts an ad-hoc recording, like ⌘R, and shows it.
    func startRecording() -> Meeting {
        if session.isRecording, let current = session.currentMeeting { return current }
        let meeting = session.startRecording(
            modelContext: context, settings: settings, modelManager: modelManager, meetingDetector: meetingDetector,
            eventKitManager: eventKitManager ?? AppDelegate.eventKitManagerRef,
            googleCalendarMonitor: googleCalendarMonitor ?? AppDelegate.googleCalendarMonitorRef
        )
        SiriRouter.shared.request(.openMeeting(meeting.id))
        return meeting
    }

    /// Stops the recording; the notes are written as after Stop in the app.
    func stopRecording() throws -> Meeting {
        guard session.isRecording, let meeting = session.currentMeeting else { throw LidIASiriError.notRecording }
        session.stopRecording(modelContext: context, settings: settings, eventKitManager: eventKitManager ?? AppDelegate.eventKitManagerRef)
        return meeting
    }

    /// Adds a line to the live meeting's notes, stamped with the recording time.
    @discardableResult
    func addLiveNote(_ text: String?) throws -> (meeting: Meeting, line: String) {
        guard session.isRecording, let meeting = session.currentMeeting else { throw LidIASiriError.notRecording }
        let clock = Self.clock(session.elapsedTime)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = trimmed.isEmpty ? "- Marked moment at \(clock)" : "- [\(clock)] \(trimmed)"
        meeting.notes = Self.appending(line, to: meeting.notes)
        try? context.save()
        return (meeting, line)
    }

    static func appending(_ line: String, to notes: String) -> String {
        let base = notes.trimmingCharacters(in: .newlines)
        return base.isEmpty ? line : base + "\n" + line
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Setup

    /// Plugs the Mac into the shared intents. Called once, from `LidIAApp.init`.
    static func configure(_ host: MacSiriHost) {
        shared = host
        LidIASiri.configure(container: host.container, host: host)
        LidIASiri.parsePeople = { raw, userName in
            AttendeeParser.parse(raw, currentUserName: userName).map {
                SiriPerson(name: $0.name, email: $0.email, isCurrentUser: $0.isCurrentUser)
            }
        }
        LidIASiri.projectOfFolder = { ProjectCatalog.project(ofFolder: $0) }
        // Demo and snapshot runs, and bare executables, never teach Siri anything.
        SiriDonations.isEnabled = Bundle.main.bundleIdentifier != nil && !DemoDataSeeder.isDemoMode && !SnapshotRun.isActive
    }
}
