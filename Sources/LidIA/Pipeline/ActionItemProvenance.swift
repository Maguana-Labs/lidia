import Foundation

/// Tracks which action items the AI wrote and whether the user has touched them since.
///
/// The pipeline stamps every item it creates with a fingerprint of its user-editable
/// fields. Anything the user does — complete it, rename it, change owner, deadline or
/// priority, confirm a destination, export it to Notion or Reminders — changes the
/// fingerprint, which marks the item as the user's. Items without a fingerprint
/// (created by the user, voice, sync, or before this existed) are always the user's.
extension ActionItem {
    /// Fingerprint of the fields a user can change. `suggestedDestination` is excluded
    /// because the pipeline sets it after creating the item.
    var provenanceFingerprint: String {
        [
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            assignee ?? "",
            deadline ?? "",
            deadlineDate.map { String($0.timeIntervalSince1970) } ?? "",
            isCompleted ? "1" : "0",
            priority,
            confirmedDestination ?? "",
            notionBlockID ?? "",
            notionTaskPageID ?? "",
            reminderID ?? "",
        ].joined(separator: "\u{1F}")
    }

    /// Call right after the pipeline creates an item.
    func markAsAIGenerated() {
        aiFingerprint = provenanceFingerprint
    }

    /// True only for AI-created items the user has not changed in any way.
    var isUntouchedAIItem: Bool {
        guard let aiFingerprint else { return false }
        return aiFingerprint == provenanceFingerprint
    }

    /// True when the user owns this item (created or edited it). Regenerate keeps these.
    var isUserOwned: Bool { !isUntouchedAIItem }

    /// Normalised title for duplicate detection.
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
