import AppIntents
import CoreTransferable
import Foundation
import LidIAKit
import UniformTypeIdentifiers

/// An action item from a meeting: what to do, who owns it, when it's due,
/// where it stands and the meeting it came from.
public struct ActionItemEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Action Item",
        numericFormat: "\(placeholder: .int) action items"
    )
    public static let defaultQuery = ActionItemEntityQuery()
    // siri-27.3: public static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    public let id: UUID

    @Property(title: "Title") // siri-27.3: @Property(title: "Title", description: "What has to be done, in a few words.")
    public var title: String

    @Property(title: "Owner") // siri-27.3: @Property(title: "Owner", description: "Who owns the item: a person from the meeting, or the user (\"you\", \"me\" or the user's name).")
    public var owner: String?

    @Property(title: "Due Date") // siri-27.3: @Property(title: "Due Date", description: "When the item is due, if the meeting set a date.")
    public var dueDate: Date?

    @Property(title: "Status") // siri-27.3: @Property(title: "Status", description: "To do, in progress, waiting on someone, or done.")
    public var status: ActionItemStateAppEnum

    @Property(title: "Meeting") // siri-27.3: @Property(title: "Meeting", description: "The meeting the item came from.")
    public var meeting: MeetingEntity?

    @Property(title: "Meeting Title") // siri-27.3: @Property(title: "Meeting Title", description: "The title of the meeting the item came from.")
    public var meetingTitle: String?

    @Property(title: "Project") // siri-27.3: @Property(title: "Project", description: "The project of the meeting the item came from, if any.")
    public var project: String?

    // siri-27.3: @Property(title: "Priority", visibility: .internal)
    // siri-27.3: public var priority: String

    public init(record: SiriActionItemRecord, meeting: SiriMeetingRecord? = nil) {
        id = record.id
        title = record.title
        owner = record.owner
        dueDate = record.dueDate
        status = ActionItemStateAppEnum(record.status)
        self.meeting = meeting.map(MeetingEntity.init(record:))
        meetingTitle = record.meetingTitle
        project = record.project
        // siri-27.3: priority = record.priority
    }

    public var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let owner, !owner.isEmpty { parts.append(owner) }
        if let dueDate { parts.append("due " + dueDate.formatted(date: .abbreviated, time: .omitted)) }
        if let meetingTitle, !meetingTitle.isEmpty { parts.append("from " + meetingTitle) }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(parts.joined(separator: " · "))",
            image: .init(systemName: status == .done ? "checkmark.circle.fill" : "circle")
        )
    }
}

@MainActor
extension ActionItemEntity {
    /// The entity for a stored item, with its meeting.
    public static func make(_ item: ActionItem) -> ActionItemEntity {
        ActionItemEntity(record: SiriStore.itemRecord(item), meeting: item.meeting.map { SiriStore.record($0, includeSearchText: false) })
    }
}

/// Finds action items by id or words, and offers the open ones.
public struct ActionItemEntityQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ActionItemEntity] {
        try await MainActor.run {
            let context = try LidIASiri.context()
            return identifiers.compactMap { SiriStore.actionItem($0, in: context) }.map(ActionItemEntity.make)
        }
    }

    public func entities(matching string: String) async throws -> [ActionItemEntity] {
        try await MainActor.run {
            let context = try LidIASiri.context()
            let records = try SiriStore.itemRecords(in: context)
            return SiriLibrary.actionItems(matching: string, in: records)
                .compactMap { SiriStore.actionItem($0.id, in: context) }
                .map(ActionItemEntity.make)
        }
    }

    public func suggestedEntities() async throws -> [ActionItemEntity] {
        try await MainActor.run {
            let context = try LidIASiri.context()
            let records = try SiriStore.itemRecords(in: context)
            return SiriLibrary.findActionItems(records, SiriActionItemSearch(limit: 15), userName: LidIASiri.userName)
                .compactMap { SiriStore.actionItem($0.id, in: context) }
                .map(ActionItemEntity.make)
        }
    }
}

/// Hands an action item to Messages, Mail, Reminders and other apps.
extension ActionItemEntity: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { entity in
            Data(SiriRecap.plainText(item: entity.record).utf8)
        }
        DataRepresentation(exportedContentType: .html) { entity in
            Data(SiriRecap.html(item: entity.record).utf8)
        }
    }

    /// The item as a plain record (what the transfer writes out).
    var record: SiriActionItemRecord {
        SiriActionItemRecord(
            id: id, title: title, owner: owner, dueDate: dueDate,
            status: ActionItemStatus(rawValue: status.rawValue) ?? .todo,
            meetingID: meeting?.id, meetingTitle: meetingTitle, meetingDate: meeting?.date, project: project
        )
    }
}
