import Foundation
import SwiftData

/// Re-fetches models by UUID after an `await`.
///
/// A meeting or action item held across an await can be deleted meanwhile: by the
/// user, by sync, by the MCP inbox or by the voice assistant, possibly in another
/// context. Reading or writing a deleted model traps inside SwiftData, so code that
/// keeps a model across an await re-checks it here first, using the UUID it copied
/// before the await. A fetch never touches the stale instance and skips rows deleted
/// in this context but not yet saved.
@MainActor
enum LiveModel {
    static func meeting(_ id: UUID, in context: ModelContext) -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func actionItem(_ id: UUID, in context: ModelContext) -> ActionItem? {
        var descriptor = FetchDescriptor<ActionItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Whether the meeting with `id` still exists in `context`.
    static func meetingExists(_ id: UUID, in context: ModelContext) -> Bool {
        meeting(id, in: context) != nil
    }

    /// Whether the action item with `id` still exists in `context`.
    static func actionItemExists(_ id: UUID, in context: ModelContext) -> Bool {
        actionItem(id, in: context) != nil
    }
}

/// When a meeting can be deleted. Deleting one that is being processed would leave
/// the pipeline writing to a deleted model, so it waits until processing ends.
enum MeetingDeletionPolicy {
    static let processingMessage = String(localized: "LidIA is still processing this meeting. You can delete it once processing finishes.")

    /// Why the meeting can't be deleted now, or nil when it can.
    /// A queued meeting that isn't being processed can be deleted: it is taken off the
    /// queue first, and the queue re-fetches each meeting before processing it.
    static func blockReason(status: MeetingStatus, isBeingProcessed: Bool) -> String? {
        if status == .recording { return String(localized: "Stop the recording before deleting this meeting.") }
        if status == .processing || isBeingProcessed { return processingMessage }
        return nil
    }
}
