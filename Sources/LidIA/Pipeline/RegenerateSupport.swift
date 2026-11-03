import Foundation
import SwiftData

/// What a Regenerate would change, so the UI can decide whether to confirm.
struct RegenerateImpact: Sendable, Equatable {
    /// Action items the user created, completed, edited or exported. Always kept.
    let keptUserItems: Int
    /// Untouched AI action items that will be replaced.
    let replacedAIItems: Int
    /// The user edited the summary or transcript and Regenerate will overwrite it.
    let overwritesUserEdits: Bool

    /// True when the UI should ask before regenerating: the user's own edits would be
    /// overwritten. Replacing untouched AI items alone does not need a prompt — it can
    /// be undone with the `RegenerateSnapshot` returned by `regenerate`.
    var requiresConfirmation: Bool { overwritesUserEdits }
}

/// Everything Regenerate may change, captured before it runs. Pass it to
/// `MeetingPipeline.undoRegenerate` to revert what Regenerate changed (and only that).
struct RegenerateSnapshot: Sendable {
    struct ActionItemValue: Sendable, Equatable {
        let id: UUID
        let title: String
        let assignee: String?
        let deadline: String?
        let deadlineDate: Date?
        let isCompleted: Bool
        let notionBlockID: String?
        let notionTaskPageID: String?
        let reminderID: String?
        let sourceQuote: String?
        let priority: String
        let suggestedDestination: String?
        let confirmedDestination: String?
        let aiFingerprint: String?
    }

    let meetingID: UUID
    let title: String
    let summary: String
    let structuredSummary: Data?
    let refinedTranscript: String
    let userEditedSummary: String?
    let userEditedTranscript: String?
    let status: MeetingStatus
    let processingError: String?
    let templateID: UUID?
    let actionItems: [ActionItemValue]
    let takenAt: Date
    /// Items Regenerate itself inserted. Undo deletes only those still untouched.
    var insertedActionItemIDs: Set<UUID> = []
    /// Items Regenerate itself deleted (replaced). Undo brings only those back.
    var removedActionItemIDs: Set<UUID> = []
}

