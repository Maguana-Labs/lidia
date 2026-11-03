import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import LidIA

// The agent harness with scripted models: no network, no MLX.

// MARK: - Fakes

/// An `LLMClient` that streams scripted replies, one per request, and
/// records what it was sent.
final class AgentScriptedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var received: [[LLMChatMessage]] = []

    init(_ replies: [String]) { self.replies = replies }

    var requests: [[LLMChatMessage]] { lock.withLock { received } }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        next(messages)
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        let reply = next(messages)
        return AsyncThrowingStream { continuation in
            // Stream in small pieces, like a model would.
            var rest = Substring(reply)
            while !rest.isEmpty {
                continuation.yield(String(rest.prefix(7)))
                rest = rest.dropFirst(7)
            }
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { ["scripted"] }

    private func next(_ messages: [LLMChatMessage]) -> String {
        lock.withLock {
            received.append(messages)
            return replies.isEmpty ? "(script ended)" : replies.removeFirst()
        }
    }
}

/// A backend that returns scripted turns (as a native tool API would).
final class AgentScriptedBackend: AgentBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [AgentTurnResponse]
    private let repeatLast: Bool
    private let delay: Duration?
    private(set) var received: [AgentTurnRequest] = []

    init(_ turns: [AgentTurnResponse], repeatLast: Bool = false, delay: Duration? = nil) {
        self.turns = turns
        self.repeatLast = repeatLast
        self.delay = delay
    }

    var kind: AgentBackendKind { .anthropicTools }
    var requests: [AgentTurnRequest] { lock.withLock { received } }

    func turn(_ request: AgentTurnRequest) async throws -> AgentTurnResponse {
        if let delay { try await Task.sleep(for: delay) }
        let response: AgentTurnResponse = lock.withLock {
            received.append(request)
            if turns.count > 1 || !repeatLast { return turns.isEmpty ? AgentTurnResponse(text: "(script ended)") : turns.removeFirst() }
            return turns[0]
        }
        if !response.text.isEmpty { request.onText(response.text) }
        return response
    }
}

private func call(_ name: String, _ arguments: String, id: String = UUID().uuidString) -> AgentToolCall {
    AgentToolCall(id: id, name: name, argumentsJSON: arguments)
}

@MainActor
private struct Library {
    let container: ModelContainer
    let context: ModelContext
    let northwind: Meeting
    let item: ActionItem

    init() throws {
        container = try ModelContainer(for: Meeting.self, ActionItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let calendar = Calendar(identifier: .gregorian)
        let old = Meeting(title: "Northwind x Harborcloud - SaaS Platform on AWS", date: calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 13))!)
        old.calendarAttendees = ["Mateo K <mateo.k@northwind.example>", "Alex Moreno <alex@harborcloud.example>"]
        old.summary = "Agreed to start with the landing zone and separate prod and staging accounts."
        old.folder = "Northwind"
        let other = Meeting(title: "Engineering - WBR", date: calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 11))!)
        other.summary = "Weekly business review of engineering metrics."
        context.insert(old)
        context.insert(other)
        let item = ActionItem(title: "Send the landing zone proposal", assignee: "Alex Moreno")
        item.meeting = old
        old.actionItems.append(item)
        context.insert(item)
        try context.save()
        northwind = old
        self.item = item
    }

    func toolContext(destinations: AgentDestinations = AgentDestinations(clickUp: true)) -> AgentToolContext {
        AgentToolContext(modelContext: context, settings: nil, destinations: destinations, now: Date(timeIntervalSince1970: 1_793_000_000))
    }

    func actionItemCount() throws -> Int { try context.fetchCount(FetchDescriptor<ActionItem>()) }
}

@MainActor
private func harness(_ backend: any AgentBackend, family: AgentModelFamily = .claude, maxSteps: Int = 5, deadline: TimeInterval = 30, tools: AgentToolRegistry = LidIATools.all(destinations: AgentDestinations(clickUp: true))) -> AgentHarness {
    AgentHarness(
        endpoint: AgentHarness.Endpoint(backend: backend, family: family, model: "test-model", modelLabel: "Test", providerName: "Test", locality: .onDevice),
        tools: tools,
        configuration: AgentHarness.Configuration(maxSteps: maxSteps, deadline: deadline, effort: .low, toolResultLimit: 4_000)
    )
}

private let askPrompt = AgentPromptContext(task: .ask, toolFormat: .native, tools: [], maxSteps: 5)

// MARK: - Loop

@Suite("Agent harness")
@MainActor
struct AgentHarnessTests {

