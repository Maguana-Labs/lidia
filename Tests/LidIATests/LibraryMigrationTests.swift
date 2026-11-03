import Foundation
import SQLite3
import SwiftData
import Testing
@testable import LidIA

/// Opening a schema-3.3 library with the CloudKit-compatible schema 4.0 must keep every
/// meeting, transcript, summary, action item and chat exactly as it was.
///
/// `Fixtures/LibraryV3/LidIA.store` was written by the schema-3.3 models (the Mac's
/// `Sources/LidIA/Models` at commit 0268d2f): three meetings (one with a 1,500-word
/// transcript and a 45,000-character refined transcript), three action items with AI
/// fingerprints and board columns, a chat thread with two messages, a talking point and
/// an inbox notification.
@MainActor
@Suite("Library migration to the iCloud schema")
struct LibraryMigrationTests {
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LibraryV3/LidIA.store")
    }

    @Test("The schema-3.3 fixture opens with the new schema, nothing lost")
    func fixtureMigrates() throws {
        let work = try LibraryCopy(of: Self.fixtureURL)
        defer { work.remove() }
        let before = try StoreSnapshot(url: work.storeURL)
        #expect(before.meetings.count == 3)
        #expect(before.indexes.contains("Z_ChatThreadModel_UNIQUE_id"))

        do {
            let container = try work.openWithCurrentSchema()
            let context = container.mainContext
            let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date)]))
            #expect(meetings.map(\.title) == ["Weekly sync", "Failed one", "Queued one"])

            let weekly = meetings[0]
            #expect(weekly.status == .complete)
            #expect(weekly.rawTranscript.count == 1_500)
            #expect(weekly.rawTranscript[3].speakerName == "Ana")
            #expect(weekly.rawTranscript[5].isLocalSpeaker == true)
            #expect(weekly.refinedTranscript.count == 45_000)
            #expect(weekly.summary == "## Decisions\n- Ship beta Friday")
            #expect(weekly.userEditedSummary == "## Decisions\n- Ship beta Friday (edited)")
            #expect(weekly.calendarAttendees == ["ana@example.com", "bo@example.com"])
            #expect(weekly.externalSourceID == "granola:abc-123")
            #expect(weekly.templateAutoDetected == false)
            #expect(weekly.structuredSummary == Data("{\"sections\":[]}".utf8))
            #expect(weekly.folder == "Work")
            #expect(weekly.audioFilePath?.hasSuffix("m1/audio.m4a") == true)
            // Existing meetings have no origin until the launch claim stamps them.
            #expect(weekly.originDeviceID == nil)

            let items = weekly.actionItems.sorted { $0.title < $1.title }
            #expect(items.map(\.title) == ["Book venue", "Send pricing deck", "User added item"])
            #expect(items.map(\.aiFingerprint) == ["fp-stale", "fp-untouched", nil])
            #expect(items.map(\.boardStatus) == [.done, .todo, .inProgress])
            #expect(items[1].priority == "high")
            #expect(items[1].sourceQuote == "I'll send the pricing deck")
            #expect(items[2].reminderID == "rem-1")
            #expect(items.allSatisfy { $0.meeting === weekly })

            #expect(meetings[1].status == .failed)
            #expect(meetings[1].processingError == "No speech")
            #expect(meetings[2].status == .queued)
            #expect(meetings[2].processingRetryCount == 2)

            let threads = try context.fetch(FetchDescriptor<ChatThreadModel>())
            #expect(threads.count == 1)
            #expect(threads.first?.messages.count == 2)
            #expect(threads.first?.messages.contains { $0.groundingConfidenceRawValue == "high" } == true)

            let inbox = try context.fetch(FetchDescriptor<InboxNotification>())
            #expect(inbox.first?.draft == "Hi")
            #expect(inbox.first?.meetingID == weekly.id)
            #expect(try context.fetchCount(FetchDescriptor<TalkingPoint>()) == 1)

            // The launch claim makes them this Mac's, once.
            let defaults = UserDefaults(suiteName: "lidia.tests.claim.\(UUID().uuidString)")!
            #expect(LegacyMeetingOwnership.claimOnce(in: context, deviceID: "this-mac", defaults: defaults) == 3)
            #expect(meetings.allSatisfy { $0.originDeviceID == "this-mac" })

            // No unique constraint any more: a second thread with the same id is allowed
            // (CloudKit can't enforce uniqueness; ChatThreadStore looks threads up first).
            let threadID = try #require(threads.first?.id)
            context.insert(ChatThreadModel(id: threadID, title: "Duplicate id"))
            try context.save()
        }

        let after = try StoreSnapshot(url: work.storeURL)
        #expect(after.unchangedContent(comparedTo: before).isEmpty)
        #expect(!after.indexes.contains("Z_ChatThreadModel_UNIQUE_id"))

        // Opening again (the second launch) works and changes nothing.
        do {
            let container = try work.openWithCurrentSchema()
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Meeting>()) == 3)
        }
    }

    /// The real-library check. Never runs on the library itself: point it at a COPY
    /// (store plus -wal, -shm and .LidIA_SUPPORT), which it copies again before opening.
    ///
    ///     LIDIA_MIGRATION_STORE=/path/to/copy/LidIA.store swift test --filter realLibraryCopyMigrates
    @Test("A copy of a real library migrates with every record intact",
          .enabled(if: ProcessInfo.processInfo.environment["LIDIA_MIGRATION_STORE"] != nil))
    func realLibraryCopyMigrates() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LIDIA_MIGRATION_STORE"])
        let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let library = LibraryLocation.folder.standardizedFileURL.resolvingSymlinksInPath()
        #expect(!source.path.hasPrefix(library.path + "/"), "Refusing to run on the live library; pass a copy.")
        guard !source.path.hasPrefix(library.path + "/") else { return }

        let work = try LibraryCopy(of: source)
        defer { work.remove() }
        let before = try StoreSnapshot(url: work.storeURL)

        var swiftDataCounts: (meetings: Int, items: Int, words: Int, threads: Int, messages: Int) = (0, 0, 0, 0, 0)
        do {
            let container = try work.openWithCurrentSchema()
            let context = container.mainContext
            let meetings = try context.fetch(FetchDescriptor<Meeting>())
            swiftDataCounts.meetings = meetings.count
            swiftDataCounts.items = try context.fetchCount(FetchDescriptor<ActionItem>())
            swiftDataCounts.words = meetings.reduce(0) { $0 + $1.rawTranscript.count }
            let threads = try context.fetch(FetchDescriptor<ChatThreadModel>())
            swiftDataCounts.threads = threads.count
            swiftDataCounts.messages = threads.reduce(0) { $0 + $1.messages.count }

            for meeting in meetings {
                let key = meeting.id.uuidString.replacingOccurrences(of: "-", with: "")
                let row = try #require(before.meetings[key], "Meeting \(meeting.title) appeared from nowhere")
                #expect(meeting.title == row.title)
                #expect(meeting.refinedTranscript.unicodeScalars.count == row.refinedLength, "\(meeting.title)")
                #expect(meeting.summary.unicodeScalars.count == row.summaryLength, "\(meeting.title)")
                #expect(meeting.actionItems.count == before.actionItems.values.filter { $0.meetingID == key }.count, "\(meeting.title)")
                // SwiftData stores the word array as JSON; the decoded count must match.
                let storedWords = try row.rawTranscript.map { try JSONDecoder().decode([TranscriptWord].self, from: $0) } ?? []
                #expect(meeting.rawTranscript.count == storedWords.count, "\(meeting.title)")
                #expect(meeting.rawTranscript == storedWords, "\(meeting.title)")
            }
        }
        let after = try StoreSnapshot(url: work.storeURL)
        let changes = after.unchangedContent(comparedTo: before)
        #expect(changes.isEmpty, "\(changes.prefix(20).joined(separator: "\n"))")

        print("""
        [migration] tables before: \(before.tableCounts.sorted { $0.key < $1.key })
        [migration] tables after:  \(after.tableCounts.sorted { $0.key < $1.key })
        [migration] SwiftData: \(swiftDataCounts.meetings) meetings, \(swiftDataCounts.items) action items, \
        \(swiftDataCounts.words) transcript words, \(swiftDataCounts.threads) chat threads, \(swiftDataCounts.messages) messages
        [migration] transcript characters: refined \(before.meetings.values.reduce(0) { $0 + $1.refinedLength }) -> \
        \(after.meetings.values.reduce(0) { $0 + $1.refinedLength }); summaries \(before.meetings.values.reduce(0) { $0 + $1.summaryLength }) -> \
        \(after.meetings.values.reduce(0) { $0 + $1.summaryLength })
        [migration] field differences: \(changes.count)
        """)
    }
}

