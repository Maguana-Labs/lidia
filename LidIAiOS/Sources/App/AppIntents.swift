import AppIntents
import Foundation
import LidIAAppIntents
import LidIAIntelligence
import LidIAKit
import SwiftData

// Siri and Shortcuts on the iPhone. The library intents (find meetings,
// summary, action items, ask, open) and entities come from LidIAAppIntents,
// shared with the Mac; recording control lives here and in the Live Activity
// (Shared/RecordingActivity.swift: stop, bookmark, add note), which is what
// lets Siri act without the app's name while a recording is running.
// Lines marked `siri-27.3:` switch on with the Siri AI SDK (docs/siri.md).

/// "Record a meeting" for Siri, Shortcuts, Spotlight and the Action button.
// siri-27.3: @AppIntent(.tool)
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Meeting"
    static let description = IntentDescription("Opens LidIA and starts recording a meeting, transcribed on this iPhone. While it records, Siri can stop it, bookmark a moment or add a note.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.current?.showRecorder = true
        if let recorder = RecordingController.current, !recorder.phase.isActive {
            await recorder.start()
        }
        return .result()
    }
}

/// The iPhone's side of the shared intents: its library, navigation and Ask
/// (the same engine and routing as the Ask tab: on this iPhone unless the
/// user picked a cloud model with their own key; Local-only forces on-device).
@MainActor
final class IOSSiriHost: LidIASiriHost {
    let settings: AppSettings
    let intelligence: Intelligence
    let container: ModelContainer

    init(settings: AppSettings, intelligence: Intelligence, container: ModelContainer) {
        self.settings = settings
        self.intelligence = intelligence
        self.container = container
    }

    var userName: String { settings.displayName }

    func openMeeting(id: UUID) async throws {
        guard SiriStore.meeting(id, in: container.mainContext) != nil else { throw LidIASiriError.meetingNotFound }
        AppRouter.current?.open(id)
    }

    func ask(_ question: String) async throws -> String {
        let meetings = try container.mainContext.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        let documents = meetings.filter { $0.status == .complete }.prefix(200).map { meeting in
            MeetingDocument(
                id: meeting.id,
                title: meeting.displayTitle,
                date: meeting.date,
                summary: meeting.summaryText,
                notes: meeting.notes,
                transcript: meeting.transcriptText,
                openActionItems: meeting.openItems.map { ($0.assignee.map { "\($0): " } ?? "") + $0.title },
                attendees: meeting.attendeeNames
            )
        }
        let engine = AskEngine(generator: try intelligence.generator())
        let (sources, stream) = try await engine.answer(question: question, documents: Array(documents), userName: settings.firstName)
        var answer = ""
        for try await delta in stream { answer += delta }
        // Citation labels like [1] read badly aloud; name the meetings instead.
        var text = SiriRecap.plainSummary(answer)
        for source in sources { text = text.replacingOccurrences(of: "[\(source.label)]", with: "") }
        let cited = sources.filter { answer.contains("[\($0.label)]") }.map(\.title)
        if !cited.isEmpty { text += "\n\nFrom: " + cited.prefix(3).joined(separator: "; ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plugs the iPhone into the shared intents. Called from `AppServices.init`.
    static func configure(settings: AppSettings, intelligence: Intelligence, container: ModelContainer, demo: Bool) {
        LidIASiri.configure(container: container, host: IOSSiriHost(settings: settings, intelligence: intelligence, container: container))
        SiriDonations.isEnabled = !demo
    }
}

struct LidIAShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Record a meeting with \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Record Meeting",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Stop the \(.applicationName) recording",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: BookmarkMomentIntent(),
            phrases: [
                "Bookmark this moment in \(.applicationName)",
                "Mark this moment in \(.applicationName)",
            ],
            shortTitle: "Bookmark Moment",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: AddMeetingNoteIntent(),
            phrases: [
                "Add a note in \(.applicationName)",
                "Take a note in \(.applicationName)",
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: FindMeetingsIntent(),
            phrases: [
                "Find meetings in \(.applicationName)",
                "Search my \(.applicationName) meetings",
            ],
            shortTitle: "Find Meetings",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ListActionItemsIntent(),
            phrases: [
                "Show my action items in \(.applicationName)",
                "What's on my plate in \(.applicationName)",
            ],
            shortTitle: "Action Items",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: GetMeetingSummaryIntent(),
            phrases: [
                "Summarize a meeting in \(.applicationName)",
                "Get meeting notes from \(.applicationName)",
            ],
            shortTitle: "Meeting Summary",
            systemImageName: "text.alignleft"
        )
        AppShortcut(
            intent: AskLidIAIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) about my meetings",
            ],
            shortTitle: "Ask LidIA",
            systemImageName: "sparkles"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .red
}

/// The iPhone app's intents, including the shared package's.
struct LidIAiOSAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [LidIAAppIntentsPackage.self] }
}
