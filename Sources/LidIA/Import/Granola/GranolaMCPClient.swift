import Foundation
import os

enum GranolaMCPError: Error, LocalizedError, Equatable {
    case http(Int, String)
    case rpc(Int, String)
    case tool(String)
    case rateLimited
    case malformedResponse(String)
    case toolMissing(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail):
            status >= 500
                ? "Granola's server had a problem (HTTP \(status)). Try again in a few minutes."
                : "Granola refused the request (HTTP \(status))\(detail.isEmpty ? "" : ": \(detail)")."
        case .rpc(_, let message):
            "Granola returned an error: \(message)"
        case .tool(let message):
            "Granola couldn't answer: \(message)"
        case .rateLimited:
            "Granola is limiting requests right now. Try again in a few minutes."
        case .malformedResponse(let detail):
            "Granola sent a reply LidIA couldn't read (\(detail))."
        case .toolMissing(let name):
            "Granola's server doesn't offer \(name) any more, so LidIA can't import from it."
        }
    }
}

/// The full transcript of one meeting, or why there isn't one.
struct GranolaTranscriptResult: Equatable, Sendable {
    var text: String
    /// Set when Granola has no transcript: "transcript_pending", "not_happened_yet", "no_transcript", …
    var unavailableReason: String?
}

/// A client for Granola's official MCP server (streamable HTTP, JSON-RPC 2.0).
///
/// Reads only: it lists meetings and fetches notes, summaries and transcripts.
/// At most `maxConcurrentCalls` requests are in flight; a rate-limit answer
/// waits `retry_after_seconds` and retries just that call.
actor GranolaMCPClient {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "GranolaMCP")
    static let preferredProtocolVersion = "2025-06-18"

    private let endpoint: URL
    private let http: any GranolaHTTPLoading
    private let tokens: any GranolaTokenProviding
    private let maxConcurrentCalls: Int
    private let sleep: @Sendable (Double) async throws -> Void
    private let today: @Sendable () -> Date

    private var sessionID: String?
    private var protocolVersion = GranolaMCPClient.preferredProtocolVersion
    private var initialized = false
    private var connectTask: Task<Void, Error>?
    private var nextID = 1
    /// Input property names per tool, from tools/list.
    private(set) var toolProperties: [String: Set<String>] = [:]

    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        endpoint: URL = GranolaAuthMetadata.mcpEndpoint,
        http: any GranolaHTTPLoading = URLSessionGranolaHTTP(),
        tokens: any GranolaTokenProviding,
        maxConcurrentCalls: Int = 3,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        today: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.http = http
        self.tokens = tokens
        self.maxConcurrentCalls = max(1, maxConcurrentCalls)
        self.sleep = sleep
        self.today = today
    }

    // MARK: - Session

    /// initialize → notifications/initialized → tools/list. Safe to call again.
    func connect() async throws {
        guard !initialized else { return }
        if let connectTask {
            try await connectTask.value
            return
        }
        let task = Task { try await self.performConnect() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    private func performConnect() async throws {
        sessionID = nil
        let result = try await rpc(method: "initialize", params: [
            "protocolVersion": Self.preferredProtocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "LidIA", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
        ], allowReconnect: false)
        if let version = result["protocolVersion"] as? String, !version.isEmpty {
            protocolVersion = version
        }
        try await notify(method: "notifications/initialized")
        initialized = true

        let tools = try await rpc(method: "tools/list", params: [:], allowReconnect: false)
        var properties: [String: Set<String>] = [:]
        for tool in tools["tools"] as? [[String: Any]] ?? [] {
            guard let name = tool["name"] as? String else { continue }
            let schema = tool["inputSchema"] as? [String: Any]
            let keys = (schema?["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
            properties[name] = keys
        }
        toolProperties = properties
        Self.logger.info("Granola MCP connected; tools: \(properties.keys.sorted().joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Tools

    /// Every meeting the user can access, all pages.
    func listAllMeetings(
        from fromDate: String = "2015-01-01",
        progress: (@Sendable (_ found: Int, _ total: Int?) async -> Void)? = nil
    ) async throws -> [GranolaMeetingListing] {
        try await connect()
        try requireTool("list_meetings")
        let toDate = Self.dayString(today())
        var all: [GranolaMeetingListing] = []
        var seen = Set<String>()
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<500 {
            var arguments: [String: Any] = [
                "time_range": "custom",
                "from_date": fromDate,
                "to_date": toDate,
                "limit": 200,
                "max_participants": 50,
            ]
            if let cursor { arguments["cursor"] = cursor }
            let text = try await callTool("list_meetings", arguments: arguments)
            let page = GranolaParser.parseListMeetings(text)
            for meeting in page.meetings where seen.insert(meeting.id).inserted {
                all.append(meeting)
            }
            await progress?(all.count, page.pagination?.totalCount)
            guard let pagination = page.pagination, pagination.hasMore,
                  let next = pagination.nextCursor, seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        return all
    }

    /// Details for up to 10 meetings per call; more IDs are split into batches.
    func getMeetings(ids: [String]) async throws -> [GranolaMeetingDetail] {
        try await connect()
        try requireTool("get_meetings")
        var results: [GranolaMeetingDetail] = []
        for start in stride(from: 0, to: ids.count, by: 10) {
            let batch = Array(ids[start..<min(start + 10, ids.count)])
            let idKey = pick("get_meetings", ["meeting_ids", "note_ids"])
            let text = try await callTool("get_meetings", arguments: [idKey: batch, "attachments": "none"])
            results += GranolaParser.parseGetMeetings(text)
        }
        return results
    }

    /// The whole transcript, paging until it is no longer truncated.
    func fullTranscript(meetingID: String) async throws -> GranolaTranscriptResult {
        try await connect()
        try requireTool("get_meeting_transcript")
        let idKey = pick("get_meeting_transcript", ["meeting_id", "note_id"])
        var text = ""
        var offset: Int?
        var previousEndedMid = false
        for _ in 0..<1000 {
            var arguments: [String: Any] = [idKey: meetingID, "max_chars": 80_000, "include_timestamps": true]
            if let offset { arguments["offset"] = offset }
            let raw = try await callTool("get_meeting_transcript", arguments: arguments)
            guard let page = GranolaParser.parseTranscript(raw) else {
                throw GranolaMCPError.malformedResponse("transcript for \(meetingID)")
            }
            if let reason = page.unavailableReason, (page.transcript ?? "").isEmpty, text.isEmpty {
                return GranolaTranscriptResult(text: "", unavailableReason: reason)
            }
            GranolaParser.appendTranscriptPage(page.transcript ?? "", to: &text, previousEndedMidUtterance: previousEndedMid)
            previousEndedMid = page.endsMidUtterance
            guard page.truncated, let next = page.nextOffset, next > (offset ?? 0) else { break }
            offset = next
        }
        return GranolaTranscriptResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), unavailableReason: nil)
    }

    private func requireTool(_ name: String) throws {
        // An empty list means tools/list told us nothing; try anyway.
        guard toolProperties.isEmpty || toolProperties[name] != nil else {
            throw GranolaMCPError.toolMissing(name)
        }
    }

    /// The first of `candidates` the tool advertises, else the first candidate.
    private func pick(_ tool: String, _ candidates: [String]) -> String {
        guard let known = toolProperties[tool], !known.isEmpty else { return candidates[0] }
        return candidates.first(where: known.contains) ?? candidates[0]
    }

    /// Drops arguments the server doesn't advertise for this tool.
    func filteredArguments(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
        guard let known = toolProperties[tool], !known.isEmpty else { return arguments }
        return arguments.filter { known.contains($0.key) }
    }

    /// Calls a tool and returns its text content. Retries rate limits.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let filtered = filteredArguments(name, arguments)
        var rateLimitRetries = 0
        var transientRetries = 0
        while true {
            try Task.checkCancellation()
            do {
                await acquire()
                let result: [String: Any]
                do {
                    result = try await rpc(method: "tools/call", params: ["name": name, "arguments": filtered], allowReconnect: true)
                } catch {
                    release()
                    throw error
                }
                release()
                let text = Self.text(of: result)
                if (result["isError"] as? Bool) == true {
                    if let limit = GranolaParser.parseRateLimit(text) {
                        if Self.notRetryable(text) { throw GranolaMCPError.rateLimited }
                        throw RateLimitSignal(seconds: limit.retryAfterSeconds)
                    }
                    throw GranolaMCPError.tool(text.isEmpty ? "unknown error" : String(text.prefix(300)))
                }
                return text
            } catch let signal as RateLimitSignal {
                rateLimitRetries += 1
                guard rateLimitRetries <= 8 else { throw GranolaMCPError.rateLimited }
                Self.logger.notice("Granola rate limit on \(name, privacy: .public); waiting \(signal.seconds)s")
                try await sleep(min(max(signal.seconds, 1), 120))
            } catch let error as GranolaMCPError {
                if case .http(let status, _) = error, status >= 500, transientRetries < 3 {
                    transientRetries += 1
                    try await sleep(Double(transientRetries * 2))
                    continue
                }
                throw error
            } catch let error as URLError where Self.isTransient(error) && transientRetries < 3 {
                transientRetries += 1
                try await sleep(Double(transientRetries * 2))
            }
        }
    }

    private struct RateLimitSignal: Error { let seconds: Double }

    private static func notRetryable(_ text: String) -> Bool {
        let compact = text.lowercased().replacingOccurrences(of: " ", with: "")
        return compact.contains("\"retryable\":false") || compact.contains("retryable=\"false\"")
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(error.code)
    }

    static func text(of result: [String: Any]) -> String {
        let parts = (result["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard (item["type"] as? String ?? "text") == "text" else { return nil }
            return item["text"] as? String
        }
        if !parts.isEmpty { return parts.joined(separator: "\n") }
        if let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return ""
    }

    // MARK: - Concurrency limit

    private func acquire() async {
        if inFlight < maxConcurrentCalls {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    // MARK: - JSON-RPC over streamable HTTP

    private func rpc(method: String, params: [String: Any], allowReconnect: Bool) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let usedSession = sessionID
        let (data, response) = try await post(body)

        if response.statusCode == 404, usedSession != nil, allowReconnect {
            // The server forgot our session: start a new one (once, however
            // many calls noticed) and retry this call.
            if sessionID == usedSession {
                initialized = false
                sessionID = nil
            }
            try await connect()
            return try await rpc(method: method, params: params, allowReconnect: false)
        }
        if response.statusCode == 429 {
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 10
            throw RateLimitSignal(seconds: seconds)
        }
        guard (200...299).contains(response.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw GranolaMCPError.http(response.statusCode, detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionID = session
        }
        guard let message = Self.responseMessage(in: data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id) else {
            throw GranolaMCPError.malformedResponse("no reply to \(method)")
        }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            let text = error["message"] as? String ?? "unknown error"
            if let limit = GranolaParser.parseRateLimit(text + " " + (Self.jsonString(error["data"]) ?? "")) {
                throw RateLimitSignal(seconds: limit.retryAfterSeconds)
            }
            throw GranolaMCPError.rpc(code, text)
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func notify(method: String) async throws {
        let (data, response) = try await post(["jsonrpc": "2.0", "method": method])
        guard (200...299).contains(response.statusCode) else {
            throw GranolaMCPError.http(response.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// POSTs one JSON-RPC message with a bearer token, refreshing once on 401.
    private func post(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var token = try await tokens.accessToken()
        for attempt in 0..<2 {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
            let (data, response) = try await http.load(request)
            if response.statusCode == 401, attempt == 0 {
                token = try await tokens.refreshedAccessToken(after: token)
                continue
            }
            if response.statusCode == 401 {
                throw GranolaAuthError.sessionExpired
            }
            return (data, response)
        }
        throw GranolaAuthError.sessionExpired
    }

    /// The JSON-RPC response with `id`, from a JSON body or an SSE stream.
    static func responseMessage(in data: Data, contentType: String?, id: Int) -> [String: Any]? {
        let isSSE = contentType?.lowercased().contains("text/event-stream") == true
        if !isSSE, let object = try? JSONSerialization.jsonObject(with: data) {
            if let message = object as? [String: Any] { return message }
            if let batch = object as? [[String: Any]] {
                return batch.first { ($0["id"] as? NSNumber)?.intValue == id } ?? batch.first
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fallback: [String: Any]?
        for event in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let dataLines = event.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).drop(while: { $0 == " " }) }
            guard !dataLines.isEmpty else { continue }
            let json = dataLines.joined(separator: "\n")
            guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            if (object["id"] as? NSNumber)?.intValue == id { return object }
            if object["result"] != nil || object["error"] != nil { fallback = object }
        }
        return fallback
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
