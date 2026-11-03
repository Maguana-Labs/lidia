import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import LidIA

// End-to-end tests for the LidiaMCP server and the app-side inbox importer.
//
// They build a real SwiftData store with the app's schema, run the compiled
// `LidiaMCP` binary against it over stdin/stdout, check the store file is
// byte-for-byte unchanged, then let `MCPInboxImporter` apply the queued writes.

private enum MCPBinary {
    /// `.build/<config>/LidiaMCP`, next to the test bundle.
    static let url: URL? = {
        let candidates: [URL] = {
            var list: [URL] = []
            // The test bundle lives in the same build products directory.
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                list.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("LidiaMCP"))
            }
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            list.append(root.appendingPathComponent(".build/debug/LidiaMCP"))
            return list
        }()
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()
}

private struct MCPFixture {
    let dir: URL
    let storeURL: URL
    let inboxURL: URL
    let container: ModelContainer
    let meetingID: UUID
    let keptItemID: UUID
    let doomedItemID: UUID

    @MainActor
    static func make() throws -> MCPFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidia-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("lidia.store")
        let schema = Schema(versionedSchema: AppSchema.self)
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let meeting = Meeting(title: "Quarterly planning", date: Date(timeIntervalSince1970: 1_790_000_000))
        meeting.summary = "We agreed on the roadmap."
        meeting.refinedTranscript = "Alice: let's ship the widget."
        meeting.notes = "Original notes"
        meeting.calendarAttendees = ["alice@example.com"]
        meeting.status = .complete
        context.insert(meeting)
        let kept = ActionItem(title: "Draft roadmap", assignee: "Alice", deadline: "2026-11-10")
        let doomed = ActionItem(title: "Cancel offsite")
        context.insert(kept)
        context.insert(doomed)
        kept.meeting = meeting
        doomed.meeting = meeting
        try context.save()

