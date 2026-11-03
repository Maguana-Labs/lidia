import Foundation
import LidIAKit
import SwiftData

/// What each app provides so the shared intents can act on its UI and its AI.
@MainActor
public protocol LidIASiriHost: AnyObject {
    /// The user's name, for "my action items".
    var userName: String { get }
    /// Shows the meeting in the app.
    func openMeeting(id: UUID) async throws
    /// Answers a question about the library with the app's own Ask engine,
    /// routing and privacy rules. Called only when `SiriContentPolicy` allows content.
    func ask(_ question: String) async throws -> String
    /// Called after an intent changed the library (refresh caches, sync).
    func libraryDidChange(meetingID: UUID?)
}

extension LidIASiriHost {
    public func libraryDidChange(meetingID: UUID?) {}
}

/// The shared intents' connection to the running app: the library, the host,
/// and the app's rules for people and projects. Each app calls `configure`
/// once at launch, before any intent can run (in `App.init`).
@MainActor
public enum LidIASiri {
    private(set) public static var container: ModelContainer?
    private(set) public static var host: (any LidIASiriHost)?
    /// Parses a meeting's raw attendees. The Mac passes its `AttendeeParser`.
    public static var parsePeople: @MainActor ([String], String) -> [SiriPerson] = SiriDefaults.parsePeople
    /// The project a meeting's folder names. The Mac leaves out import folders.
    public static var projectOfFolder: @MainActor (String?) -> String? = SiriDefaults.project(ofFolder:)

    public static func configure(container: ModelContainer, host: any LidIASiriHost) {
        self.container = container
        self.host = host
    }

    /// The library's main context, or `LidIASiriError.notReady`.
    public static func context() throws -> ModelContext {
        guard let container else { throw LidIASiriError.notReady }
        return container.mainContext
    }

    public static var userName: String { host?.userName ?? "" }
}

/// Reads the library into the value copies the rules work on. Main actor only;
/// models never leave this type.
@MainActor
public enum SiriStore {
    /// Every meeting, newest first, without meetings still being recorded
    /// when `includeRecording` is false.
    public static func meetingRecords(in context: ModelContext, includeSearchText: Bool = true) throws -> [SiriMeetingRecord] {
        let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        return meetings.map { record($0, includeSearchText: includeSearchText) }
    }

    public static func record(_ meeting: Meeting, includeSearchText: Bool = true) -> SiriMeetingRecord {
        let userName = LidIASiri.userName
        let items = meeting.actionItems.filter { !$0.isDeleted }
        return SiriMeetingRecord(
            id: meeting.id,
            title: meeting.title,
            date: meeting.date,
            duration: meeting.duration,
            people: LidIASiri.parsePeople(meeting.calendarAttendees ?? [], userName),
            project: LidIASiri.projectOfFolder(meeting.folder),
            state: SiriMeetingState(meeting.status),
            openItemCount: items.filter { !$0.isCompleted }.count,
            searchableText: includeSearchText ? (meeting.userEditedSummary ?? meeting.summary) + "\n" + meeting.notes : ""
        )
    }

    public static func meeting(_ id: UUID, in context: ModelContext) -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public static func actionItem(_ id: UUID, in context: ModelContext) -> ActionItem? {
        var descriptor = FetchDescriptor<ActionItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public static func itemRecords(in context: ModelContext) throws -> [SiriActionItemRecord] {
        try context.fetch(FetchDescriptor<ActionItem>()).filter { !$0.isDeleted }.map(itemRecord)
    }

    public static func itemRecord(_ item: ActionItem) -> SiriActionItemRecord {
        SiriActionItemRecord(
            id: item.id,
            title: item.title,
            owner: item.assignee,
            dueDate: item.deadlineDate,
            dueText: item.displayDeadline,
            status: item.boardStatus,
            priority: item.priority,
            meetingID: item.meeting?.id,
            meetingTitle: item.meeting?.title,
            meetingDate: item.meeting?.date,
            project: LidIASiri.projectOfFolder(item.meeting?.folder)
        )
    }

    /// The transcript as text: the edited one, else the refined one, else the words.
    public static func transcriptText(_ meeting: Meeting) -> String {
        if let edited = meeting.userEditedTranscript, !edited.isEmpty { return edited }
        if !meeting.refinedTranscript.isEmpty { return meeting.refinedTranscript }
        return meeting.rawTranscript.map(\.word).joined(separator: " ")
    }

    /// Summary, decisions and notes. Callers must check `SiriContentPolicy` first.
    public static func content(of meeting: Meeting) -> SiriMeetingContent {
        let summary = meeting.userEditedSummary ?? meeting.summary
        var decisions = SiriRecap.decisions(fromStructuredSummary: meeting.structuredSummary)
        if decisions.isEmpty { decisions = SiriRecap.decisions(fromMarkdown: summary) }
        return SiriMeetingContent(summary: summary, decisions: decisions, notes: meeting.notes)
    }
}
