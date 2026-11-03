import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: AnyCodableID?
    let method: String
    let params: [String: AnyCodable]?
}

struct JSONRPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: AnyCodableID?
    let result: AnyCodable?
    let error: JSONRPCError?
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
}

// Flexible ID that can be Int or String
enum AnyCodableID: Codable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else { throw DecodingError.typeMismatch(AnyCodableID.self, .init(codingPath: [], debugDescription: "Expected Int or String")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }
}

// Minimal Any-wrapping Codable type
indirect enum AnyCodable: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case dict([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([AnyCodable].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyCodable].self) { self = .dict(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dict(let v): try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

// MARK: - Database Access (read-only)

/// Reads LidIA's SwiftData store. The connection is opened read-only: this
/// process never writes to the app's database. Writes go through `Inbox`.
final class MeetingStore {
    private var db: OpaquePointer?

    /// Parameter values for prepared statements.
    enum Bind {
        case int(Int)
        case text(String)
        case blob(Data)
        case null
    }

    init(path: String = MeetingStore.findStorePath()) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw StoreError.notFound(path)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2_000)

        // Unsandboxed SwiftData apps all default to the same file name, so make
        // sure this is really LidIA's store before answering from it.
        let tables = try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('ZMEETING', 'ZACTIONITEM')",
            bind: []
        )
        guard tables.count == 2 else {
            throw StoreError.notLidIAStore(path)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// `LIDIA_STORE_PATH` if set, otherwise the app's library in its own folder, falling
    /// back to SwiftData's shared default location used by older builds.
    static func findStorePath() -> String {
        if let override = ProcessInfo.processInfo.environment["LIDIA_STORE_PATH"], !override.isEmpty {
            return override
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = appSupport.appendingPathComponent("LidIA/LidIA.store").path
        if FileManager.default.fileExists(atPath: current) { return current }
        return appSupport.appendingPathComponent("default.store").path
    }

    // MARK: Reads

    func recentMeetings(limit: Int = 20) throws -> [[String: AnyCodable]] {
        let sql = """
            SELECT ZTITLE, ZDATE, ZDURATION, ZSUMMARY, ZSTATUS, Z_PK, ZID
            FROM ZMEETING
            ORDER BY ZDATE DESC
            LIMIT ?
            """
        return try query(sql, bind: [.int(limit)]).map(meetingRow)
    }

    func meeting(byUUID uuid: String) throws -> [String: AnyCodable]? {
        guard let idBlob = Self.uuidBlob(uuid) else { return nil }
        let sql = """
            SELECT ZTITLE, ZDATE, ZDURATION, ZSUMMARY, ZSTATUS, ZREFINEDTRANSCRIPT, ZNOTES, Z_PK, ZID,
                   ZCALENDARATTENDEES, ZTEMPLATEID
            FROM ZMEETING
            WHERE ZID = ?
            """
        guard let row = try query(sql, bind: [.blob(idBlob)]).first else { return nil }
        var result = meetingRow(row)

        if case .int(let pk) = row["Z_PK"] {
            let actionSQL = """
                SELECT ZTITLE, ZASSIGNEE, ZDEADLINE, ZISCOMPLETED, ZID
                FROM ZACTIONITEM
                WHERE ZMEETING = ?
                """
            let items = try query(actionSQL, bind: [.int(pk)]).map(actionItemRow)
            result["actionItems"] = .array(items.map { .dict($0) })
        }

        if let transcript = row["ZREFINEDTRANSCRIPT"] {
            result["refinedTranscript"] = transcript
        }
        if let notes = row["ZNOTES"] {
            result["notes"] = notes
        }
        if let attendees = row["__ZCALENDARATTENDEES_DATA"].flatMap(Self.decodeAttendees) {
            result["attendees"] = .array(attendees.map { .string($0) })
        }
        return result
    }

    func meetingExists(uuid: String) throws -> Bool {
        guard let idBlob = Self.uuidBlob(uuid) else { return false }
        return try !query("SELECT Z_PK FROM ZMEETING WHERE ZID = ?", bind: [.blob(idBlob)]).isEmpty
    }

    func meetingTitle(uuid: String) throws -> AnyCodable? {
        guard let idBlob = Self.uuidBlob(uuid) else { return nil }
        return try query("SELECT ZTITLE FROM ZMEETING WHERE ZID = ?", bind: [.blob(idBlob)]).first?["ZTITLE"]
    }

    func searchMeetings(query searchText: String) throws -> [[String: AnyCodable]] {
        let escaped = searchText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let sql = """
            SELECT ZTITLE, ZDATE, ZDURATION, ZSUMMARY, ZSTATUS, Z_PK, ZID
            FROM ZMEETING
            WHERE ZTITLE LIKE ?1 ESCAPE '\\' OR ZSUMMARY LIKE ?1 ESCAPE '\\'
               OR ZREFINEDTRANSCRIPT LIKE ?1 ESCAPE '\\' OR ZNOTES LIKE ?1 ESCAPE '\\'
            ORDER BY ZDATE DESC
            LIMIT 50
            """
        return try query(sql, bind: [.text(pattern)]).map(meetingRow)
    }

    func actionItems(status: String?) throws -> [[String: AnyCodable]] {
        var sql = """
            SELECT ai.ZTITLE, ai.ZASSIGNEE, ai.ZDEADLINE, ai.ZISCOMPLETED, ai.ZID,
                   m.ZTITLE AS ZMEETINGTITLE, m.ZID AS ZMEETINGID
            FROM ZACTIONITEM ai
            LEFT JOIN ZMEETING m ON ai.ZMEETING = m.Z_PK
            """
        if status == "pending" {
            sql += " WHERE ai.ZISCOMPLETED = 0"
        } else if status == "completed" {
            sql += " WHERE ai.ZISCOMPLETED = 1"
        }
        sql += " ORDER BY m.ZDATE DESC"

        return try query(sql, bind: []).map { row in
            var dict = actionItemRow(row)
            dict["meetingTitle"] = row["ZMEETINGTITLE"] ?? .null
            dict["meetingId"] = row["ZMEETINGID"] ?? .null
            return dict
        }
    }

    func actionItem(uuid: String) throws -> [String: AnyCodable]? {
        guard let idBlob = Self.uuidBlob(uuid) else { return nil }
        let rows = try query(
            "SELECT ZTITLE, ZASSIGNEE, ZDEADLINE, ZISCOMPLETED, ZID FROM ZACTIONITEM WHERE ZID = ?",
            bind: [.blob(idBlob)]
        )
        return rows.first.map(actionItemRow)
    }

    // MARK: Row mapping

    private func meetingRow(_ row: [String: AnyCodable]) -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [:]
        dict["id"] = row["ZID"] ?? .null
        dict["title"] = row["ZTITLE"] ?? .null
        dict["summary"] = row["ZSUMMARY"] ?? .null
        dict["status"] = row["ZSTATUS"] ?? .null

        // Core Data timestamps are seconds since 2001-01-01.
        if case .double(let ts) = row["ZDATE"] {
            let date = Date(timeIntervalSinceReferenceDate: ts)
            dict["date"] = .string(ISO8601DateFormatter().string(from: date))
        }
        switch row["ZDURATION"] {
        case .double(let d): dict["durationSeconds"] = .int(Int(d))
        case .int(let d): dict["durationSeconds"] = .int(d)
        default: break
        }
        return dict
    }

    private func actionItemRow(_ row: [String: AnyCodable]) -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [:]
        dict["id"] = row["ZID"] ?? .null
        dict["title"] = row["ZTITLE"] ?? .null
        dict["assignee"] = row["ZASSIGNEE"] ?? .null
        dict["deadline"] = row["ZDEADLINE"] ?? .null
        if case .int(let v) = row["ZISCOMPLETED"] {
            dict["isCompleted"] = .bool(v != 0)
        } else {
            dict["isCompleted"] = .bool(false)
        }
        return dict
    }

    // MARK: UUIDs

    /// SwiftData stores `UUID` attributes as 16-byte blobs.
    static func uuidBlob(_ string: String) -> Data? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func uuidString(fromBlob data: Data) -> String? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    private static func decodeAttendees(_ value: AnyCodable) -> [String]? {
        guard case .string(let base64) = value, let data = Data(base64Encoded: base64) else { return nil }
        let strings = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSString.self, from: data)
        return strings?.map { $0 as String }
    }

    // MARK: SQLite

    private func query(_ sql: String, bind: [Bind]) throws -> [[String: AnyCodable]] {
        guard let db else { throw StoreError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, val) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch val {
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var results: [[String: AnyCodable]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: AnyCodable] = [:]
            let colCount = sqlite3_column_count(stmt)
            for c in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row[name] = .int(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT:
                    row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT:
                    row[name] = .string(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, c))
                    let data = sqlite3_column_blob(stmt, c).map { Data(bytes: $0, count: count) } ?? Data()
                    if let uuid = Self.uuidString(fromBlob: data) {
                        row[name] = .string(uuid)
                    } else {
                        // Keep other blobs out of results, but available to callers that know the format.
                        row[name] = .null
                        row["__\(name)_DATA"] = .string(data.base64EncodedString())
                    }
                default:
                    row[name] = .null
                }
            }
            results.append(row)
        }
        return results
    }

    enum StoreError: LocalizedError {
        case notFound(String)
        case openFailed(String)
        case notLidIAStore(String)
        case notOpen
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let p): return "LidIA's database was not found at \(p). Open LidIA once, or set LIDIA_STORE_PATH."
            case .openFailed(let m): return "Failed to open LidIA's database read-only: \(m)"
            case .notLidIAStore(let p): return "The database at \(p) isn't LidIA's. Set LIDIA_STORE_PATH to LidIA's store."
            case .notOpen: return "Database not open"
            case .queryFailed(let m): return "Query failed: \(m)"
            }
        }
    }
}

