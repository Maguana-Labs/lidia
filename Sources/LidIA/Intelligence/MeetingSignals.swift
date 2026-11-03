import Foundation

/// What LidIA's on-device suggestions read from a meeting. Built from a
/// `Meeting` on the main actor (`MeetingSignals(meeting)`); tests build it
/// directly. Plain values, so scoring can run anywhere.
struct MeetingSignals: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var date: Date
    /// The meeting's project, if it has one.
    var project: String?
    var attendees: [MeetingAttendee]
    /// Summary and the user's notes, for mentions and next steps.
    var summary: String = ""
    var notes: String = ""
    var isComplete: Bool = true
    var actionItems: [ActionItemSignal] = []

    var seriesKey: String? { MeetingLibraryModel.seriesKey(for: title) }
}

/// An action item as the suggestions see it.
struct ActionItemSignal: Hashable, Sendable {
    var id: UUID
    var title: String
    var assignee: String?
    var isCompleted: Bool = false
}

/// Folders that say where a meeting came from, not what it's about.
/// `Meeting.folder` doubles as the project name; these values are not projects.
enum ProjectCatalog {
    static let sourceFolders: Set<String> = [GranolaImportStore.folderName]

    /// The project a stored folder value names, or nil.
    static func project(ofFolder folder: String?) -> String? {
        guard let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !sourceFolders.contains(trimmed) else { return nil }
        return trimmed
    }

    /// Lowercased, diacritic-free, letters/digits/spaces only.
    static func fold(_ text: String) -> String {
        AttendeeParser.fold(text)
            .split(separator: " ")
            .joined(separator: " ")
    }

    struct Summary: Identifiable, Hashable, Sendable {
        var name: String
        var meetingCount: Int
        var lastDate: Date?
        var id: String { ProjectCatalog.fold(name) }
    }

    /// Every project, from meetings and the user's own list, newest activity first.
    static func projects(meetings: [MeetingSignals], known: [String] = []) -> [Summary] {
        var byKey: [String: Summary] = [:]
        for meeting in meetings {
            guard let name = meeting.project else { continue }
            let key = fold(name)
            var summary = byKey[key] ?? Summary(name: name, meetingCount: 0, lastDate: nil)
            summary.meetingCount += 1
            if summary.lastDate.map({ meeting.date > $0 }) ?? true { summary.lastDate = meeting.date }
            byKey[key] = summary
        }
        for name in known where byKey[fold(name)] == nil {
            byKey[fold(name)] = Summary(name: name, meetingCount: 0, lastDate: nil)
        }
        return byKey.values.sorted { lhs, rhs in
            switch (lhs.lastDate, rhs.lastDate) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

extension Meeting {
    /// The meeting's project (`folder`, minus import-source folders).
    var projectName: String? { ProjectCatalog.project(ofFolder: folder) }

    /// Puts the meeting in a project, or takes it out with nil.
    func setProject(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        folder = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

extension MeetingSignals {
    /// Reads a live meeting. Call on the main actor (SwiftData models aren't Sendable).
    @MainActor
    init(_ meeting: Meeting, attendees: [MeetingAttendee]? = nil) {
        self.init(
            id: meeting.id,
            title: meeting.title,
            date: meeting.date,
            project: meeting.projectName,
            attendees: attendees ?? meeting.libraryAttendees,
            summary: meeting.userEditedSummary ?? meeting.summary,
            notes: meeting.notes,
            isComplete: meeting.status == .complete,
            actionItems: meeting.actionItems
                .filter { !$0.isDeleted }
                .map { ActionItemSignal(id: $0.id, title: $0.title, assignee: $0.assignee, isCompleted: $0.isCompleted) }
        )
    }

    /// Reads a calendar event (no notes yet).
    init(event: AgendaEvent, currentUserName: String) {
        self.init(
            id: UUID(),
            title: event.title,
            date: event.start,
            project: nil,
            attendees: AttendeeParser.parse(event.attendees, currentUserName: currentUserName),
            isComplete: false
        )
    }
}
