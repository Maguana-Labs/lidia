import Foundation

/// What an open action item really asks for, worked out and prepared so the
/// user only has to look and click: who owes what to whom, where it goes,
/// a ready draft (message, calendar change, ticket, page), the moment in the
/// transcript it comes from, and how sure LidIA is (from that evidence, not
/// from a model's opinion of itself). Nothing here is ever sent on its own.
///
/// Cached in `IntentStore` (JSON on disk, keyed by the action item's UUID),
/// never in the SwiftData models.
struct ActionIntent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case message, schedule, ticket, document, reminder, research, unclear

        var label: String {
            switch self {
            case .message: "Message"
            case .schedule: "Calendar"
            case .ticket: "Ticket"
            case .document: "Doc or link"
            case .reminder: "Reminder"
            case .research: "Research"
            case .unclear: "Unclear"
            }
        }
    }

    /// Who owes what to whom.
    enum Direction: String, Codable, Sendable {
        /// The user does it, for `recipients`.
        case userOwes
        /// Someone else does it for the user: the user can only nudge.
        case othersOweUser
        /// Between other people.
        case othersOwe
        case unknown
    }

    /// Whether the transcript backs the item.
    enum Verdict: String, Codable, Sendable {
        case supported
        /// A loose match: worth a look.
        case weak
        /// Nothing in the transcript says it.
        case notFound
        /// Said, but it happened during the meeting (a screen share, a live
        /// explanation): not a follow-up.
        case doneInMeeting

        var needsReview: Bool { self != .supported }
    }

    struct Person: Codable, Sendable, Hashable {
        var name: String
        var email: String?

        var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
    }

    struct Evidence: Codable, Sendable, Equatable {
        var quote: String
        /// "Me", "Them", "Mateo", or nil when the transcript has no speakers.
        var speaker: String?
        var speakerIsUser: Bool?
        /// Seconds from the start of the recording.
        var offset: TimeInterval?
        /// Wall-clock time it was said, when the meeting's start is known.
        var spokenAt: Date?
        /// 0–1: how much of the item the passage covers.
        var score: Double
    }

    /// Where the prepared action goes.
    struct Destination: Codable, Sendable, Equatable, Identifiable {
        /// "gmail", "mail", "slack", "calendar", "calendarApp", "linear",
        /// "clickup", "notion", "n8n", "reminder".
        var id: String
        var name: String
        var configured: Bool
        /// One line: why this one ("Notion · you've sent 4 items there").
        var reason: String
    }

    struct Slot: Codable, Sendable, Hashable {
        var start: Date
        var end: Date
    }

    struct CalendarProposal: Codable, Sendable, Equatable {
        var eventID: String?
        var eventTitle: String
        var currentStart: Date?
        var currentEnd: Date?
        var attendees: [Person] = []
        var slots: [Slot]
        /// LidIA can move it (an Apple Calendar event the user can edit).
        var editable: Bool
        /// "apple", "google" or "none".
        var source: String
        var note: String?
    }

    enum Artifact: Codable, Sendable, Equatable {
        case message(subject: String, body: String)
        case calendarChange(CalendarProposal)
        case ticket(title: String, body: String)
        case document(title: String, body: String)
        case reminder(title: String, notes: String?)
        case research(notes: String)
        case none
    }

    struct Link: Codable, Sendable, Hashable {
        var title: String
        var url: URL
    }

    var itemID: UUID
    var meetingID: UUID
    var kind: Kind
    var direction: Direction
    /// Who does it ("Alex Moreno", "Mateo").
    var owner: String?
    var ownerIsUser: Bool
    var recipients: [Person]
    /// "Northwind", "the Northwind team", "Mateo".
    var recipientLabel: String?
    /// Best first; unconfigured ones only when they're the best fit.
    var destinations: [Destination]
    var artifact: Artifact
    /// Only from a real web search; never invented.
    var links: [Link] = []
    /// Shown when the draft would want a link LidIA couldn't look up.
    var linkNote: String?
    var evidence: [Evidence]
    var verdict: Verdict
    /// 0–1, from the evidence (see `IntentConfidence`).
    var confidence: Double
    var confidenceReasons: [String]
    /// A corrected title when the item's direction was wrong.
    var suggestedTitle: String?
    /// The one button: "Send recap to Mateo", "Move Friday's meeting".
    var primaryLabel: String
    var computedAt: Date
    /// Changes when anything the intent reads changes.
    var inputFingerprint: String
    /// The model that wrote the draft, when one did.
    var draftedBy: String?
    var usedWebSearch = false
    /// Whether a weak or missing match asks the user to review the item.
    /// Only items LidIA extracted from its own transcript: imported notes'
    /// items paraphrase a summary and would all look "unsupported".
    var reviewable: Bool? = nil

    var id: UUID { itemID }

    var primaryDestination: Destination? { destinations.first }

    /// The best destination isn't set up: the button connects it instead.
    var needsConnection: Bool { primaryDestination.map { !$0.configured } ?? false }

    var bestEvidence: Evidence? { evidence.first }
}

extension ActionIntent.Evidence {
    /// "3:21" from the start of the recording.
    var offsetLabel: String? {
        guard let offset else { return nil }
        let total = Int(offset.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "Said at 8:07 by Them" / "Said at 3:21".
    func saidLabel(calendar: Calendar = .current) -> String {
        var when = ""
        if let spokenAt {
            var style = Date.FormatStyle.dateTime.hour().minute()
            style.timeZone = calendar.timeZone
            when = spokenAt.formatted(style)
        } else if let offsetLabel {
            when = offsetLabel
        }
        var text = when.isEmpty ? "Said" : "Said at \(when)"
        if let speaker, !speaker.isEmpty {
            text += speakerIsUser == true ? " by you" : " by \(speaker)"
        }
        return text
    }
}