// MARK: - Inbox (writes)

/// One queued write. Must match `MCPInboxRequest` in the app
/// (`Sources/LidIA/Integrations/MCPInbox.swift`).
struct InboxRequest: Encodable {
    static let currentVersion = 1

    let version: Int = InboxRequest.currentVersion
    let requestID: String = UUID().uuidString
    let createdAt: String = ISO8601DateFormatter().string(from: Date())
    let operation: String
    var actionItemID: String?
    var meetingID: String?
    var title: String?
    var assignee: String?
    var deadline: String?
    var isCompleted: Bool?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case createdAt = "created_at"
        case operation
        case actionItemID = "action_item_id"
        case meetingID = "meeting_id"
        case title, assignee, deadline
        case isCompleted = "is_completed"
        case notes
    }
}

/// Hands writes to the app by dropping one JSON file per request into a
/// folder the app watches. The app validates each request and applies it
/// through SwiftData, so IDs, required fields and history stay consistent.
struct Inbox {
    let directory: URL

    // Same limits the app enforces, checked here too so the client gets a
    // clear error immediately instead of a silently rejected request.
    static let maxTitleLength = 500
    static let maxAssigneeLength = 200
    static let maxDeadlineLength = 100
    static let maxNotesLength = 1_000_000

    /// `LIDIA_MCP_INBOX` if set, otherwise `~/Library/Application Support/LidIA/MCPInbox`.
    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["LIDIA_MCP_INBOX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LidIA/MCPInbox", isDirectory: true)
    }

    func enqueue(_ request: InboxRequest) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)

        // Sortable name so the app applies requests in order. Write to a hidden
        // temp file first, then rename, so the app never reads a partial file.
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let name = String(format: "%013lld-%@.json", millis, request.requestID)
        let temp = directory.appendingPathComponent(".\(name).tmp")
        let final = directory.appendingPathComponent(name)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw InboxError.writeFailed(directory.path)
        }
        do {
            try fm.moveItem(at: temp, to: final)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    enum InboxError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .writeFailed(let path): return "Could not queue the change in \(path)"
            }
        }
    }
}
// MARK: - MCP Server