        return MCPFixture(
            dir: dir, storeURL: storeURL, inboxURL: dir.appendingPathComponent("inbox", isDirectory: true),
            container: container, meetingID: meeting.id, keptItemID: kept.id, doomedItemID: doomed.id
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// SHA-256 of the store and its WAL: what a writer would change.
    func storeDigest() throws -> String {
        var hasher = SHA256()
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            if let data = try? Data(contentsOf: url) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs the MCP server with `requests` (one JSON-RPC message per line) and
    /// returns the decoded responses keyed by id.
    func runServer(_ requests: [[String: Any]]) throws -> [Int: [String: Any]] {
        let binary = try #require(MCPBinary.url)
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["LIDIA_STORE_PATH"] = storeURL.path
        env["LIDIA_MCP_INBOX"] = inboxURL.path
        process.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        var input = Data()
        for request in requests {
            input.append(try JSONSerialization.data(withJSONObject: request))
            input.append(0x0A)
        }
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var responses: [Int: [String: Any]] = [:]
        for line in output.split(separator: 0x0A) where !line.isEmpty {
            let json = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            if let id = json["id"] as? Int { responses[id] = json }
        }
        return responses
    }
}

private func call(_ id: Int, _ tool: String, _ arguments: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
}

/// The JSON a tool returned, and whether it was an error.
private func toolPayload(_ response: [String: Any]?) throws -> (json: Any, isError: Bool) {
    let result = try #require(response?["result"] as? [String: Any])
    let content = try #require(result["content"] as? [[String: Any]])
    let text = try #require(content.first?["text"] as? String)
    let isError = result["isError"] as? Bool ?? false
    if isError { return (text, true) }
    return (try JSONSerialization.jsonObject(with: Data(text.utf8)), false)
}

@Suite("LidiaMCP server", .enabled(if: MCPBinary.url != nil, "LidiaMCP binary not built"), .serialized)
struct MCPServerTests {

    @MainActor
    @Test("Reads work against a real SwiftData store, including UUID lookups")
    func readsFromRealStore() throws {
        let fixture = try MCPFixture.make()
        defer { fixture.cleanUp() }

        let responses = try fixture.runServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            call(3, "get_meeting", ["meeting_id": fixture.meetingID.uuidString]),
            call(4, "search_meetings", ["query": "widget"]),
            call(5, "get_action_items", ["status": "pending"]),
            call(6, "search_meetings", ["query": "%"]),
        ])

        // Notifications get no response; every request does.
        #expect(responses.keys.sorted() == [1, 2, 3, 4, 5, 6])

        let tools = try #require((responses[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == [
            "search_meetings", "get_action_items", "get_meeting", "create_action_item",
            "update_action_item", "delete_action_item", "mark_action_item_done", "update_meeting_notes",
        ])

        let meeting = try #require((try toolPayload(responses[3]).json as? [[String: Any]])?.first)
        #expect(meeting["id"] as? String == fixture.meetingID.uuidString)
        #expect(meeting["title"] as? String == "Quarterly planning")
        #expect(meeting["notes"] as? String == "Original notes")
        #expect(meeting["attendees"] as? [String] == ["alice@example.com"])
        let items = try #require(meeting["actionItems"] as? [[String: Any]])
        #expect(Set(items.compactMap { $0["id"] as? String }) == [fixture.keptItemID.uuidString, fixture.doomedItemID.uuidString])

        let found = try #require(try toolPayload(responses[4]).json as? [[String: Any]])
        #expect(found.count == 1)

        let pending = try #require(try toolPayload(responses[5]).json as? [[String: Any]])
        #expect(pending.count == 2)
        #expect(pending.allSatisfy { $0["meetingId"] as? String == fixture.meetingID.uuidString })

        // LIKE wildcards in the query are matched literally.
        let wildcard = try #require(try toolPayload(responses[6]).json as? [[String: Any]])
        #expect(wildcard.isEmpty)
    }

    @MainActor
    @Test("Writes never touch the database; the app applies them from the inbox")
    func writesGoThroughInbox() throws {
        let fixture = try MCPFixture.make()
        defer { fixture.cleanUp() }
        let before = try fixture.storeDigest()

        let responses = try fixture.runServer([
            call(1, "create_action_item", [
                "title": "Book venue", "assignee": "Bob", "deadline": "2026-12-01",
                "meeting_id": fixture.meetingID.uuidString,
            ]),
            call(2, "update_action_item", ["id": fixture.keptItemID.uuidString, "title": "Publish roadmap"]),
            call(3, "mark_action_item_done", ["id": fixture.keptItemID.uuidString]),
            call(4, "delete_action_item", ["id": fixture.doomedItemID.uuidString]),
            call(5, "update_meeting_notes", ["id": fixture.meetingID.uuidString, "notes": "Updated by Claude"]),
            // Rejected up front: these never reach the inbox.
            call(6, "create_action_item", ["title": "Orphan", "meeting_id": UUID().uuidString]),
            call(7, "update_action_item", ["id": UUID().uuidString, "title": "Nope"]),
            call(8, "create_action_item", ["title": "   "]),
            call(9, "update_meeting_notes", ["id": "not-a-uuid", "notes": "x"]),
        ])

        // The store is untouched.
        #expect(try fixture.storeDigest() == before)

        let created = try #require((try toolPayload(responses[1]).json as? [[String: Any]])?.first)
        #expect(created["status"] as? String == "queued")
        let newID = try #require((created["id"] as? String).flatMap(UUID.init(uuidString:)))

        let updated = try #require((try toolPayload(responses[2]).json as? [[String: Any]])?.first)
        #expect(updated["title"] as? String == "Publish roadmap")
        #expect(updated["assignee"] as? String == "Alice")

        for id in 6...9 {
            #expect(try toolPayload(responses[id]).isError, "request \(id) should be rejected")
        }

        let queued = try FileManager.default.contentsOfDirectory(atPath: fixture.inboxURL.path)
            .filter { $0.hasSuffix(".json") }
        #expect(queued.count == 5)

        // The app applies the queue.
        let importer = MCPInboxImporter(directory: fixture.inboxURL)
        let context = ModelContext(fixture.container)
        let pass = importer.importPending(into: context)
        #expect(pass == MCPInboxImporter.PassResult(applied: 5, rejected: 0))

        let fresh = ModelContext(fixture.container)
        let items = try fresh.fetch(FetchDescriptor<ActionItem>())
        let newItem = try #require(items.first { $0.id == newID })
        #expect(newItem.title == "Book venue")
        #expect(newItem.assignee == "Bob")
        #expect(newItem.meeting?.id == fixture.meetingID)
        #expect(newItem.deadlineDate != nil)
        #expect(newItem.priority == "none")

        let kept = try #require(items.first { $0.id == fixture.keptItemID })
        #expect(kept.title == "Publish roadmap")
        #expect(kept.isCompleted)
        #expect(!items.contains { $0.id == fixture.doomedItemID })

        let meeting = try #require(try fresh.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.notes == "Updated by Claude")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.inboxURL.path)
            .filter { $0.hasSuffix(".json") }
        #expect(remaining.isEmpty)
    }

    @MainActor
    @Test("The server refuses a database that isn't LidIA's")
    func refusesForeignStore() throws {
        let fixture = try MCPFixture.make()
        defer { fixture.cleanUp() }
        let foreign = fixture.dir.appendingPathComponent("other.store")
        try Data("not a database".utf8).write(to: foreign)

        let binary = try #require(MCPBinary.url)
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["LIDIA_STORE_PATH"] = foreign.path
        env["LIDIA_MCP_INBOX"] = fixture.inboxURL.path
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: call(1, "get_action_items", [:])) + Data([0x0A]))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let line = try #require(output.split(separator: 0x0A).first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        #expect(try toolPayload(json).isError)
    }
}