    @Test("JSON actions: tool call, result fed back, then a streamed answer")
    func jsonActionLoop() async throws {
        let library = try Library()
        let client = AgentScriptedClient([
            #"{"tool": "search_meetings", "arguments": {"query": "Northwind"}}"#,
            "You agreed to start with the landing zone (Northwind x Harborcloud, 2026-10-20).",
        ])
        let agent = harness(JSONActionBackend(client: client), family: .qwen)
        var streamed = ""
        let result = await agent.run(prompt: askPrompt, history: [], userMessage: "What did we agree with Northwind last time?", context: library.toolContext()) { event in
            if case .text(let text) = event { streamed += text }
            if case .resetText = event { streamed = "" }
        }

        #expect(result.outcome == .answered)
        #expect(result.answer.hasPrefix("You agreed to start with the landing zone"))
        #expect(streamed == result.answer, "The answer streams; the JSON action never shows")
        #expect(result.transcript.modelCalls.count == 2)
        #expect(result.transcript.toolRuns.map(\.status) == [.executed])
        #expect(result.meetingTitles.contains("Northwind x Harborcloud - SaaS Platform on AWS"))

        // The second request carried the tool result, as a user message.
        let second = try #require(client.requests.last)
        #expect(second.first?.role == "system")
        #expect(second.first?.content.contains("search_meetings(") == true, "JSON-action prompt lists the tools")
        #expect(second.last?.content.hasPrefix("Result of search_meetings:") == true)
        #expect(second.last?.content.contains("Northwind x Harborcloud") == true)
        // Transcript: the exact conversation.
        #expect(result.transcript.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(result.transcript.backend == .jsonActions)
    }

    @Test("Step limit: the last step offers no tools, and the run stops")
    func stepLimit() async throws {
        let library = try Library()
        let backend = AgentScriptedBackend(
            [AgentTurnResponse(text: "", toolCalls: [call("list_projects", "{}")])],
            repeatLast: true
        )
        let result = await harness(backend, maxSteps: 3).run(prompt: askPrompt, history: [], userMessage: "Projects?", context: library.toolContext())
        #expect(backend.requests.count == 3)
        #expect(backend.requests[0].tools.isEmpty == false)
        #expect(backend.requests[2].tools.isEmpty, "The final step must make the model answer")
        #expect(result.outcome == .stepLimit)
        #expect(result.transcript.toolRuns.count == 2)
    }

    @Test("Deadline: a slow model is stopped and the run returns")
    func deadline() async throws {
        let library = try Library()
        let backend = AgentScriptedBackend([AgentTurnResponse(text: "late")], delay: .seconds(10))
        let started = Date()
        let result = await harness(backend, deadline: 0.3).run(prompt: askPrompt, history: [], userMessage: "Hi", context: library.toolContext())
        #expect(result.outcome == .deadline)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!result.answer.isEmpty)
    }