// MARK: - Helpers

/// A private copy of a library (store, -wal, -shm, .<name>_SUPPORT) in a temp folder.
struct LibraryCopy {
    let folder: URL
    let storeURL: URL

    init(of source: URL) throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("lidia-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        storeURL = folder.appendingPathComponent("LidIA.store")
        let dir = source.deletingLastPathComponent()
        let name = source.lastPathComponent
        let base = source.deletingPathExtension().lastPathComponent
        for (from, to) in [(name, "LidIA.store"), (name + "-wal", "LidIA.store-wal"), (name + "-shm", "LidIA.store-shm"),
                           (".\(base)_SUPPORT", ".LidIA_SUPPORT")] {
            let file = dir.appendingPathComponent(from)
            if fm.fileExists(atPath: file.path) {
                try fm.copyItem(at: file, to: folder.appendingPathComponent(to))
            }
        }
    }

    /// Opens the copy exactly like the app does (minus CloudKit, which needs a signed app).
    @MainActor
    func openWithCurrentSchema() throws -> ModelContainer {
        let schema = Schema(versionedSchema: AppSchema.self)
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Every user-visible value in a library, read with plain SQLite (no SwiftData), so a
/// migration can be checked independently of the code that performed it.
struct StoreSnapshot {
    struct MeetingRow: Equatable {
        var title: String?
        var status: String?
        var date: Double?
        var refinedTranscript: String?
        var summary: String?
        var userEditedSummary: String?
        var userEditedTranscript: String?
        var notes: String?
        var rawTranscript: Data?
        var structuredSummary: Data?
        var calendarAttendees: Data?
        var externalSourceID: String?
        var audioFilePath: String?

        var refinedLength: Int { refinedTranscript?.unicodeScalars.count ?? 0 }
        var summaryLength: Int { summary?.unicodeScalars.count ?? 0 }
        var rawTranscriptBytes: Int? { rawTranscript?.count }
    }

    struct ItemRow: Equatable {
        var title: String?
        var isCompleted: Int64?
        var aiFingerprint: String?
        var workflowStatus: String?
        var priority: String?
        var assignee: String?
        var meetingID: String?
    }

    var meetings: [String: MeetingRow] = [:]
    var actionItems: [String: ItemRow] = [:]
    var chatMessages: [String: String] = [:] // message id → thread id
    var tableCounts: [String: Int] = [:]
    var indexes: Set<String> = []

    init(url: URL) throws {
        var db: OpaquePointer?
        // Read-write (but never written): a WAL-mode store copied without its -shm can't be
        // opened read-only, and `immutable` would skip the -wal. This is always a temp copy.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        // SwiftData may still be closing its own connection when this runs.
        sqlite3_busy_timeout(db, 10_000)

        for row in try Self.query(db, """
            SELECT hex(ZID), ZTITLE, ZSTATUS, ZDATE, ZREFINEDTRANSCRIPT, ZSUMMARY, ZUSEREDITEDSUMMARY,
                   ZUSEREDITEDTRANSCRIPT, ZNOTES, ZRAWTRANSCRIPT, ZSTRUCTUREDSUMMARY, ZCALENDARATTENDEES,
                   ZEXTERNALSOURCEID, ZAUDIOFILEPATH
            FROM ZMEETING
            """) {
            meetings[row[0] as? String ?? ""] = MeetingRow(
                title: row[1] as? String, status: row[2] as? String, date: row[3] as? Double,
                refinedTranscript: row[4] as? String, summary: row[5] as? String,
                userEditedSummary: row[6] as? String, userEditedTranscript: row[7] as? String,
                notes: row[8] as? String, rawTranscript: row[9] as? Data, structuredSummary: row[10] as? Data,
                calendarAttendees: row[11] as? Data, externalSourceID: row[12] as? String, audioFilePath: row[13] as? String
            )
        }
        for row in try Self.query(db, """
            SELECT hex(a.ZID), a.ZTITLE, a.ZISCOMPLETED, a.ZAIFINGERPRINT, a.ZWORKFLOWSTATUS, a.ZPRIORITY,
                   a.ZASSIGNEE, hex(m.ZID)
            FROM ZACTIONITEM a LEFT JOIN ZMEETING m ON a.ZMEETING = m.Z_PK
            """) {
            actionItems[row[0] as? String ?? ""] = ItemRow(
                title: row[1] as? String, isCompleted: row[2] as? Int64, aiFingerprint: row[3] as? String,
                workflowStatus: row[4] as? String, priority: row[5] as? String, assignee: row[6] as? String,
                meetingID: row[7] as? String
            )
        }
        // The iPhone's pre-sync library has no chat or inbox tables.
        let tables = Set(try Self.query(db, "SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.first as? String })
        if tables.contains("ZCHATMESSAGEMODEL") {
            for row in try Self.query(db, """
                SELECT hex(c.ZID), hex(t.ZID) FROM ZCHATMESSAGEMODEL c LEFT JOIN ZCHATTHREADMODEL t ON c.ZTHREAD = t.Z_PK
                """) {
                chatMessages[row[0] as? String ?? ""] = row[1] as? String ?? ""
            }
        }
        for table in ["ZMEETING", "ZACTIONITEM", "ZTALKINGPOINT", "ZCHATTHREADMODEL", "ZCHATMESSAGEMODEL", "ZINBOXNOTIFICATION"]
        where tables.contains(table) {
            tableCounts[table] = Int(try Self.query(db, "SELECT count(*) FROM \(table)").first?.first as? Int64 ?? -1)
        }
        indexes = Set(try Self.query(db, "SELECT name FROM sqlite_master WHERE type = 'index'").compactMap { $0.first as? String })
    }

    /// Lines describing every record or value that differs from `before`. Empty when the
    /// migration kept everything.
    func unchangedContent(comparedTo before: StoreSnapshot) -> [String] {
        var differences: [String] = []
        for (id, row) in before.meetings where meetings[id] != row {
            differences.append("Meeting \(id) \(row.title ?? ""): \(meetings[id] == nil ? "missing" : "changed")")
        }
        for (id, row) in before.actionItems where actionItems[id] != row {
            differences.append("Action item \(id) \(row.title ?? ""): \(actionItems[id] == nil ? "missing" : "changed")")
        }
        for (id, thread) in before.chatMessages where chatMessages[id] != thread {
            differences.append("Chat message \(id): \(chatMessages[id] == nil ? "missing" : "moved")")
        }
        for (table, count) in before.tableCounts where (tableCounts[table] ?? -1) < count {
            differences.append("\(table): \(count) rows before, \(tableCounts[table] ?? -1) after")
        }
        return differences
    }

    private static func query(_ db: OpaquePointer?, _ sql: String) throws -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "StoreSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [Any?] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) {
                        row.append(Data(bytes: bytes, count: count))
                    } else {
                        row.append(Data())
                    }
                default: row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }
}