final class MCPServer {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var store: MeetingStore?
    var storeError: String?
    let inbox: Inbox

    static let queuedMessage = "Queued for LidIA. The app checks and saves this change while it's running; open LidIA if it isn't."

    init(inbox: Inbox = Inbox(directory: Inbox.defaultDirectory())) {
        self.inbox = inbox
        encoder.outputFormatting = [.sortedKeys]
    }

    func run() {
        openStore()

        // Read JSON-RPC messages from stdin, one per line
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }

            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: data)
                // Notifications (no id) never get a response.
                guard let response = handleRequest(request), request.id != nil else { continue }
                write(response)
            } catch {
                write(JSONRPCResponse(
                    id: nil,
                    result: nil,
                    error: JSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)")
                ))
            }
        }
    }

    private func write(_ response: JSONRPCResponse) {
        guard let data = try? encoder.encode(response),
              let json = String(data: data, encoding: .utf8) else { return }
        print(json)
        fflush(stdout)
    }

    /// Opens (or reopens) the store. LidIA may be launched after the server.
    @discardableResult
    func openStore() -> MeetingStore? {
        if let store { return store }
        do {
            store = try MeetingStore()
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            log("Warning: Could not open meeting store: \(error.localizedDescription)")
        }
        return store
    }

    func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return initializeResponse(id: request.id)
        case "initialized", "notifications/initialized", "notifications/cancelled":
            return nil
        case "resources/list":
            return listResources(id: request.id)
        case "resources/read":
            return readResource(id: request.id, params: request.params)
        case "tools/list":
            return listTools(id: request.id)
        case "tools/call":
            return callTool(id: request.id, params: request.params)
        case "ping":
            return JSONRPCResponse(id: request.id, result: .dict([:]), error: nil)
        default:
            if request.method.hasPrefix("notifications/") { return nil }
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    // MARK: - Initialize

    func initializeResponse(id: AnyCodableID?) -> JSONRPCResponse {
        let result: [String: AnyCodable] = [
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .dict([
                "resources": .dict([:]),
                "tools": .dict([:])
            ]),
            "serverInfo": .dict([
                "name": .string("lidia-mcp"),
                "version": .string("1.1.0")
            ])
        ]
        return JSONRPCResponse(id: id, result: .dict(result), error: nil)
    }

    // MARK: - Resources

    func listResources(id: AnyCodableID?) -> JSONRPCResponse {
        let resources: [AnyCodable] = [
            .dict([
                "uri": .string("meetings://recent"),
                "name": .string("Recent Meetings"),
                "description": .string("Last 20 meetings with titles, dates, and summaries"),
                "mimeType": .string("application/json")
            ])
        ]
        return JSONRPCResponse(id: id, result: .dict(["resources": .array(resources)]), error: nil)
    }

    func readResource(id: AnyCodableID?, params: [String: AnyCodable]?) -> JSONRPCResponse {
        guard let uri = params?["uri"]?.stringValue else {
            return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32602, message: "Missing uri parameter"))
        }

        guard let store = openStore() else {
            return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32000, message: storeUnavailableMessage))
        }

        do {
            if uri == "meetings://recent" {
                let meetings = try store.recentMeetings()
                let json = try encoder.encode(AnyCodable.array(meetings.map { .dict($0) }))
                let contents: [AnyCodable] = [
                    .dict([
                        "uri": .string(uri),
                        "mimeType": .string("application/json"),
                        "text": .string(String(data: json, encoding: .utf8) ?? "[]")
                    ])
                ]
                return JSONRPCResponse(id: id, result: .dict(["contents": .array(contents)]), error: nil)
            } else if uri.hasPrefix("meetings://") {
                let meetingID = String(uri.dropFirst("meetings://".count))
                guard let meeting = try store.meeting(byUUID: meetingID) else {
                    return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32000, message: "Meeting not found"))
                }
                let json = try encoder.encode(AnyCodable.dict(meeting))
                let contents: [AnyCodable] = [
                    .dict([
                        "uri": .string(uri),
                        "mimeType": .string("application/json"),
                        "text": .string(String(data: json, encoding: .utf8) ?? "{}")
                    ])
                ]
                return JSONRPCResponse(id: id, result: .dict(["contents": .array(contents)]), error: nil)
            } else {
                return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32602, message: "Unknown resource URI: \(uri)"))
            }
        } catch {
            return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32000, message: error.localizedDescription))
        }
    }

    private var storeUnavailableMessage: String {
        storeError ?? "Meeting store not available. Has LidIA been run at least once?"
    }

