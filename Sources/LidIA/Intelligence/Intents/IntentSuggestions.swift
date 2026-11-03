import Foundation

/// Which prepared intents Today's "For You" shows, merged with the other
/// suggestions so one action item never appears twice.
enum IntentSuggestions {
    struct Candidate: Sendable, Equatable {
        var intent: ActionIntent
        var itemTitle: String
        var meetingID: UUID
        var meetingDate: Date
    }

    /// How recent a meeting's items must be to be suggested.
    static let maxAgeDays = 7

    /// Ready-to-run intents worth a card, best first: the user owes them,
    /// the transcript backs them, and the meeting is recent. A meeting that
    /// already has a follow-up email card doesn't also get a recap intent.
    static func pick(
        _ candidates: [Candidate],
        followUpMeetingIDs: Set<UUID>,
        now: Date = .now,
        limit: Int = 3
    ) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        return candidates
            .filter { candidate in
                let intent = candidate.intent
                guard candidate.meetingDate >= cutoff, !intent.verdict.needsReview else { return false }
                guard intent.ownerIsUser || intent.direction == .othersOweUser else { return false }
                if intent.kind == .reminder || intent.kind == .unclear { return false }
                if followUpMeetingIDs.contains(candidate.meetingID), intent.kind == .message,
                   FollowUpPlanner.isRecapPromise(candidate.itemTitle) { return false }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.meetingDate != rhs.meetingDate { return lhs.meetingDate > rhs.meetingDate }
                return lhs.intent.confidence > rhs.intent.confidence
            }
            .prefix(limit)
            .map { $0 }
    }

    /// An older post-meeting card ("Ticket draft", "Follow-up draft") about
    /// an item that now has an intent: the intent replaces it.
    static func isCoveredByIntent(actionItemTitle: String?, meetingID: UUID?, intents: [Candidate]) -> Bool {
        guard let title = actionItemTitle.map(ProjectCatalog.fold), !title.isEmpty else { return false }
        return intents.contains { candidate in
            (meetingID == nil || candidate.meetingID == meetingID)
                && (ProjectCatalog.fold(candidate.itemTitle) == title || candidate.intent.suggestedTitle.map(ProjectCatalog.fold) == title)
        }
    }

    /// A ticket card addressed to the user is a mistake: tickets go to a tracker.
    static func isSelfAddressed(recipient: String?, userName: String, userEmails: [String]) -> Bool {
        guard let recipient = recipient?.trimmingCharacters(in: .whitespaces).lowercased(), !recipient.isEmpty else { return false }
        if userEmails.map({ $0.lowercased() }).contains(recipient) { return true }
        return OwnerResolver.isUser(recipient, userName: userName)
            || (recipient.contains("@") && OwnerResolver.isUser(String(recipient.split(separator: "@")[0]), userName: userName))
    }
}