    @Test("Cancellation ends the run as cancelled")
    func cancellation() async throws {
        let library = try Library()
        let backend = AgentScriptedBackend([AgentTurnResponse(text: "late")], delay: .seconds(10))
        let agent = harness(backend)
        let context = library.toolContext()
        let task = Task { @MainActor in
            await agent.run(prompt: askPrompt, history: [], userMessage: "Hi", context: context)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
    }

    @Test("Native tool calls with bad arguments come back as errors the model can fix")
    func nativeInvalidArguments() async throws {
        let library = try Library()
        let backend = AgentScriptedBackend([
            AgentTurnResponse(text: "", toolCalls: [call("get_meeting", #"{"query": "x"}"#, id: "t1")]),
            AgentTurnResponse(text: "", toolCalls: [call("nope", "{}", id: "t2")]),
            AgentTurnResponse(text: "Done."),
        ])
        let result = await harness(backend).run(prompt: askPrompt, history: [], userMessage: "?", context: library.toolContext())
        #expect(result.transcript.toolRuns.map(\.status) == [.invalidArguments, .unknownTool])
        let errors = result.transcript.messages.filter { $0.role == .tool }
        #expect(errors.allSatisfy { $0.isError })
        #expect(errors.first?.text.contains("\"meeting_id\" is required") == true)
        #expect(result.answer == "Done.")
    }

    // MARK: Side effects

    @Test("Mutating tools never run without confirmation")
    func mutatingToolsWaitForConfirmation() async throws {
        let library = try Library()
        let itemID = LidIATools.shortID(library.item.id)
        let backend = AgentScriptedBackend([
            AgentTurnResponse(text: "", toolCalls: [
                call("create_action_item", #"{"title": "Book the kickoff room", "deadline": "2026-11-10"}"#),
                call("update_action_item_status", #"{"action_item_id": "\#(itemID)", "status": "done"}"#),
            ]),
            AgentTurnResponse(text: "Both changes are waiting for your confirmation."),
        ])
        let before = try library.actionItemCount()
        let tools = LidIATools.all(destinations: AgentDestinations())
        let context = library.toolContext()
        let result = await harness(backend, tools: tools).run(prompt: askPrompt, history: [], userMessage: "Add it and close the other", context: context)

        #expect(try library.actionItemCount() == before, "Nothing was created")
        #expect(library.item.isCompleted == false, "Nothing was moved")
        #expect(result.pendingActions.count == 2)
        #expect(result.pendingActions.allSatisfy { $0.state == .pending })
        #expect(result.transcript.toolRuns.map(\.status) == [.awaitingConfirmation, .awaitingConfirmation])
        #expect(result.pendingActions[1].summary == "Move “Send the landing zone proposal” to Done")

        // Only the explicit confirmation runs them.
        let created = await AgentHarness.confirm(result.pendingActions[0], tools: tools, context: context)
        #expect(created.state == .confirmed)
        #expect(try library.actionItemCount() == before + 1)
        let moved = await AgentHarness.confirm(result.pendingActions[1], tools: tools, context: context)
        #expect(moved.state == .confirmed)
        #expect(LiveModel.actionItem(library.item.id, in: library.context)?.isCompleted == true)
        // A confirmed action can't run twice.
        let again = await AgentHarness.confirm(created, tools: tools, context: context)
        #expect(again == created)
        #expect(try library.actionItemCount() == before + 1)
    }

    @Test("propose_dispatch drafts a proposal and sends nothing; confirm refuses non-mutating tools")
    func proposeDispatchOnlyDrafts() async throws {
        let library = try Library()
        let itemID = LidIATools.shortID(library.item.id)
        let backend = AgentScriptedBackend([
            AgentTurnResponse(text: "", toolCalls: [call("propose_dispatch", #"{"destination": "clickup", "title": "Landing zone proposal", "body": "From the Northwind call.", "action_item_id": "\#(itemID)"}"#)]),
            AgentTurnResponse(text: "I drafted a ClickUp task."),
        ])
        let tools = LidIATools.commentTools(destinations: AgentDestinations(clickUp: true))
        let result = await harness(backend, tools: tools).run(prompt: askPrompt, history: [], userMessage: "ticket", context: library.toolContext())
        let proposal = try #require(result.proposals.first)
        #expect(proposal == AgentDispatchProposal(destination: "clickup", title: "Landing zone proposal", body: "From the Northwind call.", actionItemID: library.item.id))
        #expect(library.item.confirmedDestination == nil)
        let mapped = AgentDispatch.proposal(from: result, itemTitle: library.item.title)
        #expect(mapped?.kind == .dispatch(destination: "clickup"))
        #expect(mapped?.byAI == true)

        let fake = AgentPendingAction(toolName: "propose_dispatch", argumentsJSON: "{}", summary: "x")
        #expect(await AgentHarness.confirm(fake, tools: tools, context: library.toolContext()).state == .failed)
    }

    @Test("Destinations the user hasn't set up aren't offered")
    func destinationsAreGated() {
        let spec = LidIATools.proposeDispatch(AgentDestinations()).spec
        let destination = spec.parameters.first { $0.name == "destination" }
        #expect(destination?.kind == .oneOf(["reminder", "email"]))
        if case .failure = spec.validate(#"{"destination": "clickup", "title": "x"}"#) {} else {
            Issue.record("clickup must be rejected when not configured")
        }
    }
}

// MARK: - Live run

@Suite("Agent run (live UI model)")
@MainActor
struct AgentRunTests {
    @Test("Phase, steps, sources (deduplicated, dated), follow-ups and the final answer")
    func liveRun() async throws {
        let library = try Library()
        // A second meeting with the same title, to check sources stay apart.
        let later = Meeting(title: library.northwind.title, date: library.northwind.date.addingTimeInterval(7 * 86_400))
        later.summary = "Reviewed the account structure."
        later.folder = "Northwind"
        library.context.insert(later)
        try library.context.save()
        let id = LidIATools.shortID(library.northwind.id)
        let backend = AgentScriptedBackend([
            AgentTurnResponse(text: "", toolCalls: [call("search_meetings", #"{"query": "Northwind", "from": "2026-10-01"}"#, id: "s")]),
            AgentTurnResponse(text: "", toolCalls: [call("get_meeting", #"{"meeting_id": "\#(id)"}"#, id: "g")]),
            AgentTurnResponse(text: "On 2026-10-20 you agreed on the landing zone."),
        ])
        let agent = harness(backend)
        let run = agent.makeRun(question: "What did we agree with Northwind?")
        #expect(run.phase == .thinking)
        let result = await agent.run(prompt: askPrompt, history: [], userMessage: run.question, context: library.toolContext(), live: run)

        #expect(run.phase == .done)
        #expect(run.isFinished)
        #expect(run.answer == "On 2026-10-20 you agreed on the landing zone.")
        #expect(run.steps.map(\.status) == [.succeeded, .succeeded])
        #expect(run.steps[0].summary == "Searched meetings: Northwind, since 2026-10-01")
        #expect(run.steps[0].resultCount == 2)
        #expect(run.steps[1].summary.hasPrefix("Read “Northwind x Harborcloud - SaaS Platform on AWS”, 2026-10-"))
        #expect(run.steps.allSatisfy { $0.duration != nil })
        // Sources: the meeting that was read, with its ID, date and an excerpt.
        #expect(run.sources.map(\.id) == [library.northwind.id])
        #expect(run.sources.first?.excerpt?.contains("landing zone") == true)
        #expect(result.meetingsSeen.count == 2, "Both same-titled meetings were seen, kept apart by ID")
        #expect(ChatBarViewModel.sourceLabels(result.meetingsSeen).allSatisfy { $0.contains(" · 2026-") })
        #expect((2...3).contains(run.followUps.count))
        #expect(run.modelAndLocality == "Test · On this Mac")
        #expect(run.transcript != nil)
    }

    @Test("Approvals: prepared changes and drafted dispatches wait as structured requests")
    func approvals() async throws {
        let library = try Library()
        let itemID = LidIATools.shortID(library.item.id)
        let backend = AgentScriptedBackend([
            AgentTurnResponse(text: "", toolCalls: [
                call("update_action_item_status", #"{"action_item_id": "\#(itemID)", "status": "done"}"#),
                call("propose_dispatch", #"{"destination": "clickup", "title": "Landing zone proposal", "action_item_id": "\#(itemID)"}"#),
            ]),
            AgentTurnResponse(text: "Both are ready for you to confirm."),
        ])
        let agent = harness(backend)
        let run = agent.makeRun(question: "Close it and ticket it")
        _ = await agent.run(prompt: askPrompt, history: [], userMessage: run.question, context: library.toolContext(), live: run)
        #expect(run.phase == .waitingForApproval)
        #expect(run.approvals.count == 2)
        #expect(run.steps.first?.status == .awaitingApproval)
        guard case .change = run.approvals[0].kind, case .dispatch(let proposal) = run.approvals[1].kind else {
            Issue.record("wrong approval kinds"); return
        }
        #expect(proposal.title == "Landing zone proposal")
        #expect(run.approvals[1].allowsFreeText)
        #expect(library.item.isCompleted == false, "Nothing ran yet")

        // Cancel resolves without the handler; confirm goes through it.
        var handled: [AgentApproval.Choice] = []
        run.onApproval = { _, choice in handled.append(choice); return .resolved("Done") }
        await run.respond(to: run.approvals[1].id, with: .option("cancel"))
        #expect(run.approvals[1].state == .resolved("Dismissed"))
        #expect(handled.isEmpty)
        await run.respond(to: run.approvals[0].id, with: .option("confirm"))
        #expect(handled == [.option("confirm")])
        #expect(run.phase == .done)
    }

    @Test("ask_user stops the run with a clarification the user can answer")
    func clarification() async throws {
        let library = try Library()
        let backend = AgentScriptedBackend([
            AgentTurnResponse(text: "", toolCalls: [call("ask_user", #"{"question": "Which Northwind call?", "options": "Oct 20 | Oct 28"}"#)]),
            AgentTurnResponse(text: "never reached"),
        ])
        let agent = harness(backend)
        let run = agent.makeRun(question: "Summarize the Northwind call")
        let result = await agent.run(prompt: askPrompt, history: [], userMessage: run.question, context: library.toolContext(), live: run)
        #expect(backend.requests.count == 1)
        #expect(result.answer == "Which Northwind call?")
        #expect(run.phase == .waitingForApproval)
        let approval = try #require(run.approvals.first)
        #expect(approval.kind == .clarification)
        #expect(approval.options.map(\.label) == ["Oct 20", "Oct 28"])
        #expect(approval.allowsFreeText)
        #expect(run.followUps.isEmpty)
    }
}

// MARK: - JSON actions

@Suite("Agent JSON actions")
@MainActor
struct AgentJSONActionTests {
    let tools = LidIATools.all(destinations: AgentDestinations()).specs

    @Test("Plain text is the answer; one JSON object is a call")
    func interpret() {
        #expect(JSONActionBackend.interpret("Hello there.", tools: tools) == .answer("Hello there."))
        guard case .call(let call) = JSONActionBackend.interpret("```json\n{\"tool\":\"list_projects\",\"arguments\":{}}\n```", tools: tools) else {
            Issue.record("fenced call not read"); return
        }
        #expect(call.name == "list_projects")
        #expect(JSONActionBackend.interpret(#"{"answer": "Nothing found."}"#, tools: tools) == .answer("Nothing found."))
        // The flat form (arguments beside "tool") is the documented one.
        guard case .call(let flat) = JSONActionBackend.interpret(#"{"tool": "get_meeting", "meeting_id": "2fecea55"}"#, tools: tools) else {
            Issue.record("flat call not read"); return
        }
        #expect(AgentJSON.object(flat.argumentsJSON)?["meeting_id"] as? String == "2fecea55")
    }

    @Test("Invalid actions are reported, never guessed")
    func invalid() {
        func problem(_ text: String) -> String? {
            if case .invalid(let problem) = JSONActionBackend.interpret(text, tools: tools) { return problem }
            return nil
        }
        #expect(problem(#"{"tool": "search_meetings", "arguments": {"limit": "lots"}}"#)?.contains("\"limit\" must be an integer") == true)
        #expect(problem(#"{"tool": "delete_everything", "arguments": {}}"#)?.contains("unknown tool") == true)
        #expect(problem(#"{"tool": "get_meeting", "arguments": {}}"#)?.contains("\"meeting_id\" is required") == true)
        #expect(problem(#"{"tool": "update_action_item_status", "arguments": {"action_item_id": "a", "status": "finished"}}"#)?.contains("must be one of") == true)
        #expect(problem(#"{"tool": "search_meetings", "arguments": {"from": "last week"}}"#)?.contains("YYYY-MM-DD") == true)
        #expect(problem(#"{"tool": "search_meetings""#)?.contains("malformed") == true)
        // A reply that starts with a valid action and trails a sentence is accepted.
        if case .call(let trailing) = JSONActionBackend.interpret(#"{"tool": "list_projects", "arguments": {}} I'll check."#, tools: tools) {
            #expect(trailing.name == "list_projects")
        } else {
            Issue.record("leading object not accepted")
        }
        // Prose with an embedded action is not parsed as a call.
        #expect(problem(#"Let me check. {"tool": "list_projects", "arguments": {}}"#) != nil)
        #expect(problem("") != nil)
    }

    @Test("Lenient where safe: numeric strings, nulls, unknown keys, enum case")
    func lenient() throws {
        let spec = LidIATools.listActionItems.spec
        guard case .success(let arguments) = spec.validate(#"{"limit": "7", "assignee": null, "status": "In Progress", "extra": 1}"#) else {
            Issue.record("should validate"); return
        }
        #expect(arguments.integer("limit") == 7)
        #expect(arguments.string("assignee") == nil)
        #expect(arguments.string("status") == "in_progress")
    }

    @Test("One repair attempt: an invalid action is shown back to the model once")
    func repairOnce() async throws {
        let library = try Library()
        let id = LidIATools.shortID(library.northwind.id)
        let client = AgentScriptedClient([
            #"{"tool": "get_meeting", "arguments": {}}"#,
            #"{"tool": "get_meeting", "arguments": {"meeting_id": "\#(id)"}}"#,
            "They agreed on separate prod and staging accounts.",
        ])
        let result = await harness(JSONActionBackend(client: client), family: .qwen)
            .run(prompt: askPrompt, history: [], userMessage: "Details?", context: library.toolContext())
        #expect(result.outcome == .answered)
        #expect(result.transcript.entries.contains { if case .repair = $0 { true } else { false } })
        let repairRequest = client.requests[1]
        #expect(repairRequest.last?.content.contains("could not be used") == true)
        #expect(repairRequest.last?.content.contains("\"meeting_id\" is required") == true)
        #expect(result.transcript.toolRuns.first?.status == .executed)
    }

    @Test("Still invalid after the repair: the run fails cleanly")
    func repairFails() async throws {
        let library = try Library()
        let client = AgentScriptedClient([#"{"tool": "nope"}"#, #"{"tool": "still_nope"}"#])
        let result = await harness(JSONActionBackend(client: client), family: .qwen)
            .run(prompt: askPrompt, history: [], userMessage: "?", context: library.toolContext())
        #expect(result.outcome == .failed)
        #expect(client.requests.count == 2, "Exactly one repair attempt")
        #expect(result.transcript.errorMessage?.contains("couldn't be used") == true)
        #expect(result.transcript.entries.filter { if case .note = $0 { true } else { false } }.count == 2, "Both rejected replies are in the transcript")
    }
}

// MARK: - Profiles

@Suite("Agent prompt profiles")
struct AgentPromptProfileTests {
    @Test("Family detection from client type and model")
    func detection() {
        #expect(AgentModelFamily.detect(clientTypeName: "AnthropicClient", modelID: "claude-sonnet-5-5") == .claude)
        #expect(AgentModelFamily.detect(clientTypeName: "AppleFoundationClient", modelID: "apple-on-device") == .apple)
        #expect(AgentModelFamily.detect(clientTypeName: "MLXLocalClient", modelID: "mlx-community/Qwen3.5-4B-4bit") == .qwen)
        #expect(AgentModelFamily.detect(clientTypeName: "MLXLocalClient", modelID: "mlx-community/LFM3-1.7B-4bit") == .lfm)
        #expect(AgentModelFamily.detect(clientTypeName: "OpenAIClient", modelID: "gpt-5.2") == .openAICompatible)
        #expect(AgentModelFamily.detect(clientTypeName: "OllamaClient", modelID: "qwen3:4b") == .qwen)
        #expect(AgentModelFamily.detect(clientTypeName: "CodexCLIClient", modelID: "gpt-5-codex") == .cliAgent)
        #expect(AgentModelFamily.detect(clientTypeName: "GrokCLIClient", modelID: "grok-4") == .cliAgent)
        #expect(AgentModelFamily.detect(clientTypeName: "CLIChatClient", modelID: "gpt-5-codex") == .cliAgent)
        // "LLMClient" / "LocalClient" contain "cli" in lower case: not CLI agents.
        #expect(AgentModelFamily.detect(clientTypeName: "UnavailableLLMClient", modelID: "") == .qwen)
        #expect(AgentModelFamily.detect(clientTypeName: "AutomaticLocalClient", modelID: "automatic") == .qwen)
    }

    @Test("Backends: native tools where the client has them, JSON actions elsewhere")
    func backends() {
        func kind(_ client: any LLMClient, _ model: String) -> AgentBackendKind {
            AgentEndpoints.endpoint(client: client, model: model, providerName: "x", locality: .onDevice).backend.kind
        }
        #expect(kind(AnthropicClient(apiKey: "k"), "claude-sonnet-5-5") == .anthropicTools)
        #expect(kind(OpenAIClient(apiKey: "k"), "gpt-5.2") == .openAITools)
        #expect(kind(AppleFoundationClient(), AppleFoundationClient.modelID) == .appleTools)
        #expect(kind(AgentScriptedClient([]), "mlx-community/Qwen3.5-4B-4bit") == .jsonActions)
        #expect(kind(UnavailableLLMClient(.setupRequired("x")), "") == .jsonActions)
        // Subscription CLIs (Codex, Grok) run their own agents: JSON actions, no shell.
        #expect(kind(CLIChatClient(vendor: .codex), "gpt-5-codex") == .jsonActions)
    }

    @Test("Every profile stays under 800 tokens with the full tool list, and has no example content")
    @MainActor
    func budgets() {
        let tools = LidIATools.all(destinations: AgentDestinations(clickUp: true, notion: true, n8n: true)).specs
        for family in AgentModelFamily.allCases {
            for format in [AgentToolFormat.native, .jsonActions] {
                for task in [AgentTaskKind.ask, .voice, .comment] {
                    let prompt = AgentPromptProfiles.system(for: family, context: AgentPromptContext(task: task, toolFormat: format, tools: tools, maxSteps: 5, userName: "Alex"))
                    let tokens = TokenEstimate.estimate(prompt)
                    #expect(tokens < 800, "\(family) \(format) \(task): \(tokens) tokens")
                    for example in ["Northwind", "Acme", "e.g. \"", "For example"] {
                        #expect(!prompt.contains(example), "\(family) prompt contains example content: \(example)")
                    }
                    #expect(prompt.contains("search_meetings(") == (format == .jsonActions))
                }
            }
        }
        #expect(!AgentPromptProfiles.version.isEmpty)
    }
}

// MARK: - Anthropic tool use

@Suite("Anthropic tool use")
@MainActor
struct AnthropicToolUseTests {
    @Test("Streamed tool_use is rebuilt, thinking kept for replay")
    func parseToolUse() throws {
        let lines = [
            #"data: {"type":"message_start","message":{"id":"m"}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need the meeting."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me look."}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_meetings","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"North"}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"wind\"}"}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        var parser = AnthropicToolStreamParser()
        var streamed = ""
        var reasoning = ""
        for line in lines {
            switch try parser.consume(line: line) {
            case .text(let text): streamed += text
            case .reasoning(let text): reasoning += text
            case nil: break
            }
        }
        #expect(reasoning == "Need the meeting.")
        let turn = try parser.finish()
        #expect(streamed == "Let me look.")
        #expect(turn.text == "Let me look.")
        #expect(turn.toolCalls.count == 1)
        #expect(turn.toolCalls[0].id == "toolu_1")
        #expect(AgentJSON.object(turn.toolCalls[0].argumentsJSON)?["query"] as? String == "Northwind")
        #expect(turn.stopReason == "tool_use")
        let replay = try #require(AgentJSON.array(turn.nativeContentJSON ?? "") as? [[String: Any]])
        #expect(replay.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(replay[0]["signature"] as? String == "sig123")
    }

    @Test("Refusals and cut-off tool calls are errors")
    func refusals() throws {
        var refused = AnthropicToolStreamParser()
        _ = try refused.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        #expect(throws: LLMError.self) { try refused.finish() }

        var cut = AnthropicToolStreamParser()
        _ = try cut.consume(line: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"get_meeting","input":{}}}"#)
        _ = try cut.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"meeting_id\": \"ab"}}"#)
        _ = try cut.consume(line: #"data: {"type":"content_block_stop","index":0}"#)
        _ = try cut.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
        #expect(throws: LLMError.self) { try cut.finish() }
    }

    @Test("Request: tools, low effort, fallback; tool results grouped in one user message")
    func requestBody() throws {
        var assistant = AgentMessage.assistant("")
        assistant.toolCalls = [AgentToolCall(id: "a", name: "list_projects", argumentsJSON: "{}"), AgentToolCall(id: "b", name: "list_projects", argumentsJSON: "{}")]
        let thinking = AgentMessage(role: .assistant, text: "x", nativeContentJSON: #"[{"type":"thinking","thinking":"","signature":"s"},{"type":"tool_use","id":"c","name":"list_projects","input":{}}]"#)
        let request = AgentTurnRequest(
            system: "sys",
            messages: [
                .user("Projects?"), assistant,
                AgentMessage(role: .tool, text: "one", toolCallID: "a", toolName: "list_projects"),
                AgentMessage(role: .tool, text: "two", toolCallID: "b", toolName: "list_projects", isError: true),
                thinking,
                AgentMessage(role: .tool, text: "three", toolCallID: "c", toolName: "list_projects"),
            ],
            tools: [LidIATools.listProjects.spec],
            model: "claude-sonnet-5-5",
            effort: .low,
            onText: { _ in }
        )
        let body = AnthropicClient.toolRequestBody(request)
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect((body["thinking"] as? [String: String])?["display"] == "summarized")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["system"] as? String == "sys")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "list_projects")
        #expect((tools.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user", "assistant", "user"])
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.map { $0["tool_use_id"] as? String } == ["a", "b"])
        #expect(results[1]["is_error"] as? Bool == true)
        // Native content (thinking with its signature) replayed verbatim.
        let replayed = try #require(messages[3]["content"] as? [[String: Any]])
        #expect(replayed.first?["signature"] as? String == "s")
    }
}

// MARK: - OpenAI function calling

@Suite("OpenAI function calling")
@MainActor
struct OpenAIToolCallingTests {
    @Test("Parses tool_calls with string or object arguments")
    func parse() throws {
        let json = #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_meeting","arguments":"{\"meeting_id\":\"ab12cd34\"}"}},{"id":"c2","type":"function","function":{"name":"list_projects","arguments":{}}}]}}]}"#
        let turn = try OpenAIClient.parseToolResponse(Data(json.utf8))
        #expect(turn.toolCalls.map(\.name) == ["get_meeting", "list_projects"])
        #expect(AgentJSON.object(turn.toolCalls[0].argumentsJSON)?["meeting_id"] as? String == "ab12cd34")
        #expect(turn.toolCalls[1].argumentsJSON == "{}")
        #expect(turn.text.isEmpty)
    }

    @Test("Request carries tools and tool results; effort only for OpenAI reasoning models")
    func body() {
        var assistant = AgentMessage.assistant("")
        assistant.toolCalls = [AgentToolCall(id: "c1", name: "list_projects", argumentsJSON: "{}")]
        let request = AgentTurnRequest(
            system: "sys", messages: [.user("q"), assistant, AgentMessage(role: .tool, text: "r", toolCallID: "c1", toolName: "list_projects")],
            tools: [LidIATools.listProjects.spec], model: "gpt-5.2", effort: .low, onText: { _ in }
        )
        let body = OpenAIClient.toolRequestBody(request, isOpenAIProper: true)
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[3]["tool_call_id"] as? String == "c1")
        #expect((body["tools"] as? [[String: Any]])?.count == 1)
        #expect(body["reasoning_effort"] as? String == "low")
        #expect(OpenAIClient.toolRequestBody(request, isOpenAIProper: false)["reasoning_effort"] == nil)
    }
}

// MARK: - Apple Foundation Models

@Suite("Apple Foundation Models tools")
@MainActor
struct AppleFoundationToolTests {
    @Test("Every LidIA tool converts to a generation schema")
    func schemas() throws {
        for spec in LidIATools.all(destinations: AgentDestinations(clickUp: true, notion: true, n8n: true)).specs {
            _ = try AppleAgentTool.schema(for: spec)
        }
    }

    @Test("A native call reaches the harness's runner with JSON arguments")
    func callBridges() async throws {
        let received = Received()
        let tool = try AppleAgentTool(spec: LidIATools.searchMeetings.spec) { call in
            await received.set(call)
            return "2 meetings"
        }
        let output = try await tool.call(arguments: GeneratedContent(properties: ["query": "Northwind", "limit": 3]))
        #expect(output == "2 meetings")
        let call = try #require(await received.call)
        #expect(call.name == "search_meetings")
        guard case .success(let arguments) = LidIATools.searchMeetings.spec.validate(call.argumentsJSON) else {
            Issue.record("arguments from Apple must validate"); return
        }
        #expect(arguments.string("query") == "Northwind")
        #expect(arguments.integer("limit") == 3)
    }

    actor Received {
        var call: AgentToolCall?
        func set(_ call: AgentToolCall) { self.call = call }
    }
}

// MARK: - Tools

@Suite("LidIA agent tools")
@MainActor
struct LidIAToolTests {
    @Test("search_meetings by words, person and date; get_meeting by short id; filters")
    func readers() async throws {
        let library = try Library()
        let context = library.toolContext()
        func run(_ tool: AgentTool, _ json: String) async throws -> String {
            guard case .success(let arguments) = tool.spec.validate(json) else { throw AgentValidationError(tool: tool.name, problems: []) }
            return try await tool.handler(arguments, context).text
        }
        let byWord = try await run(LidIATools.searchMeetings, #"{"query": "what did we agree with northwind"}"#)
        #expect(byWord.contains("Northwind x Harborcloud"))
        #expect(!byWord.contains("Engineering - WBR"))
        let byPerson = try await run(LidIATools.searchMeetings, #"{"person": "Mateo"}"#)
        #expect(byPerson.contains("Northwind x Harborcloud"))
        let byDate = try await run(LidIATools.searchMeetings, #"{"from": "2026-10-25"}"#)
        #expect(byDate.contains("Engineering - WBR") && !byDate.contains("Northwind"))

        let id = LidIATools.shortID(library.northwind.id)
        let details = try await run(LidIATools.getMeeting, #"{"meeting_id": "[\#(id)]"}"#)
        #expect(details.contains("landing zone"))
        #expect(details.contains("Send the landing zone proposal"))
        #expect(details.contains("Mateo K"))

        let open = try await run(LidIATools.listActionItems, #"{"assignee": "alex"}"#)
        #expect(open.contains("Send the landing zone proposal"))
        let done = try await run(LidIATools.listActionItems, #"{"status": "done"}"#)
        #expect(done == "No matching action items.")

        let projects = try await run(LidIATools.listProjects, "{}")
        #expect(projects.contains("Northwind: 1 meeting"))
    }

    @Test("Spoken confirmation: yes, no, or a new request")
    func voiceReplies() {
        #expect(VoiceAgent.reply(to: "Yes please") == .yes)
        #expect(VoiceAgent.reply(to: "Sí, hazlo") == .yes)
        #expect(VoiceAgent.reply(to: "no, don't") == .no)
        #expect(VoiceAgent.reply(to: "What's on my calendar tomorrow afternoon with the Northwind team?") == .other)
    }
}
