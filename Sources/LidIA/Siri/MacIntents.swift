import AppIntents
import Foundation
import LidIAAppIntents
import LidIAKit
import SwiftData

// The Mac's own intents: recording, notes, and the actions that open LidIA's
// confirm sheets. The library intents (find, summary, action items, ask, open)
// come from LidIAAppIntents. Lines marked `siri-27.3:` turn these into Siri AI
// tools with the 27.3 SDK (docs/siri.md).

@MainActor
private func host() throws -> MacSiriHost {
    guard let host = MacSiriHost.shared else { throw LidIASiriError.notReady }
    return host
}

// MARK: - Recording

// siri-27.3: @AppIntent(.tool)
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Meeting"
    static let description = IntentDescription(
        "Starts recording a meeting in LidIA on this Mac and opens its live page. Audio and transcript stay on this Mac.",
        categoryName: "Recording",
        searchKeywords: ["record", "start", "transcribe", "grabar"]
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let host = try host()
        let wasRecording = host.session.isRecording
        let meeting = host.startRecording()
        let title = meeting.title.isEmpty ? "your meeting" : "\u{201C}\(meeting.title)\u{201D}"
        return .result(
            dialog: IntentDialog(stringLiteral: wasRecording ? "LidIA is already recording \(title)." : "Recording \(title)."),
            view: SiriConfirmationSnippet(symbol: "record.circle", title: wasRecording ? "Already recording" : "Recording", detail: meeting.title.isEmpty ? nil : meeting.title)
        )
    }
}

// siri-27.3: @AppIntent(.tool)
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription(
        "Stops the meeting LidIA is recording. LidIA then writes the notes and action items on this Mac.",
        categoryName: "Recording",
        searchKeywords: ["stop", "end", "finish", "parar", "detener"]
    )
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MeetingEntity> & ProvidesDialog {
        let host = try host()
        let meeting = try host.stopRecording()
        SiriDonations.donate(StopRecordingIntent())
        return .result(
            value: MeetingEntity(record: SiriStore.record(meeting, includeSearchText: false)),
            dialog: "Stopped. LidIA is writing the notes now."
        )
    }
}

// siri-27.3: @AppIntent(.tool)
struct AddMeetingNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note to Live Meeting"
    static let description = IntentDescription(
        "Adds a line to the notes of the meeting LidIA is recording, stamped with the time in the recording. LidIA merges it into the meeting notes.",
        categoryName: "Recording",
        searchKeywords: ["note", "write down", "remember", "nota", "apunta"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Note", description: "What to write down, in the user's words.", requestValueDialog: "What should I write down?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to the live meeting's notes")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw $text.needsValueError("What should I write down?") }
        let (_, line) = try host().addLiveNote(trimmed)
        let stamp = line.split(separator: "]").first.map { String($0.dropFirst(3)) } ?? ""
        return .result(dialog: IntentDialog(stringLiteral: "Added to your notes at \(stamp)."))
    }
}

// siri-27.3: @AppIntent(.tool)
struct BookmarkMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark This Moment"
    static let description = IntentDescription(
        "Marks the current moment in the meeting LidIA is recording, so the user can find it in the transcript later.",
        categoryName: "Recording",
        searchKeywords: ["bookmark", "mark", "flag", "highlight", "marcar"]
    )
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (_, line) = try host().addLiveNote(nil)
        return .result(dialog: IntentDialog(stringLiteral: line.replacingOccurrences(of: "- Marked moment at ", with: "Marked the moment at ") + "."))
    }
}

// MARK: - Notes

// siri-27.3: @AppIntent(.tool)
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription(
        "Opens a new note in LidIA. During a meeting it can also start transcribing, as set in LidIA's Recording settings.",
        categoryName: "Meetings",
        searchKeywords: ["note", "write", "nueva nota"]
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try host()
        SiriRouter.shared.request(.newNote)
        return .result()
    }
}

// MARK: - Follow-ups (confirm sheets; nothing is sent from here)

// siri-27.3: @AppIntent(.tool)
struct DraftFollowUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft Follow-Up"
    static let description = IntentDescription(
        "Drafts the follow-up email for a meeting (thanks, a short recap and the next steps) and opens it in LidIA to review. Nothing is sent: the user edits it, then chooses Open in Mail or Copy.",
        categoryName: "Follow-ups",
        searchKeywords: ["follow up", "recap email", "email", "seguimiento"]
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Meeting", description: "The meeting to follow up on: the one on screen, or one found by person, project or date.")
    var meeting: MeetingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Draft a follow-up for \(\.$meeting)")
    }

    init() {}

    init(meeting: MeetingEntity) {
        self.meeting = meeting
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let host = try host()
        guard let model = SiriStore.meeting(meeting.id, in: host.context) else { throw LidIASiriError.meetingNotFound }
        let plan = MacFollowUps.plan(for: model, settings: host.settings, context: host.context)
        SiriRouter.shared.request(plan.request)
        return .result(dialog: IntentDialog(stringLiteral: plan.spoken))
    }
}

// siri-27.3: @AppIntent(.tool)
struct PrepareNextStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Next Step"
    static let description = IntentDescription(
        "Prepares the next step for an action item (an email, a calendar change, a ticket or a page, depending on what it asks) and opens it in LidIA to review. Nothing is sent or changed until the user confirms in LidIA.",
        categoryName: "Follow-ups",
        searchKeywords: ["next step", "prepare", "draft", "do it", "siguiente paso"]
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Action Item", description: "The item to prepare: the one on screen, or one found by its words.")
    var item: ActionItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Prepare the next step for \(\.$item)")
    }

    init() {}

    init(item: ActionItemEntity) {
        self.item = item
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let host = try host()
        guard let model = SiriStore.actionItem(item.id, in: host.context) else { throw LidIASiriError.actionItemNotFound }
        guard model.meeting != nil else {
            throw LidIASiriError.unavailable("That action item isn't from a meeting, so LidIA has nothing to prepare it from.")
        }
        let intent = MacFollowUps.nextStep(for: model, host: host)
        SiriRouter.shared.request(.nextStep(itemID: model.id))
        return .result(dialog: IntentDialog(stringLiteral: MacFollowUps.spoken(intent, itemTitle: model.title)))
    }
}

// MARK: - Shortcuts

/// LidIA's App Shortcuts: phrases that work with no setup, in English and
/// Spanish (`Resources/AppShortcuts/<lang>.lproj/AppShortcuts.strings`).
struct LidIAShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Record a meeting with \(.applicationName)",
                "Start recording in \(.applicationName)",
            ],
            shortTitle: "Record Meeting",
            systemImageName: "record.circle"
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
            intent: AddMeetingNoteIntent(),
            phrases: [
                "Add a note in \(.applicationName)",
                "Take a note in \(.applicationName)",
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil"
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
            intent: NewNoteIntent(),
            phrases: [
                "New note in \(.applicationName)",
                "Write a note in \(.applicationName)",
            ],
            shortTitle: "New Note",
            systemImageName: "note.text"
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
        AppShortcut(
            intent: DraftFollowUpIntent(),
            phrases: [
                "Draft a follow-up in \(.applicationName)",
                "Write a meeting follow-up with \(.applicationName)",
            ],
            shortTitle: "Draft Follow-Up",
            systemImageName: "envelope"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .red
}

/// The Mac app's intents, including the shared package's.
struct LidIAMacAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [LidIAAppIntentsPackage.self] }
}
