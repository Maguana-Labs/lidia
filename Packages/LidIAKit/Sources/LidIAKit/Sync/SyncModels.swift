import Foundation

/// Codable DTOs matching the lidia-sync Go API.

// MARK: - Sync Response

public struct SyncResponse: Codable, Sendable {
    public let serverTime: Int64
    public let meetings: [SyncMeeting]
    public let actionItems: [SyncActionItem]
    public let deletedMeetingIDs: [String]
    public let deletedActionItemIDs: [String]
    public let files: [String: String]?
    public let settings: [String: String]?

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case meetings
        case actionItems = "action_items"
        case deletedMeetingIDs = "deleted_meeting_ids"
        case deletedActionItemIDs = "deleted_action_item_ids"
        case files
        case settings
    }
}

// MARK: - Meeting DTO

public struct SyncMeeting: Codable, Sendable {
    public let id: String
    public let title: String
    public let date: Int64
    public let duration: Double
    public let rawTranscript: String
    public let refinedTranscript: String
    public let summary: String
    public let status: String
    public let notes: String
    public let folder: String?
    public let audioFilePath: String?
    public let userEditedTranscript: String?
    public let userEditedSummary: String?
    public let calendarEventID: String?
    public let calendarAttendees: String?
    public let templateID: String?
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, date, duration, summary, status, notes, folder
        case rawTranscript = "raw_transcript"
        case refinedTranscript = "refined_transcript"
        case audioFilePath = "audio_file_path"
        case userEditedTranscript = "user_edited_transcript"
        case userEditedSummary = "user_edited_summary"
        case calendarEventID = "calendar_event_id"
        case calendarAttendees = "calendar_attendees"
        case templateID = "template_id"
        case updatedAt = "updated_at"
    }

    public init(from meeting: Meeting) {
        self.id = meeting.id.uuidString
        self.title = meeting.title
        self.date = Int64(meeting.date.timeIntervalSince1970 * 1000)
        self.duration = meeting.duration
        self.rawTranscript = ""  // TranscriptWord array not synced as raw text
        self.refinedTranscript = meeting.refinedTranscript
        self.summary = meeting.summary
        self.status = meeting.status.rawValue
        self.notes = meeting.notes
        self.folder = meeting.folder
        self.audioFilePath = meeting.audioFilePath
        self.userEditedTranscript = meeting.userEditedTranscript
        self.userEditedSummary = meeting.userEditedSummary
        self.calendarEventID = meeting.calendarEventID
        self.calendarAttendees = meeting.calendarAttendees.flatMap {
            try? JSONEncoder().encode($0)
        }.flatMap { String(data: $0, encoding: .utf8) }
        self.templateID = meeting.templateID?.uuidString
        self.updatedAt = Int64(Date.now.timeIntervalSince1970 * 1000)
    }
}

// MARK: - Action Item DTO

public struct SyncActionItem: Codable, Sendable {
    public let id: String
    public let meetingID: String?
    public let title: String
    public let assignee: String?
    public let deadline: String?
    public let deadlineDate: Int64?
    public let isCompleted: Int64
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, assignee, deadline
        case meetingID = "meeting_id"
        case deadlineDate = "deadline_date"
        case isCompleted = "is_completed"
        case updatedAt = "updated_at"
    }

    public init(from item: ActionItem) {
        self.id = item.id.uuidString
        self.meetingID = item.meeting?.id.uuidString
        self.title = item.title
        self.assignee = item.assignee
        self.deadline = item.deadline
        self.deadlineDate = item.deadlineDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        self.isCompleted = item.isCompleted ? 1 : 0
        self.updatedAt = Int64(Date.now.timeIntervalSince1970 * 1000)
    }
}
