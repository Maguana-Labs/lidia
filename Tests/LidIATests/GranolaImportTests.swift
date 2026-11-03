import Synchronization
import Foundation
import SwiftData
import Testing
@testable import LidIA

// MARK: - Fixtures

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/Granola/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Parsers

@Test func granolaParsesListMeetingsFixture() throws {
    let page = GranolaParser.parseListMeetings(try fixture("list_meetings.txt"))
    #expect(page.meetings.count == 1)
    let meeting = try #require(page.meetings.first)
    #expect(meeting.id == "5b1e2c90-7a4d-4e1f-9c3b-2d8f6a0e4b71")
    #expect(meeting.title == "Bakery pop-up and supplier plan")
    #expect(meeting.capturedByMe == true)
    #expect(meeting.url == "https://notes.granola.ai/d/5b1e2c90-7a4d-4e1f-9c3b-2d8f6a0e4b71")
    #expect(meeting.meetingAt == GranolaParser.parseDate("2026-11-02T20:10:44.168Z"))
    #expect(meeting.participants == [
        GranolaParticipant(name: "Sample Person", email: "person@example.com", company: "Example", isNoteCreator: true),
    ])
    #expect(meeting.participants.first?.attendeeString == "Sample Person <person@example.com>")

    let pagination = try #require(page.pagination)
    #expect(pagination.hasMore)
    #expect(pagination.totalCount == 444)
    #expect(pagination.remainingCount == 443)
    #expect(pagination.nextCursor == "eyJ2ZXJzaW9uIjoxfQ")
}

/// Granola lists every participant on one line, separated by commas.
@Test func granolaParsesParticipantsOnOneLine() {
    let parsed = GranolaParser.parseParticipants(
        "Alex Moreno (note creator) from Harborcloud (alex@harborcloud.example), Felix S (felix.s@northwind.example), Daniel R (daniel.r@northwind.example)"
    )
    #expect(parsed.map(\.name) == ["Alex Moreno", "Felix S", "Daniel R"])
    #expect(parsed.map(\.email) == ["alex@harborcloud.example", "felix.s@northwind.example", "daniel.r@northwind.example"])
    #expect(parsed.first?.company == "Harborcloud")
    #expect(parsed.first?.isNoteCreator == true)
}

@Test func granolaParsesGetMeetingsFixture() throws {
    let details = GranolaParser.parseGetMeetings(try fixture("get_meetings.txt"))
    #expect(details.count == 1)
    let detail = try #require(details.first)
    #expect(detail.id == "5b1e2c90-7a4d-4e1f-9c3b-2d8f6a0e4b71")
    #expect(detail.title == "Bakery pop-up and supplier plan")
    #expect(detail.privateNotes.isEmpty)
    #expect(detail.privateNotesStatus == "empty")
    #expect(detail.transcriptAvailable == true)
    #expect(detail.summary.hasPrefix("### Pop-up de Panadería: Decisiones"))
    #expect(detail.summary.contains("- **Pedir harina al proveedor del mercado**"))
    #expect(detail.summary.hasSuffix("empezar la prueba el mismo día de la entrega."))
    #expect(detail.participants.first?.email == "person@example.com")
}

@Test func granolaParsesTranscriptFixture() throws {
    let page = try #require(GranolaParser.parseTranscript(try fixture("get_meeting_transcript.json")))
    #expect(page.truncated)
    #expect(page.nextOffset == 1489)
    #expect(page.totalChars == 2651)
    #expect(page.endsMidUtterance)
    #expect(page.unavailableReason == nil)
    #expect(page.transcript?.hasPrefix("Speaker A: Y el resto.") == true)
    #expect(page.transcript?.contains("\nSpeaker B: OK.") == true)
}