// MARK: - Tools

    func listTools(id: AnyCodableID?) -> JSONRPCResponse {
        let tools: [AnyCodable] = [
            .dict([
                "name": .string("search_meetings"),
                "description": .string("Search meetings by title, summary, or transcript content"),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "query": .dict([
                            "type": .string("string"),
                            "description": .string("Search text to find in meeting titles, summaries, or transcripts")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ]),
            .dict([
                "name": .string("get_action_items"),
                "description": .string("Get action items from meetings, optionally filtered by status"),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "status": .dict([
                            "type": .string("string"),
                            "description": .string("Filter by status: 'pending', 'completed', or omit for all"),
                            "enum": .array([.string("pending"), .string("completed")])
                        ])
                    ])
                ])
            ]),
            .dict([
                "name": .string("get_meeting"),
                "description": .string("Get full details of a specific meeting by its ID, including transcript and action items"),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "meeting_id": .dict([
                            "type": .string("string"),
                            "description": .string("The UUID of the meeting")
                        ])
                    ]),
                    "required": .array([.string("meeting_id")])
                ])
            ]),
            .dict([
                "name": .string("create_action_item"),
                "description": .string("Create a new action item, optionally linked to a meeting. LidIA checks and saves the change; the result includes the new item's ID."),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "title": .dict([
                            "type": .string("string"),
                            "description": .string("The title/description of the action item")
                        ]),
                        "assignee": .dict([
                            "type": .string("string"),
                            "description": .string("Person assigned to this action item")
                        ]),
                        "deadline": .dict([
                            "type": .string("string"),
                            "description": .string("Deadline in YYYY-MM-DD format")
                        ]),
                        "meeting_id": .dict([
                            "type": .string("string"),
                            "description": .string("UUID of the meeting to link this action item to")
                        ])
                    ]),
                    "required": .array([.string("title")])
                ])
            ]),
            .dict([
                "name": .string("update_action_item"),
                "description": .string("Update an existing action item's title, assignee, deadline, or completion status. LidIA checks and saves the change."),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "id": .dict([
                            "type": .string("string"),
                            "description": .string("The UUID of the action item to update")
                        ]),
                        "title": .dict([
                            "type": .string("string"),
                            "description": .string("New title for the action item")
                        ]),
                        "assignee": .dict([
                            "type": .string("string"),
                            "description": .string("New assignee for the action item")
                        ]),
                        "deadline": .dict([
                            "type": .string("string"),
                            "description": .string("New deadline in YYYY-MM-DD format")
                        ]),
                        "is_completed": .dict([
                            "type": .string("boolean"),
                            "description": .string("Whether the action item is completed")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ])
            ]),
            .dict([
                "name": .string("delete_action_item"),
                "description": .string("Delete an action item by its UUID. LidIA checks and applies the change."),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "id": .dict([
                            "type": .string("string"),
                            "description": .string("The UUID of the action item to delete")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ])
            ]),
            .dict([
                "name": .string("mark_action_item_done"),
                "description": .string("Mark an action item as completed. LidIA checks and saves the change."),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "id": .dict([
                            "type": .string("string"),
                            "description": .string("The UUID of the action item to mark as done")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ])
            ]),
            .dict([
                "name": .string("update_meeting_notes"),
                "description": .string("Update or set the notes field of a meeting. LidIA checks and saves the change."),
                "inputSchema": .dict([
                    "type": .string("object"),
                    "properties": .dict([
                        "id": .dict([
                            "type": .string("string"),
                            "description": .string("The UUID of the meeting")
                        ]),
                        "notes": .dict([
                            "type": .string("string"),
                            "description": .string("The notes content to set for the meeting")
                        ])
                    ]),
                    "required": .array([.string("id"), .string("notes")])
                ])
            ])
        ]
        return JSONRPCResponse(id: id, result: .dict(["tools": .array(tools)]), error: nil)
    }

    func callTool(id: AnyCodableID?, params: [String: AnyCodable]?) -> JSONRPCResponse {
        guard let toolName = params?["name"]?.stringValue else {
            return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32602, message: "Missing tool name"))
        }

        guard let store = openStore() else {
            return toolError(id: id, message: storeUnavailableMessage)
        }

        let arguments: [String: AnyCodable]
        if case .dict(let args) = params?["arguments"] {
            arguments = args
        } else {
            arguments = [:]
        }

        do {
            switch toolName {
            case "search_meetings":
                guard let query = arguments["query"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: query")
                }
                let results = try store.searchMeetings(query: query)
                return toolResult(id: id, content: results.map { .dict($0) })

            case "get_action_items":
                let status = arguments["status"]?.stringValue
                let results = try store.actionItems(status: status)
                return toolResult(id: id, content: results.map { .dict($0) })

            case "get_meeting":
                guard let meetingID = arguments["meeting_id"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: meeting_id")
                }
                guard let meeting = try store.meeting(byUUID: meetingID) else {
                    return toolError(id: id, message: "Meeting not found with ID: \(meetingID)")
                }
                return toolResult(id: id, content: [.dict(meeting)])

            case "create_action_item":
                guard let title = nonEmpty(arguments["title"]?.stringValue) else {
                    return toolError(id: id, message: "Missing required parameter: title")
                }
                let assignee = arguments["assignee"]?.stringValue
                let deadline = arguments["deadline"]?.stringValue
                let meetingID = arguments["meeting_id"]?.stringValue
                if let problem = lengthProblem(title: title, assignee: assignee, deadline: deadline, notes: nil) {
                    return toolError(id: id, message: problem)
                }
                if let meetingID {
                    guard UUID(uuidString: meetingID) != nil, try store.meetingExists(uuid: meetingID) else {
                        return toolError(id: id, message: "Meeting not found with ID: \(meetingID)")
                    }
                }
                // The ID is chosen here so the client can refer to the item
                // right away; the app keeps it when it applies the request.
                let itemID = UUID().uuidString
                var request = InboxRequest(operation: "create_action_item")
                request.actionItemID = itemID
                request.meetingID = meetingID
                request.title = title
                request.assignee = assignee
                request.deadline = deadline
                try inbox.enqueue(request)
                return toolResult(id: id, content: [.dict(queued([
                    "id": .string(itemID),
                    "title": .string(title),
                    "assignee": assignee.map { .string($0) } ?? .null,
                    "deadline": deadline.map { .string($0) } ?? .null,
                    "isCompleted": .bool(false)
                ]))])

            case "update_action_item":
                guard let itemID = arguments["id"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: id")
                }
                guard var item = try store.actionItem(uuid: itemID) else {
                    return toolError(id: id, message: "Action item not found with ID: \(itemID)")
                }
                let title = arguments["title"]?.stringValue
                let assignee = arguments["assignee"]?.stringValue
                let deadline = arguments["deadline"]?.stringValue
                var isCompleted: Bool? = nil
                if case .bool(let v) = arguments["is_completed"] {
                    isCompleted = v
                }
                guard title != nil || assignee != nil || deadline != nil || isCompleted != nil else {
                    return toolError(id: id, message: "No fields to update")
                }
                if let title, nonEmpty(title) == nil {
                    return toolError(id: id, message: "title can't be empty")
                }
                if let problem = lengthProblem(title: title, assignee: assignee, deadline: deadline, notes: nil) {
                    return toolError(id: id, message: problem)
                }
                var request = InboxRequest(operation: "update_action_item")
                request.actionItemID = itemID
                request.title = title
                request.assignee = assignee
                request.deadline = deadline
                request.isCompleted = isCompleted
                try inbox.enqueue(request)

                if let title { item["title"] = .string(title) }
                if let assignee { item["assignee"] = .string(assignee) }
                if let deadline { item["deadline"] = .string(deadline) }
                if let isCompleted { item["isCompleted"] = .bool(isCompleted) }
                item["id"] = .string(itemID)
                return toolResult(id: id, content: [.dict(queued(item))])

            case "delete_action_item":
                guard let itemID = arguments["id"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: id")
                }
                guard try store.actionItem(uuid: itemID) != nil else {
                    return toolError(id: id, message: "Action item not found with ID: \(itemID)")
                }
                var request = InboxRequest(operation: "delete_action_item")
                request.actionItemID = itemID
                try inbox.enqueue(request)
                return toolResult(id: id, content: [.dict(queued(["deleted": .bool(true), "id": .string(itemID)]))])

            case "mark_action_item_done":
                guard let itemID = arguments["id"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: id")
                }
                guard var item = try store.actionItem(uuid: itemID) else {
                    return toolError(id: id, message: "Action item not found with ID: \(itemID)")
                }
                var request = InboxRequest(operation: "mark_action_item_done")
                request.actionItemID = itemID
                try inbox.enqueue(request)
                item["id"] = .string(itemID)
                item["isCompleted"] = .bool(true)
                return toolResult(id: id, content: [.dict(queued(item))])

            case "update_meeting_notes":
                guard let meetingID = arguments["id"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: id")
                }
                guard let notes = arguments["notes"]?.stringValue else {
                    return toolError(id: id, message: "Missing required parameter: notes")
                }
                if let problem = lengthProblem(title: nil, assignee: nil, deadline: nil, notes: notes) {
                    return toolError(id: id, message: problem)
                }
                guard UUID(uuidString: meetingID) != nil, let title = try store.meetingTitle(uuid: meetingID) else {
                    return toolError(id: id, message: "Meeting not found with ID: \(meetingID)")
                }
                var request = InboxRequest(operation: "update_meeting_notes")
                request.meetingID = meetingID
                request.notes = notes
                try inbox.enqueue(request)
                return toolResult(id: id, content: [.dict(queued([
                    "id": .string(meetingID),
                    "title": title,
                    "notes": .string(notes)
                ]))])

            default:
                return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: -32602, message: "Unknown tool: \(toolName)"))
            }
        } catch {
            return toolError(id: id, message: error.localizedDescription)
        }
    }

    /// Adds the queued status fields to a write tool's result.
    private func queued(_ dict: [String: AnyCodable]) -> [String: AnyCodable] {
        var result = dict
        result["status"] = .string("queued")
        result["message"] = .string(Self.queuedMessage)
        return result
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func lengthProblem(title: String?, assignee: String?, deadline: String?, notes: String?) -> String? {
        if let title, title.count > Inbox.maxTitleLength { return "title is longer than \(Inbox.maxTitleLength) characters" }
        if let assignee, assignee.count > Inbox.maxAssigneeLength { return "assignee is longer than \(Inbox.maxAssigneeLength) characters" }
        if let deadline, deadline.count > Inbox.maxDeadlineLength { return "deadline is longer than \(Inbox.maxDeadlineLength) characters" }
        if let notes, notes.count > Inbox.maxNotesLength { return "notes are longer than \(Inbox.maxNotesLength) characters" }
        return nil
    }

    private func toolResult(id: AnyCodableID?, content: [AnyCodable]) -> JSONRPCResponse {
        let json: Data
        do {
            json = try encoder.encode(AnyCodable.array(content))
        } catch {
            return toolError(id: id, message: "Failed to encode result")
        }
        let text = String(data: json, encoding: .utf8) ?? "[]"
        let result: [String: AnyCodable] = [
            "content": .array([
                .dict([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ]
        return JSONRPCResponse(id: id, result: .dict(result), error: nil)
    }

    private func toolError(id: AnyCodableID?, message: String) -> JSONRPCResponse {
        let result: [String: AnyCodable] = [
            "content": .array([
                .dict([
                    "type": .string("text"),
                    "text": .string("Error: \(message)")
                ])
            ]),
            "isError": .bool(true)
        ]
        return JSONRPCResponse(id: id, result: .dict(result), error: nil)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[lidia-mcp] \(message)\n".utf8))
    }
}

// MARK: - Entry Point

let server = MCPServer()
server.run()
