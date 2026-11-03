import Foundation
import SwiftData

struct ActionItemNotionSyncService {
    struct SyncTarget {
        let item: ActionItem
        let meetingTitle: String
    }

    struct SyncResult {
        let createdCount: Int
        let updatedCount: Int

        var syncedCount: Int { createdCount + updatedCount }
    }

    enum SyncError: LocalizedError {
        case missingAPIKey
        case missingTasksDatabase
        case noItems

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Notion API key in Settings before exporting action items."
            case .missingTasksDatabase:
                return "Choose a Notion task tracker database in Settings before exporting action items."
            case .noItems:
                return "There are no action items to export."
            }
        }
    }

    @MainActor
    static func sync(
        targets: [SyncTarget],
        settings: AppSettings,
        modelContext: ModelContext
    ) async throws -> SyncResult {
        try PrivacyGate.check(.notion)
        guard !targets.isEmpty else { throw SyncError.noItems }
        guard !settings.notionAPIKey.isEmpty else { throw SyncError.missingAPIKey }
        guard !settings.notionTasksDatabaseID.isEmpty else { throw SyncError.missingTasksDatabase }

        // Copied out before the first await: items can be deleted while Notion answers.
        let entries = targets.map { target in
            (
                id: target.item.id,
                existingPageID: target.item.notionTaskPageID,
                title: target.item.title,
                deadline: target.item.deadlineDate,
                deadlineText: target.item.displayDeadline,
                isCompleted: target.item.isCompleted,
                meetingTitle: target.meetingTitle
            )
        }

        let client = NotionClient(apiKey: settings.notionAPIKey)
        let schema = try await client.fetchTaskDatabaseSchema(databaseID: settings.notionTasksDatabaseID)

        var createdCount = 0
        var updatedCount = 0

        for entry in entries {
            let notionPageID = try await client.createOrUpdateTaskPage(
                databaseID: settings.notionTasksDatabaseID,
                existingPageID: entry.existingPageID,
                schema: schema,
                title: entry.title,
                deadline: entry.deadline,
                deadlineText: entry.deadlineText,
                isCompleted: entry.isCompleted,
                meetingTitle: entry.meetingTitle
            )
            LiveModel.actionItem(entry.id, in: modelContext)?.notionTaskPageID = notionPageID
            if let existingPageID = entry.existingPageID, !existingPageID.isEmpty {
                updatedCount += 1
            } else {
                createdCount += 1
            }
        }

        try modelContext.save()
        return SyncResult(createdCount: createdCount, updatedCount: updatedCount)
    }
}
