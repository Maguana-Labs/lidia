import Foundation
import SwiftData
import Testing
@testable import LidIA

/// With iCloud sync, a meeting another device is still recording or processing arrives
/// here mid-flight. Launch recovery must leave it to that device.
@MainActor
@Suite("Synced meetings belong to the device that made them")
struct SyncedMeetingOwnershipTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LidIASchema.schema,
            configurations: [ModelConfiguration(schema: LidIASchema.schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Processing recovery skips another device's meetings")
    func processingRecoverySkipsForeignMeetings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let mine = Meeting(title: "Mine", status: .processing, notes: "- point")
        let theirs = Meeting(title: "iPhone's", status: .processing, notes: "- point", originDeviceID: "iphone")
        let unknown = Meeting(title: "Unknown origin", status: .queued, originDeviceID: nil)
        for meeting in [mine, theirs, unknown] { context.insert(meeting) }
        try context.save()

        let queue = DeferredMeetingProcessingQueue(defaults: UserDefaults(suiteName: "lidia.tests.ownership.\(UUID().uuidString)")!)
        let report = await ProcessingRecovery.recover(
            in: context, queue: queue, progressCenter: ProcessingProgressCenter(), recordingsRoot: root
        )
        #expect(report.requeued == [mine.id])
        #expect(report.failed.isEmpty)
        #expect(mine.status == .queued)
        #expect(theirs.status == .processing)
        #expect(theirs.processingError == nil)
        #expect(unknown.status == .queued)
    }

    @Test("Recording recovery leaves a recording on another device alone")
    func recordingRecoverySkipsForeignRecordings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext()
        let theirs = Meeting(title: "Recording on iPhone", status: .recording, originDeviceID: "iphone")
        let mine = Meeting(title: "Crashed here", status: .recording)
        context.insert(theirs)
        context.insert(mine)
        try context.save()

        let outcome = await RecordingRecovery.recoverInterruptedRecordings(
            modelContext: context, excluding: nil, recordingsRoot: root,
            transcribe: { _, _ in [] }, enqueue: { _ in }, progressCenter: ProcessingProgressCenter()
        )
        #expect(theirs.status == .recording)
        #expect(theirs.processingError == nil)
        #expect(!outcome.failed.contains(theirs.id))
        // This Mac's own interrupted recording (no audio, no words) is still failed.
        #expect(outcome.failed == [mine.id])
        #expect(mine.status == .failed)
    }

    @Test("Meetings from the self-hosted sync server aren't this device's")
    func serverSyncedMeetingsAreForeign() throws {
        let context = try makeContext()
        let json: [String: Any] = [
            "server_time": 1,
            "meetings": [[
                "id": UUID().uuidString, "title": "From server", "date": 1_790_000_000_000, "duration": 60,
                "raw_transcript": "", "refined_transcript": "", "summary": "", "status": "processing",
                "notes": "", "audio_file_path": "/elsewhere/a.m4a", "updated_at": 1,
            ]],
            "action_items": [],
            "deleted_meeting_ids": [],
            "deleted_action_item_ids": [],
        ]
        let response = try JSONDecoder().decode(SyncResponseDTO.self, from: JSONSerialization.data(withJSONObject: json))
        SyncManager().apply(response, in: context)
        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.originDeviceID == nil)
        #expect(!meeting.isOwnedByThisDevice)
        #expect(meeting.audioFilePath == nil)
    }
}