// MARK: - Importer validation

@Suite("MCP inbox importer")
@MainActor
struct MCPInboxImporterTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: AppSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeInbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidia-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: [String: Any], to inbox: URL, name: String = UUID().uuidString) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: inbox.appendingPathComponent("\(name).json"))
    }

    private func request(_ operation: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "version": 1, "request_id": UUID().uuidString,
            "created_at": "2026-11-02T10:00:00Z", "operation": operation,
        ]
        base.merge(extra) { _, new in new }
        return base
    }

    @Test("Invalid requests are moved to Rejected with a reason and change nothing")
    func rejectsInvalidRequests() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox) }

        try write(request("create_action_item", ["action_item_id": "nope", "title": "x"]), to: inbox, name: "a")
        try write(request("create_action_item", ["action_item_id": UUID().uuidString]), to: inbox, name: "b")
        try write(request("create_action_item", ["action_item_id": UUID().uuidString, "title": "x",
                                                 "meeting_id": UUID().uuidString]), to: inbox, name: "c")
        try write(request("create_action_item", ["action_item_id": UUID().uuidString,
                                                 "title": String(repeating: "x", count: 501)]), to: inbox, name: "d")
        var future = request("create_action_item", ["action_item_id": UUID().uuidString, "title": "x"])
        future["version"] = 99
        try write(future, to: inbox, name: "e")
        try write(request("update_action_item", ["action_item_id": UUID().uuidString, "title": "x"]), to: inbox, name: "f")
        try Data("{ not json".utf8).write(to: inbox.appendingPathComponent("g.json"))
        try write(request("drop_tables"), to: inbox, name: "h")

        let importer = MCPInboxImporter(directory: inbox)
        let result = importer.importPending(into: context)
        #expect(result == MCPInboxImporter.PassResult(applied: 0, rejected: 8))
        #expect(try context.fetch(FetchDescriptor<ActionItem>()).isEmpty)

        let rejected = try FileManager.default.contentsOfDirectory(atPath: importer.rejectedDirectory.path)
        #expect(rejected.filter { $0.hasSuffix(".json") }.count == 8)
        #expect(rejected.filter { $0.hasSuffix(".reason.txt") }.count == 8)
        let reason = try String(contentsOf: importer.rejectedDirectory.appendingPathComponent("c.reason.txt"), encoding: .utf8)
        #expect(reason == "Meeting not found")
    }

    @Test("Creating the same item twice is applied once and never overwrites")
    func createIsIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox) }

        let existing = ActionItem(title: "Existing")
        context.insert(existing)
        try context.save()

        let newID = UUID().uuidString
        try write(request("create_action_item", ["action_item_id": newID, "title": "First"]), to: inbox, name: "1")
        try write(request("create_action_item", ["action_item_id": newID, "title": "Second"]), to: inbox, name: "2")
        try write(request("create_action_item", ["action_item_id": existing.id.uuidString, "title": "Hijack"]), to: inbox, name: "3")

        let result = MCPInboxImporter(directory: inbox).importPending(into: context)
        #expect(result.applied == 1)
        #expect(result.rejected == 0)

        let items = try context.fetch(FetchDescriptor<ActionItem>())
        #expect(items.count == 2)
        #expect(items.first { $0.id.uuidString == newID }?.title == "First")
        #expect(items.first { $0.id == existing.id }?.title == "Existing")
    }

    @Test("Symlinks in the inbox are not followed")
    func ignoresSymlinks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let inbox = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox) }

        let outside = inbox.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: request("create_action_item", [
            "action_item_id": UUID().uuidString, "title": "From outside",
        ])).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("link.json"), withDestinationURL: outside)

        let result = MCPInboxImporter(directory: inbox).importPending(into: context)
        #expect(result.rejected == 1)
        #expect(try context.fetch(FetchDescriptor<ActionItem>()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