extension MeetingPipeline {
    static func regenerateImpact(for meeting: Meeting, overwriteUserEdits: Bool = false) -> RegenerateImpact {
        let replaceable = meeting.actionItems.filter(\.isUntouchedAIItem).count
        let hasEdits = !(meeting.userEditedSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return RegenerateImpact(
            keptUserItems: meeting.actionItems.count - replaceable,
            replacedAIItems: replaceable,
            overwritesUserEdits: overwriteUserEdits && hasEdits
        )
    }

    static func snapshot(of meeting: Meeting) -> RegenerateSnapshot {
        RegenerateSnapshot(
            meetingID: meeting.id,
            title: meeting.title,
            summary: meeting.summary,
            structuredSummary: meeting.structuredSummary,
            refinedTranscript: meeting.refinedTranscript,
            userEditedSummary: meeting.userEditedSummary,
            userEditedTranscript: meeting.userEditedTranscript,
            status: meeting.status,
            processingError: meeting.processingError,
            templateID: meeting.templateID,
            actionItems: meeting.actionItems.map {
                .init(
                    id: $0.id, title: $0.title, assignee: $0.assignee, deadline: $0.deadline,
                    deadlineDate: $0.deadlineDate, isCompleted: $0.isCompleted,
                    notionBlockID: $0.notionBlockID, notionTaskPageID: $0.notionTaskPageID,
                    reminderID: $0.reminderID, sourceQuote: $0.sourceQuote, priority: $0.priority,
                    suggestedDestination: $0.suggestedDestination,
                    confirmedDestination: $0.confirmedDestination, aiFingerprint: $0.aiFingerprint
                )
            },
            takenAt: Date()
        )
    }

    /// Re-runs processing on an existing meeting while keeping the user's work:
    /// user-created, completed, edited or exported action items are kept; only untouched
    /// AI items are replaced. With `overwriteUserEdits == false` the user's edited summary
    /// and transcript are kept too.
    ///
    /// Do NOT delete action items or clear the summary before calling this.
    ///
    /// - Returns: a snapshot for an Undo button (`undoRegenerate`).
    /// - Throws: the processing error. On failure the meeting is restored to its previous
    ///   state (so a complete meeting stays complete) before the error is rethrown.
    @discardableResult
    func regenerate(
        meeting: Meeting,
        model: String,
        template: MeetingTemplate? = nil,
        vocabulary: [AppSettings.VocabularyEntry] = [],
        overwriteUserEdits: Bool = false
    ) async throws -> RegenerateSnapshot {
        let meetingID = meeting.id
        var snapshot = Self.snapshot(of: meeting)
        var failure: Error?
        do {
            try await process(
                meeting: meeting,
                model: model,
                template: template,
                vocabulary: vocabulary,
                preserveUserEdits: !overwriteUserEdits
            )
            if meeting.status == .failed {
                // e.g. no model selected: process() marks the meeting failed without throwing.
                failure = RegenerateError.failed(meeting.processingError ?? String(localized: "Regenerate failed."))
            }
        } catch {
            failure = error
        }
        // Record exactly what this run changed, so undo never touches anything else
        // (items the user typed, the MCP inbox or sync added while the LLM ran).
        let changes = actionItemChanges.removeValue(forKey: meetingID) ?? ActionItemChanges()
        snapshot.insertedActionItemIDs = changes.inserted
        snapshot.removedActionItemIDs = changes.removed
        guard let failure else { return snapshot }

        // A deleted meeting has nothing to restore.
        if snapshot.status == .complete, failure as? PipelineError != .meetingDeleted {
            // Keep the previous good result visible; the caller shows the error.
            Self.undoRegenerate(snapshot, meeting: meeting, modelContext: modelContext)
        }
        throw failure
    }

    /// Restores the meeting's fields to the snapshot and reverts Regenerate's own
    /// action-item changes: items it inserted are deleted only while they are still
    /// untouched AI items, and items it replaced come back with their IDs. Everything
    /// else — items the user added, completed or edited, or that arrived from the MCP
    /// inbox or sync during or after the run — is kept.
    static func undoRegenerate(_ snapshot: RegenerateSnapshot, meeting: Meeting, modelContext: ModelContext) {
        guard snapshot.meetingID == meeting.id else { return }
        meeting.title = snapshot.title
        meeting.summary = snapshot.summary
        meeting.structuredSummary = snapshot.structuredSummary
        meeting.refinedTranscript = snapshot.refinedTranscript
        meeting.userEditedSummary = snapshot.userEditedSummary
        meeting.userEditedTranscript = snapshot.userEditedTranscript
        meeting.status = snapshot.status
        meeting.processingError = snapshot.processingError
        meeting.templateID = snapshot.templateID

        let toDelete = meeting.actionItems.filter {
            snapshot.insertedActionItemIDs.contains($0.id) && $0.isUntouchedAIItem
        }
        for item in toDelete {
            meeting.actionItems.removeAll { $0.id == item.id }
            modelContext.delete(item)
        }
        let present = Set(meeting.actionItems.map(\.id))
        for value in snapshot.actionItems
        where snapshot.removedActionItemIDs.contains(value.id) && !present.contains(value.id) {
            let item = ActionItem(
                title: value.title,
                assignee: value.assignee,
                deadline: value.deadline,
                deadlineDate: value.deadlineDate,
                isCompleted: value.isCompleted,
                notionBlockID: value.notionBlockID,
                notionTaskPageID: value.notionTaskPageID,
                reminderID: value.reminderID
            )
            item.id = value.id
            item.sourceQuote = value.sourceQuote
            item.priority = value.priority
            item.suggestedDestination = value.suggestedDestination
            item.confirmedDestination = value.confirmedDestination
            item.aiFingerprint = value.aiFingerprint
            meeting.actionItems.append(item)
        }
        try? modelContext.save()
    }
}

enum RegenerateError: LocalizedError, Equatable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
