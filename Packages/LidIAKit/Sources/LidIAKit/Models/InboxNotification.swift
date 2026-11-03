import Foundation
import SwiftData

/// An item in the Mac's notification inbox. Part of the shared schema so the library
/// syncs as one CloudKit store.
@Model
public final class InboxNotification {
    public var id: UUID = UUID()
    public var type: String = "processed"    // "follow_up", "ticket", "processed", "reminder"
    public var title: String = ""
    public var body: String = ""
    public var meetingID: UUID?
    public var isRead: Bool = false
    public var createdAt: Date = Date()
    public var actionPayload: String?

    public init(type: String, title: String, body: String, meetingID: UUID? = nil, actionPayload: String? = nil) {
        self.id = UUID()
        self.type = type
        self.title = title
        self.body = body
        self.meetingID = meetingID
        self.createdAt = Date()
        self.isRead = false
        self.actionPayload = actionPayload
    }

    public var typeIcon: String {
        switch type {
        case "follow_up": "pin.fill"
        case "ticket": "ticket.fill"
        case "processed": "checkmark.circle.fill"
        case "reminder": "clock.fill"
        case "meeting_prep": "doc.text.magnifyingglass"
        default: "bell.fill"
        }
    }

    // MARK: - Action Payload Parsing

    private struct ActionPayloadData: Codable {
        var draft: String?
        var recipient: String?
        var channel: String?
        var ticketTitle: String?
        var meetingTitle: String?
        var actionItemTitle: String?
        /// External event identifier — used by meeting_prep notifications to dedupe.
        var eventID: String?
    }

    private var parsedPayload: ActionPayloadData? {
        guard let json = actionPayload, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActionPayloadData.self, from: data)
    }

    public var draft: String? { parsedPayload?.draft }
    public var recipient: String? { parsedPayload?.recipient }
    public var channel: String? { parsedPayload?.channel }
    public var ticketTitle: String? { parsedPayload?.ticketTitle }
    public var sourceMeetingTitle: String? { parsedPayload?.meetingTitle }
    public var sourceActionItemTitle: String? { parsedPayload?.actionItemTitle }
    public var sourceEventID: String? { parsedPayload?.eventID }

    /// Whether this notification has a rich actionable payload (not just passive).
    public var isDispatchable: Bool { draft != nil || channel != nil }

    /// Helper to create actionPayload JSON string from components.
    public static func encodePayload(
        draft: String? = nil,
        recipient: String? = nil,
        channel: String? = nil,
        ticketTitle: String? = nil,
        meetingTitle: String? = nil,
        actionItemTitle: String? = nil,
        eventID: String? = nil
    ) -> String? {
        let payload = ActionPayloadData(
            draft: draft,
            recipient: recipient,
            channel: channel,
            ticketTitle: ticketTitle,
            meetingTitle: meetingTitle,
            actionItemTitle: actionItemTitle,
            eventID: eventID
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
