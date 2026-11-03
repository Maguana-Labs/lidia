import Foundation
import LidIAKit
import SwiftData
import Testing
@testable import LidIA

@Suite("Sync safety")
struct SyncSafetyTests {

    @Test("Only the allowlisted file names are accepted")
    func fileNameAllowlist() {
        #expect(SyncSafety.isAllowedSyncedFileName("SOUL.md"))
        #expect(SyncSafety.isAllowedSyncedFileName("MEMORY.md"))
        for name in ["../SOUL.md", "/etc/passwd", "../../.ssh/authorized_keys", "soul.md", "SOUL.md/", "SOUL.md\u{0}", ""] {
            #expect(!SyncSafety.isAllowedSyncedFileName(name), "\(name) should be rejected")
        }
    }

    @Test("Identifiers must be canonical UUIDs")
    func identifiers() {
        let id = UUID()
        #expect(SyncSafety.identifier(id.uuidString) == id)
        #expect(SyncSafety.identifier(id.uuidString.lowercased()) == id)
        #expect(SyncSafety.identifier(nil) == nil)
        #expect(SyncSafety.identifier("../../x") == nil)
        #expect(SyncSafety.identifier("") == nil)
    }

    @Test("Server audio paths are never applied")
    func audioPaths() {
        #expect(SyncSafety.audioFilePath(local: nil, remote: "/etc/passwd") == nil)
        #expect(SyncSafety.audioFilePath(local: "/Users/me/a.m4a", remote: "/tmp/x") == "/Users/me/a.m4a")
    }

    @Test("Bearer token only goes over https or to private addresses")
    func serverURLs() {
        let allowed = [
            "https://sync.example.com", "https://1.2.3.4:8443", "http://localhost:8080",
            "http://127.0.0.1:9000", "http://192.168.1.20:8080", "http://10.0.0.5",
            "http://172.20.1.1", "http://100.101.102.103:8080", "http://my-mac.local:8080",
        ]
        let rejected = [
            "http://sync.example.com", "http://1.2.3.4", "ftp://example.com", "example.com",
            "https://user:pass@example.com", "http://172.32.0.1", "http://100.128.0.1", "",
        ]
        for url in allowed { #expect(SyncSafety.isAllowedServerURL(url), "\(url) should be allowed") }
        for url in rejected { #expect(!SyncSafety.isAllowedServerURL(url), "\(url) should be rejected") }
    }

    @MainActor
    @Test("Applying a hostile server response writes nothing outside the sync folder")
    func hostileResponse() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidia-sync-\(UUID().uuidString)", isDirectory: true)
        let syncDir = base.appendingPathComponent("dot-lidia", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let meetingID = UUID().uuidString
        let json: [String: Any] = [
            "server_time": 1,
            "meetings": [
                [
                    "id": meetingID, "title": "Synced", "date": 1_790_000_000_000, "duration": 60,
                    "raw_transcript": "", "refined_transcript": "t", "summary": "s", "status": "complete",
                    "notes": "", "audio_file_path": "/etc/passwd", "updated_at": 1,
                    "template_id": "../../nope",
                ],
                [
                    "id": "../../../etc", "title": "Bad", "date": 0, "duration": 0, "raw_transcript": "",
                    "refined_transcript": "", "summary": "", "status": "complete", "notes": "", "updated_at": 1,
                ],
            ],
            "action_items": [
                ["id": "not-a-uuid", "title": "Bad item", "is_completed": 0, "updated_at": 1],
            ],
            "deleted_meeting_ids": ["*"],
            "deleted_action_item_ids": [],
            "files": [
                "../escaped.md": "pwned",
                "/tmp/absolute.md": "pwned",
                "SOUL.md": "be kind",
            ],
        ]
        let response = try JSONDecoder().decode(SyncResponseDTO.self, from: JSONSerialization.data(withJSONObject: json))

        let container = try ModelContainer(
            for: Schema(versionedSchema: AppSchema.self),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let manager = SyncManager()
        manager.syncedFilesDirectory = syncDir.path
        manager.apply(response, in: context)

        let meetings = try context.fetch(FetchDescriptor<LidIA.Meeting>())
        #expect(meetings.count == 1)
        #expect(meetings.first?.id.uuidString == meetingID)
        #expect(meetings.first?.audioFilePath == nil)
        #expect(meetings.first?.templateID == nil)
        #expect(try context.fetch(FetchDescriptor<LidIA.ActionItem>()).isEmpty)

        #expect(try String(contentsOf: syncDir.appendingPathComponent("SOUL.md"), encoding: .utf8) == "be kind")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escaped.md").path))
        #expect(!FileManager.default.fileExists(atPath: syncDir.appendingPathComponent("absolute.md").path))
        let written = try FileManager.default.contentsOfDirectory(atPath: syncDir.path)
        #expect(written == ["SOUL.md"])
    }
}
