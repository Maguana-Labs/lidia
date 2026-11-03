import Foundation
import SwiftData
import os

/// Reconciles server sync data with local SwiftData store.
/// Used by both macOS and iOS apps.
@MainActor
public final class SyncEngine {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "SyncEngine")

    private let client: SyncClient
    private let modelContainer: ModelContainer

    public init(client: SyncClient, modelContainer: ModelContainer) {
        self.client = client
        self.modelContainer = modelContainer
    }

    // MARK: - Apply Incoming Sync

    /// Apply a sync response to the local SwiftData store.
    public func apply(_ response: SyncResponse) {
        let context = modelContainer.mainContext

        // Apply meeting changes
        for syncMeeting in response.meetings {
            applyMeeting(syncMeeting, in: context)
        }

        // Apply meeting deletions
        for deletedID in response.deletedMeetingIDs {
            deleteMeeting(id: deletedID, in: context)
        }

        // Apply action item changes
        for syncItem in response.actionItems {
            applyActionItem(syncItem, in: context)
        }

        // Apply action item deletions
        for deletedID in response.deletedActionItemIDs {
            deleteActionItem(id: deletedID, in: context)
        }

        // Apply file changes
        if let files = response.files {
            for (name, content) in files {
                applyFile(name: name, content: content)
            }
        }

        do {
            try context.save()
            Self.logger.info("Sync applied: \(response.meetings.count) meetings, \(response.actionItems.count) items, \(response.deletedMeetingIDs.count) deleted meetings, \(response.deletedActionItemIDs.count) deleted items")
        } catch {
            Self.logger.error("Failed to save sync: \(error)")
        }
    }

    // MARK: - Push Local Changes

    /// Push a meeting to the server immediately.
    public func pushMeeting(_ meeting: Meeting) async {
        let dto = SyncMeeting(from: meeting)
        let success = await client.pushMeeting(dto)
        if success {
            Self.logger.debug("Pushed meeting: \(meeting.title)")
        }
    }

    /// Push an action item to the server immediately.
    public func pushActionItem(_ item: ActionItem) async {
        let dto = SyncActionItem(from: item)
        let success = await client.pushActionItem(dto)
        if success {
            Self.logger.debug("Pushed action item: \(item.title)")
        }
    }

    /// Push a file to the server.
    public func pushFile(name: String, content: String) async {
        await client.pushFile(name: name, content: content)
    }

    /// Push settings to the server.
    public func pushSettings(_ settings: [String: String]) async {
        await client.pushSettings(settings)
    }

    // MARK: - Private: Apply Changes

    private func applyMeeting(_ sync: SyncMeeting, in context: ModelContext) {
        guard let uuid = SyncSafety.identifier(sync.id) else {
            Self.logger.warning("Ignored synced meeting with an invalid ID")
            return
        }

        let existing = fetchMeeting(id: uuid, in: context)

        if let meeting = existing {
            // Update existing
            meeting.title = sync.title
            meeting.date = Date(timeIntervalSince1970: Double(sync.date) / 1000)
            meeting.duration = sync.duration
            meeting.refinedTranscript = sync.refinedTranscript
            meeting.summary = sync.summary
            meeting.status = MeetingStatus(rawValue: sync.status) ?? .complete
            meeting.notes = sync.notes
            meeting.folder = sync.folder
            // Audio paths are device-local; never take one from the server.
            meeting.audioFilePath = SyncSafety.audioFilePath(local: meeting.audioFilePath, remote: sync.audioFilePath)
            meeting.userEditedTranscript = sync.userEditedTranscript
            meeting.userEditedSummary = sync.userEditedSummary
            meeting.calendarEventID = sync.calendarEventID
            meeting.calendarAttendees = decodeAttendees(sync.calendarAttendees)
            meeting.templateID = SyncSafety.identifier(sync.templateID)
        } else {
            // Create new
            let meeting = Meeting(
                title: sync.title,
                date: Date(timeIntervalSince1970: Double(sync.date) / 1000),
                duration: sync.duration,
                refinedTranscript: sync.refinedTranscript,
                summary: sync.summary,
                status: MeetingStatus(rawValue: sync.status) ?? .complete,
                audioFilePath: nil,
                userEditedTranscript: sync.userEditedTranscript,
                userEditedSummary: sync.userEditedSummary,
                calendarEventID: sync.calendarEventID,
                calendarAttendees: decodeAttendees(sync.calendarAttendees),
                templateID: SyncSafety.identifier(sync.templateID),
                notes: sync.notes,
                folder: sync.folder,
                // Made on another device: this one must not recover or process it.
                originDeviceID: nil
            )
            // Preserve the server's UUID
            meeting.id = uuid
            context.insert(meeting)
        }
    }

    private func deleteMeeting(id: String, in context: ModelContext) {
        guard let uuid = SyncSafety.identifier(id) else { return }
        if let meeting = fetchMeeting(id: uuid, in: context) {
            context.delete(meeting)
        }
    }

    private func applyActionItem(_ sync: SyncActionItem, in context: ModelContext) {
        guard let uuid = SyncSafety.identifier(sync.id) else {
            Self.logger.warning("Ignored synced action item with an invalid ID")
            return
        }

        let existing = fetchActionItem(id: uuid, in: context)

        if let item = existing {
            // Update
            item.title = sync.title
            item.assignee = sync.assignee
            item.deadline = sync.deadline
            item.deadlineDate = sync.deadlineDate.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            item.isCompleted = sync.isCompleted != 0

            // Re-link meeting if needed
            if let meetingUUID = SyncSafety.identifier(sync.meetingID) {
                if item.meeting?.id != meetingUUID {
                    item.meeting = fetchMeeting(id: meetingUUID, in: context)
                }
            }
        } else {
            // Create new
            let item = ActionItem(
                title: sync.title,
                assignee: sync.assignee,
                deadline: sync.deadline,
                deadlineDate: sync.deadlineDate.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                isCompleted: sync.isCompleted != 0
            )
            item.id = uuid
            context.insert(item)

            // Link to meeting
            if let meetingUUID = SyncSafety.identifier(sync.meetingID) {
                item.meeting = fetchMeeting(id: meetingUUID, in: context)
            }
        }
    }

    private func deleteActionItem(id: String, in context: ModelContext) {
        guard let uuid = SyncSafety.identifier(id) else { return }
        if let item = fetchActionItem(id: uuid, in: context) {
            context.delete(item)
        }
    }

    /// Files the server may write. The name comes from the server, so anything
    /// else (including path components like `../`) is ignored.
    private func applyFile(name: String, content: String) {
        guard SyncSafety.isAllowedSyncedFileName(name) else {
            Self.logger.warning("Ignored synced file with unexpected name")
            return
        }
        let dir = LidIAFiles.lidiaDir
        let path = "\(dir)/\(name)"
        let dirURL = URL(fileURLWithPath: dir)

        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        Self.logger.debug("Applied file: \(name)")
    }

    // MARK: - Fetch Helpers

    private func fetchMeeting(id: UUID, in context: ModelContext) -> Meeting? {
        let descriptor = FetchDescriptor<Meeting>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.id == id }
    }

    private func fetchActionItem(id: UUID, in context: ModelContext) -> ActionItem? {
        let descriptor = FetchDescriptor<ActionItem>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.id == id }
    }

    private func decodeAttendees(_ json: String?) -> [String]? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return arr
    }
}