@Test func granolaParserToleratesEscapingUnknownAttributesAndProse() {
    let text = """
    Here are your meetings! <note>ignore me</note>
    <meetings_data count="2" extra='x'>
    <meeting
        weird_new_attr="1" id="a1" title="Q&amp;A &quot;sync&quot; &lt;team&gt; &#233;t&#xE9;" meeting_at="2026-01-05T10:00:00Z" captured_by_me="false">
      <known_participants>
      Ana López from Acme (ana@acme.com)
      bob@example.com
      Carol
      </known_participants>
      <something_new>whatever</something_new>
    </meeting>
    <meeting id="a2" title='Single &apos;quoted&apos;' />
    </meetings_data>
    Some prose after.
    """
    let page = GranolaParser.parseListMeetings(text)
    #expect(page.meetings.map(\.id) == ["a1", "a2"])
    #expect(page.meetings[0].title == "Q&A \"sync\" <team> été")
    #expect(page.meetings[0].capturedByMe == false)
    #expect(page.meetings[0].meetingAt == GranolaParser.parseDate("2026-01-05T10:00:00Z"))
    #expect(page.meetings[0].participants.map(\.attendeeString) == ["Ana López <ana@acme.com>", "bob@example.com", "Carol"])
    #expect(page.meetings[0].participants[0].company == "Acme")
    #expect(page.meetings[1].title == "Single 'quoted'")
    #expect(page.meetings[1].participants.isEmpty)
    #expect(page.pagination == nil)
}

@Test func granolaParsesPrivateNotesAndEscapedSummary() {
    let text = """
    <meetings_data>
    <meeting id="m" title="T" meeting_at="2026-02-01T09:00:00.5+01:00">
      <private_notes status="present">
      - Ask about **budget** &amp; timing
      </private_notes>
      <transcript available="false" />
      <summary>
    ### Decisions
    - Use A &lt; B
    </summary>
    </meeting>
    </meetings_data>
    """
    let detail = GranolaParser.parseGetMeetings(text)[0]
    #expect(detail.privateNotes == "- Ask about **budget** & timing")
    #expect(detail.privateNotesStatus == "present")
    #expect(detail.transcriptAvailable == false)
    #expect(detail.summary == "### Decisions\n- Use A < B")
    #expect(detail.meetingAt != nil)
}

