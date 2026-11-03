import Foundation
import SwiftData

public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case queued
    case complete
    case failed
}

/// A meeting: transcript, notes, summary and action items.
///
/// The one definition for every app (Mac, iPhone, Watch). The Mac's library and the
/// iPhone's sync through the same iCloud container, so the schema must be identical
/// on both sides and CloudKit-compatible (see `LidIASchema`):
/// - every attribute is optional or has a default,
/// - every relationship is optional and has an inverse,
/// - no unique constraints.
///
/// `LidIASchemaTests` enforces these rules on the whole schema.
@Model
public final class Meeting {
    public var id: UUID = UUID()
    public var title: String = ""
    public var date: Date = Date.now
    public var duration: TimeInterval = 0
    /// Word-level transcript. Stored outside the SQLite file when large; CloudKit sync
    /// moves values too big for a record into a CKAsset on its own.
    @Attribute(.externalStorage) public var rawTranscript: [TranscriptWord] = []
    @Attribute(.externalStorage) public var refinedTranscript: String = ""
    @Attribute(.externalStorage) public var summary: String = ""
    /// Synced, so another device can show "Recording on your Mac". Only the device in
    /// `originDeviceID` acts on an unfinished status (see `isOwnedByThisDevice`).
    public var status: MeetingStatus = MeetingStatus.recording
    public var processingRetryCount: Int = 0
    /// Path of the recording **on the device that made it**. Device-local: it syncs,
    /// but a path from another device never resolves here, so readers must check the
    /// file exists (Mac: `MeetingAudioLocator`; iPhone: `Meeting.audioURL`).
    public var audioFilePath: String?
    @Attribute(.externalStorage) public var userEditedTranscript: String?
    @Attribute(.externalStorage) public var userEditedSummary: String?
    public var notionPageID: String?
    public var calendarEventID: String?
    public var calendarAttendees: [String]?
    public var templateID: UUID?
    public var templateAutoDetected: Bool = true
    public var processingError: String?
    public var notes: String = ""
    public var folder: String?
    /// JSON-encoded structured summary with quote anchors for transcript linking.
    public var structuredSummary: Data?
    /// Where an imported meeting came from, as "<source>:<id>" (for example
    /// "granola:62f34169-…"). `nil` for meetings made in LidIA. Re-running an
    /// import matches on this, so it updates instead of duplicating.
    public var externalSourceID: String? = nil
    /// The device that created or recorded this meeting (`LidIADevice.id`). Only that
    /// device recovers or processes it automatically, so two devices never both act on
    /// a meeting that's still recording or processing. `nil` for meetings that came
    /// from a device whose LidIA predates sync.
    public var originDeviceID: String? = nil
    /// The stored relationship. CloudKit needs to-many relationships to be optional;
    /// use `actionItems`, which reads `[]` for nil.
    @Relationship(deleteRule: .cascade, originalName: "actionItems", inverse: \ActionItem.meeting)
    public var actionItemsStorage: [ActionItem]? = []

    /// The meeting's action items (never nil).
    public var actionItems: [ActionItem] {
        get { actionItemsStorage ?? [] }
        set { actionItemsStorage = newValue }
    }

    public init(
        title: String = "",
        date: Date = .now,
        duration: TimeInterval = 0,
        rawTranscript: [TranscriptWord] = [],
        refinedTranscript: String = "",
        summary: String = "",
        status: MeetingStatus = .recording,
        processingRetryCount: Int = 0,
        audioFilePath: String? = nil,
        userEditedTranscript: String? = nil,
        userEditedSummary: String? = nil,
        notionPageID: String? = nil,
        calendarEventID: String? = nil,
        calendarAttendees: [String]? = nil,
        templateID: UUID? = nil,
        templateAutoDetected: Bool = true,
        processingError: String? = nil,
        notes: String = "",
        folder: String? = nil,
        actionItems: [ActionItem] = [],
        originDeviceID: String? = LidIADevice.id
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.duration = duration
        self.rawTranscript = rawTranscript
        self.refinedTranscript = refinedTranscript
        self.summary = summary
        self.status = status
        self.processingRetryCount = processingRetryCount
        self.audioFilePath = audioFilePath
        self.userEditedTranscript = userEditedTranscript
        self.userEditedSummary = userEditedSummary
        self.notionPageID = notionPageID
        self.calendarEventID = calendarEventID
        self.calendarAttendees = calendarAttendees
        self.templateID = templateID
        self.templateAutoDetected = templateAutoDetected
        self.processingError = processingError
        self.notes = notes
        self.folder = folder
        self.originDeviceID = originDeviceID
        self.actionItemsStorage = actionItems
    }

    /// Stable hash for attendee set, used for template recurrence matching.
    public var attendeeHash: String? {
        guard let attendees = calendarAttendees, !attendees.isEmpty else { return nil }
        return attendees.sorted().joined(separator: "|").lowercased()
    }

    /// True when this device created the meeting, so it may recover or process it.
    public var isOwnedByThisDevice: Bool { originDeviceID == LidIADevice.id }

    #Index<Meeting>([\.date], [\.calendarEventID], [\.externalSourceID])
}
