import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import LidIAKit
import UniformTypeIdentifiers

/// A meeting in LidIA, for Siri, Shortcuts and Spotlight.
///
/// Titles, dates, people and the project are always available: they're what
/// Siri needs to find a meeting. The summary, decisions and notes are content:
/// they come from "Get Meeting Summary" (which asks to authenticate and follows
/// `SiriContentPolicy`), never from these properties.
/// Lines marked `siri-27.3:` switch on with the Siri AI SDK (docs/siri.md).
public struct MeetingEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Meeting",
        numericFormat: "\(placeholder: .int) meetings"
    )
    public static let defaultQuery = MeetingEntityQuery()
    // siri-27.3: public static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    public let id: UUID

    @Property(title: "Title") // siri-27.3: @Property(title: "Title", description: "The meeting's name, as on the calendar or as the notes titled it.", authenticationPolicy: .alwaysAllowed)
    public var title: String

    @Property(title: "Date") // siri-27.3: @Property(title: "Date", description: "When the meeting started, with the time of day.", authenticationPolicy: .alwaysAllowed)
    public var date: Date

    @Property(title: "Duration in Minutes") // siri-27.3: @Property(title: "Duration in Minutes", description: "How long the recording lasted, in minutes. Zero for a written note.")
    public var durationMinutes: Int

    @Property(title: "Attendees") // siri-27.3: @Property(title: "Attendees", description: "The other people in the meeting, by name (the user is left out).", authenticationPolicy: .alwaysAllowed)
    public var attendees: [String]

    @Property(title: "Project") // siri-27.3: @Property(title: "Project", description: "The project the meeting belongs to, if the user filed it in one.")
    public var project: String?

    @Property(title: "Status") // siri-27.3: @Property(title: "Status", description: "Whether the meeting is still recording, its notes are being written, or they're ready.")
    public var status: MeetingStateAppEnum

    @Property(title: "Open Action Items") // siri-27.3: @Property(title: "Open Action Items", description: "How many of the meeting's action items aren't done yet.")
    public var openActionItemCount: Int

    // siri-27.3: @DeferredProperty(title: "Summary", description: "The meeting's notes: what was discussed and decided. Private: Siri asks the user to authenticate, and LidIA withholds it in Local-only mode.", authenticationPolicy: .requiresAuthentication)
    // siri-27.3: public var summary: String? {
        // siri-27.3: get async throws { try await SiriContentAccess.summaryText(meetingID: id) }
    // siri-27.3: }

    // siri-27.3: @Property(title: "Library ID", visibility: .internal)
    // siri-27.3: public var libraryID: String

    public init(record: SiriMeetingRecord) {
        id = record.id
        title = record.displayTitle
        date = record.date
        durationMinutes = Int((record.duration / 60).rounded())
        attendees = record.others.map(\.displayName).filter { !$0.isEmpty }
        project = record.project
        status = MeetingStateAppEnum(record.state)
        openActionItemCount = record.openItemCount
        // siri-27.3: libraryID = record.id.uuidString
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(Self.subtitle(date: date, attendees: attendees))",
            image: .init(systemName: status == .recording ? "record.circle" : "waveform")
        )
    }

    static func subtitle(date: Date, attendees: [String]) -> String {
        var line = date.formatted(date: .abbreviated, time: .shortened)
        if !attendees.isEmpty {
            let names = attendees.prefix(3).joined(separator: ", ")
            line += " · with " + names + (attendees.count > 3 ? " +\(attendees.count - 3)" : "")
        }
        return line
    }

    /// What Spotlight shows for the entity itself: never the summary.
    public var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = title
        set.displayName = title
        set.contentCreationDate = date
        set.keywords = attendees + (project.map { [$0] } ?? [])
        return set
    }
}

/// Finds meetings by id, by words in the title, people or project, and offers
/// the most recent ones.
public struct MeetingEntityQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [MeetingEntity] {
        try await MainActor.run {
            let context = try LidIASiri.context()
            return identifiers.compactMap { SiriStore.meeting($0, in: context) }.map { MeetingEntity(record: SiriStore.record($0, includeSearchText: false)) }
        }
    }

    public func entities(matching string: String) async throws -> [MeetingEntity] {
        try await MainActor.run {
            let records = try SiriStore.meetingRecords(in: try LidIASiri.context(), includeSearchText: false)
            return SiriLibrary.meetings(matching: string, in: records).map(MeetingEntity.init(record:))
        }
    }

    public func suggestedEntities() async throws -> [MeetingEntity] {
        try await MainActor.run {
            let records = try SiriStore.meetingRecords(in: try LidIASiri.context(), includeSearchText: false)
            return records.filter { $0.date <= .now }.prefix(10).map(MeetingEntity.init(record:))
        }
    }
}

// MARK: - Content access (summary, recap)

/// Reads meeting content for Siri, only when `SiriContentPolicy` allows it.
public enum SiriContentAccess {
    /// The summary as plain text, or the policy's message.
    public static func summaryText(meetingID: UUID) async throws -> String? {
        let policy = SiriContentPolicy.current()
        guard policy.allowsMeetingContent else { return policy.blockedMessage }
        return try await MainActor.run {
            guard let meeting = SiriStore.meeting(meetingID, in: try LidIASiri.context()) else { throw LidIASiriError.meetingNotFound }
            let summary = SiriRecap.plainSummary(SiriStore.content(of: meeting).summary)
            return summary.isEmpty ? nil : summary
        }
    }

    /// The recap (plain text or HTML) with content only when allowed.
    public static func recap(meetingID: UUID, html: Bool) async throws -> String {
        let policy = SiriContentPolicy.current()
        return try await MainActor.run {
            let context = try LidIASiri.context()
            guard let meeting = SiriStore.meeting(meetingID, in: context) else { throw LidIASiriError.meetingNotFound }
            let record = SiriStore.record(meeting, includeSearchText: false)
            let content = policy.allowsMeetingContent ? SiriStore.content(of: meeting) : nil
            let items = meeting.actionItems.filter { !$0.isDeleted }.map(SiriStore.itemRecord)
            return html
                ? SiriRecap.html(meeting: record, content: content, items: items, blockedMessage: policy.blockedMessage)
                : SiriRecap.plainText(meeting: record, content: content, items: items, blockedMessage: policy.blockedMessage)
        }
    }
}

/// Hands the meeting's recap to Mail, Messages, Notes and other apps: plain
/// text first (every app takes it), HTML for apps that keep formatting.
/// The summary and decisions are included only when `SiriContentPolicy` allows.
extension MeetingEntity: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { entity in
            Data(try await SiriContentAccess.recap(meetingID: entity.id, html: false).utf8)
        }
        DataRepresentation(exportedContentType: .html) { entity in
            Data(try await SiriContentAccess.recap(meetingID: entity.id, html: true).utf8)
        }
    }
}