@Test func granolaTranscriptUnavailableAndPageJoining() throws {
    let page = try #require(GranolaParser.parseTranscript("""
    Advisory text first. {"id":"x","transcript":null,"transcript_unavailable":{"reason":"transcript_pending","message":"retry"}}
    """))
    #expect(page.unavailableReason == "transcript_pending")
    #expect(page.truncated == false)

    var text = ""
    GranolaParser.appendTranscriptPage("Speaker A: Hola, qué", to: &text, previousEndedMidUtterance: false)
    GranolaParser.appendTranscriptPage(" tal.\nSpeaker B: Bien.", to: &text, previousEndedMidUtterance: true)
    GranolaParser.appendTranscriptPage("Speaker A: Adiós.", to: &text, previousEndedMidUtterance: false)
    #expect(text == "Speaker A: Hola, qué tal.\nSpeaker B: Bien.\nSpeaker A: Adiós.")
}

@Test func granolaRecognisesRateLimits() {
    #expect(GranolaParser.parseRateLimit(#"{"error":"rate_limit","retry_after_seconds":7,"retryable":true}"#)?.retryAfterSeconds == 7)
    #expect(GranolaParser.parseRateLimit("Error: rate_limit exceeded, retry_after_seconds=3")?.retryAfterSeconds == 3)
    #expect(GranolaParser.parseRateLimit("Meeting not found") == nil)
}

// MARK: - Stub MCP server

private enum ToolReply {
    case text(String)
    case error(String)
}

/// A fake Granola MCP server. Answers JSON-RPC by method and records what it saw.
private final class StubGranolaServer: GranolaHTTPLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (String, [String: Any]) -> ToolReply
    private(set) var toolCalls: [(name: String, arguments: [String: Any])] = []
    private(set) var authorizations: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    /// Answer the next tools/call with 401 when its token is this one.
    var rejectToken: String?
    var sessionCount = 0

    init(handler: @escaping @Sendable (String, [String: Any]) -> ToolReply) {
        self.handler = handler
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let method = body["method"] as? String ?? ""
        let id = body["id"] ?? NSNull()
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        lock.withLock { authorizations.append(auth) }

        if let reject = lock.withLock({ rejectToken }), auth == "Bearer \(reject)" {
            return respond(request, status: 401, data: Data(#"{"message":"Unauthorized"}"#.utf8))
        }

        switch method {
        case "initialize":
            let session = lock.withLock { () -> String in
                sessionCount += 1
                return "session-\(sessionCount)"
            }
            return respond(request, status: 200, json: ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": "2025-06-18", "capabilities": [:], "serverInfo": ["name": "stub"],
            ]], headers: ["Mcp-Session-Id": session])
        case "notifications/initialized":
            return respond(request, status: 202, data: Data())
        case "tools/list":
            return respond(request, status: 200, json: ["jsonrpc": "2.0", "id": id, "result": ["tools": [
                ["name": "list_meetings", "inputSchema": ["type": "object", "properties": [
                    "time_range": [:], "from_date": [:], "to_date": [:], "limit": [:], "max_participants": [:], "cursor": [:],
                ]]],
                ["name": "get_meetings", "inputSchema": ["type": "object", "properties": ["meeting_ids": [:], "attachments": [:]]]],
                ["name": "get_meeting_transcript", "inputSchema": ["type": "object", "properties": [
                    "meeting_id": [:], "max_chars": [:], "offset": [:], "include_timestamps": [:],
                ]]],
            ]]])
        case "tools/call":
            let params = body["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            lock.withLock {
                toolCalls.append((name, arguments))
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
            }
            try? await Task.sleep(for: .milliseconds(5))
            lock.withLock { inFlight -= 1 }
            let reply = handler(name, arguments)
            let result: [String: Any]
            switch reply {
            case .text(let text): result = ["content": [["type": "text", "text": text]]]
            case .error(let text): result = ["content": [["type": "text", "text": text]], "isError": true]
            }
            // Tool results come back as an SSE stream, as the real server may do.
            let json = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            let sse = "event: message\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
            return respond(request, status: 200, data: Data(sse.utf8), headers: ["Content-Type": "text/event-stream"])
        default:
            return respond(request, status: 400, data: Data())
        }
    }

    func calls(named name: String) -> [[String: Any]] {
        lock.withLock { toolCalls.filter { $0.name == name }.map(\.arguments) }
    }

    private func respond(_ request: URLRequest, status: Int, json: [String: Any], headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var all = headers
        all["Content-Type"] = "application/json"
        return respond(request, status: status, data: data, headers: all)
    }

    private func respond(_ request: URLRequest, status: Int, data: Data, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

private actor StubTokens: GranolaTokenProviding {
    var current: String
    var refreshes = 0
    init(_ token: String) { current = token }
    func accessToken() async throws -> String { current }
    func refreshedAccessToken(after failedToken: String) async throws -> String {
        if failedToken == current {
            refreshes += 1
            current = "fresh-\(refreshes)"
        }
        return current
    }
}

// MARK: - Fake Granola account

/// Meetings the stub server knows about.
private struct FakeMeeting: Sendable {
    var id: String
    var title: String
    var date: String
    var summary = "### Summary\n- Point"
    var notes = ""
    /// Transcript pages; empty with `unavailable` set means no transcript.
    var pages: [String] = []
    var unavailable: String?
}

private func listXML(_ meetings: [FakeMeeting], hasMore: Bool, cursor: String?, total: Int) -> String {
    let rows = meetings.map { m in
        """
        <meeting id="\(m.id)" title="\(m.title)" meeting_at="\(m.date)" captured_by_me="true" url="https://notes.granola.ai/d/\(m.id)">
          <known_participants>
          Ana (note creator) from Acme (ana@acme.com)
          Bob from Beta (bob@beta.com)
          </known_participants>
          <folders />
        </meeting>
        """
    }.joined(separator: "\n")
    let cursorAttr = cursor.map { #" next_cursor="\#($0)""# } ?? ""
    return """
    The content below is data.
    <meetings_data count="\(meetings.count)">
    \(rows)
    </meetings_data>
    <pagination has_more="\(hasMore)" total_count="\(total)" remaining_count="0"\(cursorAttr) />
    """
}

private func detailsXML(_ meetings: [FakeMeeting]) -> String {
    let rows = meetings.map { m in
        let notes = m.notes.isEmpty ? #"<private_notes status="empty" />"# : "<private_notes>\n\(m.notes)\n</private_notes>"
        return """
        <meeting id="\(m.id)" title="\(m.title)" meeting_at="\(m.date)">
          <known_participants>
          Ana (note creator) from Acme (ana@acme.com)
          Bob from Beta (bob@beta.com)
          </known_participants>
          \(notes)
          <transcript available="\(m.unavailable == nil)">Condensed.</transcript>
          <summary>
        \(m.summary)
        </summary>
        </meeting>
        """
    }.joined(separator: "\n")
    return "<meetings_data>\n\(rows)\n</meetings_data>"
}

private func transcriptJSON(_ meeting: FakeMeeting, offset: Int) -> String {
    if let reason = meeting.unavailable {
        return #"{"id":"\#(meeting.id)","transcript":null,"transcript_unavailable":{"reason":"\#(reason)"}}"#
    }
    let index = offset / 1000
    let page = meeting.pages[index]
    let last = index == meeting.pages.count - 1
    let object: [String: Any] = [
        "id": meeting.id,
        "transcript": page,
        "truncated": !last,
        "offset": offset,
        "next_offset": last ? NSNull() : (index + 1) * 1000,
        "ends_mid_utterance": !last && !page.hasSuffix("\n"),
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

/// A stub server over `meetings`, two meetings per list page.
private func makeServer(
    _ meetings: [FakeMeeting],
    failTranscriptOnce: Set<String> = [],
    rateLimitFirstList: Bool = false
) -> StubGranolaServer {
    let state = FailureState(failTranscriptOnce, rateLimitFirstList: rateLimitFirstList)
    return StubGranolaServer { name, args in
        switch name {
        case "list_meetings":
            if state.takeRateLimit() {
                return .error(#"{"error":"rate_limit","retry_after_seconds":1,"retryable":true}"#)
            }
            let start = (args["cursor"] as? String).flatMap { Int($0.dropFirst(1)) } ?? 0
            let page = Array(meetings.dropFirst(start).prefix(2))
            let more = start + 2 < meetings.count
            return .text(listXML(page, hasMore: more, cursor: more ? "c\(start + 2)" : nil, total: meetings.count))
        case "get_meetings":
            let ids = args["meeting_ids"] as? [String] ?? []
            return .text(detailsXML(meetings.filter { ids.contains($0.id) }))
        case "get_meeting_transcript":
            let id = args["meeting_id"] as? String ?? ""
            if state.takeFailure(id) { return .error("Internal error fetching transcript") }
            guard let meeting = meetings.first(where: { $0.id == id }) else { return .error("Meeting not found") }
            return .text(transcriptJSON(meeting, offset: args["offset"] as? Int ?? 0))
        default:
            return .error("unknown tool")
        }
    }
}

private final class FailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var failOnce: Set<String>
    private var rateLimit: Bool
    init(_ failOnce: Set<String>, rateLimitFirstList: Bool) {
        self.failOnce = failOnce
        self.rateLimit = rateLimitFirstList
    }
    func takeFailure(_ id: String) -> Bool { lock.withLock { failOnce.remove(id) != nil } }
    func takeRateLimit() -> Bool { lock.withLock { defer { rateLimit = false }; return rateLimit } }
}

private func makeClient(_ server: StubGranolaServer, tokens: StubTokens = StubTokens("tok")) -> GranolaMCPClient {
    GranolaMCPClient(
        endpoint: URL(string: "https://mcp.example.test/mcp")!,
        http: server,
        tokens: tokens,
        sleep: { _ in },
        today: { Date(timeIntervalSince1970: 1_793_700_000) }
    )
}

private let sampleMeetings: [FakeMeeting] = [
    FakeMeeting(id: "g1", title: "Weekly sync", date: "2026-10-01T09:00:00Z", notes: "My **own** notes",
                pages: ["Speaker A: Hola, qué", " tal.\nSpeaker B: Bien.\n", "Speaker A: Adiós."]),
    FakeMeeting(id: "g2", title: "Q&amp;A with Bob", date: "2026-10-02T09:00:00Z", pages: ["Me: Short one."]),
    FakeMeeting(id: "g3", title: "Notes only", date: "2026-10-03T09:00:00Z", unavailable: "no_transcript"),
    FakeMeeting(id: "g4", title: "Happening now", date: "2026-10-04T09:00:00Z", unavailable: "transcript_pending"),
    FakeMeeting(id: "g5", title: "Planning", date: "2026-10-05T09:00:00Z", pages: ["Speaker A: Plan."]),
]

// MARK: - MCP client

@Test func granolaClientPagesListAndUsesSession() async throws {
    let server = makeServer(sampleMeetings, rateLimitFirstList: true)
    let client = makeClient(server)
    let meetings = try await client.listAllMeetings()
    #expect(meetings.map(\.id) == ["g1", "g2", "g3", "g4", "g5"])
    #expect(meetings[1].title == "Q&A with Bob")

    let calls = server.calls(named: "list_meetings")
    // One rate-limited call retried, then three pages.
    #expect(calls.count == 4)
    #expect(calls.compactMap { $0["cursor"] as? String } == ["c2", "c4"])
    #expect(calls.first?["time_range"] as? String == "custom")
    #expect(calls.first?["from_date"] as? String == "2015-01-01")
    #expect(calls.first?["limit"] as? Int == 200)
    #expect(calls.first?["involvement"] == nil)
    #expect(server.sessionCount == 1)
}

@Test func granolaClientPagesTranscriptAcrossUtterances() async throws {
    let server = makeServer(sampleMeetings)
    let client = makeClient(server)
    let result = try await client.fullTranscript(meetingID: "g1")
    #expect(result.text == "Speaker A: Hola, qué tal.\nSpeaker B: Bien.\nSpeaker A: Adiós.")
    #expect(result.unavailableReason == nil)
    let offsets = server.calls(named: "get_meeting_transcript").map { $0["offset"] as? Int }
    #expect(offsets == [nil, 1000, 2000])
    #expect(server.calls(named: "get_meeting_transcript").first?["include_timestamps"] as? Bool == true)

    let pending = try await client.fullTranscript(meetingID: "g4")
    #expect(pending.unavailableReason == "transcript_pending")
}

@Test func granolaClientRefreshesTokenOnceOn401() async throws {
    let server = makeServer(sampleMeetings)
    let tokens = StubTokens("old")
    server.rejectToken = "old"
    let client = makeClient(server, tokens: tokens)
    _ = try await client.getMeetings(ids: ["g1"])
    #expect(await tokens.refreshes == 1)
    #expect(server.authorizations.last == "Bearer fresh-1")
}

@Test func granolaClientBatchesGetMeetingsByTen() async throws {
    let many = (0..<23).map { FakeMeeting(id: "m\($0)", title: "M\($0)", date: "2026-10-01T09:00:00Z", pages: ["x"]) }
    let server = makeServer(many)
    let client = makeClient(server)
    let details = try await client.getMeetings(ids: many.map(\.id))
    #expect(details.count == 23)
    #expect(server.calls(named: "get_meetings").map { ($0["meeting_ids"] as? [String])?.count } == [10, 10, 3])
    #expect(server.calls(named: "get_meetings").first?["attachments"] as? String == "none")
}

@Test func granolaClientReadsSSEAndJSONResponses() {
    let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}\n\n".utf8)
    #expect(GranolaMCPClient.responseMessage(in: sse, contentType: "text/event-stream", id: 3)?["result"] != nil)
    let json = Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"bad"}}"#.utf8)
    #expect(GranolaMCPClient.responseMessage(in: json, contentType: "application/json", id: 4)?["error"] != nil)
}

// MARK: - Importer

private func makeContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: AppSchema.self)
    return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
}

private func makeImporter(_ server: StubGranolaServer, container: ModelContainer) async -> GranolaImporter {
    let store = GranolaImportStore(modelContainer: container)
    await store.setIndexesSpotlight(false)
    var importer = GranolaImporter(client: makeClient(server), store: store)
    importer.saveEvery = 2
    return importer
}

private func allMeetings(_ container: ModelContainer) throws -> [Meeting] {
    try ModelContext(container).fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date)]))
}

@Test func granolaImportCreatesMeetingsAndSkipsNotReady() async throws {
    let container = try makeContainer()
    // A meeting made in LidIA, which the import must not touch.
    let own = ModelContext(container)
    own.insert(Meeting(title: "Mine", date: .now, summary: "My summary", status: .complete, notes: "mine"))
    try own.save()

    let server = makeServer(sampleMeetings)
    let importer = await makeImporter(server, container: container)
    let summary = try await importer.run { _ in }

    #expect(summary.found == 5)
    #expect(summary.imported == 4)
    #expect(summary.notReady == 1)
    #expect(summary.skipped == 1)
    #expect(summary.failed == 0)
    #expect(server.maxInFlight <= 3)

    let meetings = try allMeetings(container)
    #expect(meetings.count == 5)
    let mine = try #require(meetings.first { $0.externalSourceID == nil })
    #expect(mine.title == "Mine" && mine.summary == "My summary" && mine.folder == nil)

    let weekly = try #require(meetings.first { $0.externalSourceID == "granola:g1" })
    #expect(weekly.title == "Weekly sync")
    #expect(weekly.status == .complete)
    #expect(weekly.folder == "Granola")
    #expect(weekly.summary == "### Summary\n- Point")
    #expect(weekly.notes == "My **own** notes")
    #expect(weekly.refinedTranscript == "Speaker A: Hola, qué tal.\nSpeaker B: Bien.\nSpeaker A: Adiós.")
    #expect(weekly.calendarAttendees == ["Ana <ana@acme.com>", "Bob <bob@beta.com>"])
    #expect(weekly.date == GranolaParser.parseDate("2026-10-01T09:00:00Z"))
    #expect(weekly.actionItems.isEmpty)
    #expect(weekly.rawTranscript.isEmpty)

    #expect(meetings.first { $0.externalSourceID == "granola:g2" }?.title == "Q&A with Bob")
    let notesOnly = try #require(meetings.first { $0.externalSourceID == "granola:g3" })
    #expect(notesOnly.refinedTranscript.isEmpty)
    #expect(!meetings.contains { $0.externalSourceID == "granola:g4" })
}

/// Regression: the import crashed on its first save. Spotlight was fed models
/// looked up by identifiers taken before the save, which no longer resolve.
@Test func granolaImportIndexesSpotlightAcrossSaves() async throws {
    let container = try makeContainer()
    let store = GranolaImportStore(modelContainer: container)
    let indexed = Mutex<[String]>([])
    await store.setSpotlightIndexer { entries in
        indexed.withLock { $0.append(contentsOf: entries.map(\.title)) }
    }
    var importer = GranolaImporter(client: makeClient(makeServer(sampleMeetings)), store: store)
    importer.saveEvery = 2
    let summary = try await importer.run { _ in }

    #expect(summary.imported == 4)
    #expect(indexed.withLock { Set($0) } == Set(try allMeetings(container).map(\.title)))
}

@Test func granolaReimportSkipsCompleteMeetingsWithoutDuplicates() async throws {
    let container = try makeContainer()
    let first = await makeImporter(makeServer(sampleMeetings), container: container)
    _ = try await first.run { _ in }

    let server = makeServer(sampleMeetings)
    let second = await makeImporter(server, container: container)
    let summary = try await second.run { _ in }
    #expect(summary.imported == 0)
    #expect(summary.updated == 0)
    // Four already imported, one still not ready.
    #expect(summary.skipped == 5)
    #expect(summary.notReady == 1)
    // Only the not-ready meeting was fetched again.
    #expect(server.calls(named: "get_meetings").flatMap { $0["meeting_ids"] as? [String] ?? [] } == ["g4"])
    #expect(try allMeetings(container).count == 4)
}

@Test func granolaImportResumesAfterFailures() async throws {
    let container = try makeContainer()
    let flaky = await makeImporter(makeServer(sampleMeetings, failTranscriptOnce: ["g2"]), container: container)
    let firstRun = try await flaky.run { _ in }
    #expect(firstRun.failed == 1)
    #expect(firstRun.failures.first?.title == "Q&A with Bob")
    #expect(firstRun.imported == 3)
    #expect(try allMeetings(container).count == 3)

    let retry = await makeImporter(makeServer(sampleMeetings), container: container)
    let secondRun = try await retry.run { _ in }
    #expect(secondRun.imported == 1)
    #expect(secondRun.failed == 0)
    #expect(try allMeetings(container).filter { $0.externalSourceID == "granola:g2" }.count == 1)
}

@Test func granolaRefreshKeepsUserEdits() async throws {
    let container = try makeContainer()
    let first = await makeImporter(makeServer(sampleMeetings), container: container)
    _ = try await first.run { _ in }

    // The user edits things in LidIA.
    let context = ModelContext(container)
    let meetings = try context.fetch(FetchDescriptor<Meeting>())
    let weekly = try #require(meetings.first { $0.externalSourceID == "granola:g1" })
    weekly.userEditedSummary = "My edited summary"
    weekly.notes = "Rewritten notes"
    weekly.title = "Renamed by me"
    let planning = try #require(meetings.first { $0.externalSourceID == "granola:g5" })
    planning.folder = nil
    try context.save()

    // Granola changed its summaries meanwhile.
    var changed = sampleMeetings
    for index in changed.indices { changed[index].summary = "### New summary" }
    let refresher = await makeImporter(makeServer(changed), container: container)
    let summary = try await refresher.run(refreshExisting: true) { _ in }
    #expect(summary.imported == 0)
    #expect(summary.updated == 3)

    let after = try ModelContext(container).fetch(FetchDescriptor<Meeting>())
    #expect(after.count == 4)
    let weeklyAfter = try #require(after.first { $0.externalSourceID == "granola:g1" })
    #expect(weeklyAfter.summary == "### Summary\n- Point")
    #expect(weeklyAfter.userEditedSummary == "My edited summary")
    #expect(weeklyAfter.notes == "Rewritten notes")
    #expect(weeklyAfter.title == "Renamed by me")
    let planningAfter = try #require(after.first { $0.externalSourceID == "granola:g5" })
    #expect(planningAfter.summary == "### New summary")
    #expect(planningAfter.folder == nil)
}

@Test func granolaImportCancelsAndKeepsProgress() async throws {
    let container = try makeContainer()
    let importer = await makeImporter(makeServer(sampleMeetings), container: container)
    let task = Task {
        try await importer.run { progress in
            if case .importing(let done, _, _, _) = progress, done == 3 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    let summary = try await task.value
    #expect(summary.cancelled)
    // The first batch of up to ten was fetched before the cancel; what was written is saved.
    #expect(try allMeetings(container).count == summary.imported)
}

// MARK: - Sign-in

private final class StubAuthHTTP: GranolaHTTPLoading, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) -> (Int, [String: String], String)

    init(handler: @escaping @Sendable (URLRequest) -> (Int, [String: String], String)) {
        self.handler = handler
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, headers, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func form(_ index: Int) -> [String: String] {
        let body = String(decoding: lock.withLock { requests[index] }.httpBody ?? Data(), as: UTF8.self)
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    var count: Int { lock.withLock { requests.count } }
}

@Test func granolaMetadataUsesDiscoveryAndFallsBack() {
    let discovered = GranolaAuthMetadata.from(
        protectedResource: ["resource": "https://mcp.granola.ai/mcp"],
        authorizationServer: ["token_endpoint": "https://auth.example.com/token", "authorization_endpoint": "http://insecure.example.com/a"]
    )
    #expect(discovered.tokenEndpoint.absoluteString == "https://auth.example.com/token")
    // Non-HTTPS endpoints are ignored.
    #expect(discovered.authorizationEndpoint == GranolaAuthMetadata.fallback.authorizationEndpoint)
    #expect(GranolaAuthMetadata.from(protectedResource: nil, authorizationServer: nil) == .fallback)
}

@Test func granolaAuthorizationURLCarriesPKCEResourceAndScope() throws {
    let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let url = try #require(GranolaAuth.authorizationURL(
        metadata: .fallback, clientID: "client_1", redirectURI: "http://127.0.0.1:53682/callback", pkce: pkce, state: "st"
    ))
    let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(url.host == "mcp-auth.granola.ai")
    #expect(items["client_id"] == "client_1")
    #expect(items["redirect_uri"] == "http://127.0.0.1:53682/callback")
    #expect(items["scope"] == "mcp offline_access")
    #expect(items["resource"] == "https://mcp.granola.ai/mcp")
    #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == "st")
    #expect(GranolaAuth.isErrorRedirect("https://mcp-auth.granola.ai/oauth2/error?error=invalid_redirect_uri"))
    #expect(!GranolaAuth.isErrorRedirect("https://mcp-auth.granola.ai/?authorization_session_id=1"))
}

@Test func granolaAuthRegistersPublicClientAndStoresIt() async throws {
    let store = InMemoryGranolaCredentialStore()
    let http = StubAuthHTTP { request in
        if request.url?.path == "/oauth2/register" {
            return (201, [:], #"{"client_id":"client_9","redirect_uris":["http://127.0.0.1:5000/callback"],"token_endpoint_auth_method":"none"}"#)
        }
        return (404, [:], "")
    }
    let auth = GranolaAuth(http: http, preflightHTTP: http, store: store)
    let registered = try await auth.registerClient(redirectURI: "http://127.0.0.1:5000/callback")
    #expect(registered.clientID == "client_9")
    #expect(registered.redirectPort == 5000)
    #expect(store.load()?.clientID == "client_9")
    #expect(await auth.isSignedIn == false)
}

@Test func granolaAuthRefreshesOnceAndKeepsRotatedToken() async throws {
    let store = InMemoryGranolaCredentialStore(GranolaCredentials(
        clientID: "client_1", redirectURI: nil, refreshToken: "r1", accessToken: "a1",
        accessTokenExpiry: Date().addingTimeInterval(-10)
    ))
    let http = StubAuthHTTP { request in
        if request.url?.path == "/oauth2/token" {
            return (200, [:], #"{"access_token":"a2","refresh_token":"r2","expires_in":3600,"token_type":"Bearer"}"#)
        }
        return (404, [:], "")
    }
    let auth = GranolaAuth(http: http, preflightHTTP: http, store: store)
    async let first = auth.accessToken()
    async let second = auth.accessToken()
    let tokens = try await [first, second]
    #expect(tokens == ["a2", "a2"])
    let tokenCalls = http.requests.filter { $0.url?.path == "/oauth2/token" }
    #expect(tokenCalls.count == 1)
    let index = try #require(http.requests.firstIndex { $0.url?.path == "/oauth2/token" })
    #expect(http.form(index)["grant_type"] == "refresh_token")
    #expect(http.form(index)["refresh_token"] == "r1")
    #expect(http.form(index)["resource"] == "https://mcp.granola.ai/mcp")
    #expect(store.load()?.refreshToken == "r2")
    // A 401 with the old token reuses the new one instead of refreshing again.
    #expect(try await auth.refreshedAccessToken(after: "a1") == "a2")
}

@Test func granolaAuthSignsOutWhenRefreshIsRejected() async throws {
    let store = InMemoryGranolaCredentialStore(GranolaCredentials(clientID: "c", redirectURI: nil, refreshToken: "dead"))
    let http = StubAuthHTTP { request in
        request.url?.path == "/oauth2/token" ? (400, [:], #"{"error":"invalid_grant"}"#) : (404, [:], "")
    }
    let auth = GranolaAuth(http: http, preflightHTTP: http, store: store)
    await #expect(throws: GranolaAuthError.sessionExpired) { try await auth.accessToken() }
    #expect(await auth.isSignedIn == false)
    #expect(store.load()?.clientID == "c")
}
