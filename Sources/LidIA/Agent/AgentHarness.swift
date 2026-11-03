import Foundation
import os

/// A bounded agent loop over any model: system prompt, tools, step limit,
/// deadline, cancellation, streaming text, and a transcript of exactly what
/// was sent. Mutating tools never run inside the loop; they come back as
/// pending actions that run only through `confirm(_:…)`.
@MainActor
final class AgentHarness {
    struct Configuration: Sendable {
        /// Model calls per run, the final answer included. The last call is
        /// made without tools so the model has to answer.
        var maxSteps = 5
        /// Overall time for the run.
        var deadline: TimeInterval = 120
        /// Never above medium.
        var effort: AgentEffort = .low
        /// Longest tool result passed to the model, in characters.
        var toolResultLimit = 6_000
        /// Provider-side tools (Claude web search). Only set when the cloud
        /// is allowed for the task.
        var serverTools: [AgentServerTool] = []

        static func standard(for family: AgentModelFamily, effort: AgentEffort = .low, locality: DataLocality) -> Configuration {
            Configuration(
                maxSteps: effort == .medium ? 7 : 5,
                deadline: locality == .cloud ? 90 : 150,
                effort: effort,
                toolResultLimit: family == .apple ? 1_500 : (family == .qwen || family == .lfm ? 4_000 : 8_000)
            )
        }
    }

    /// Streamed to the UI, in order.
    enum Event: Sendable, Equatable {
        case text(String)
        /// Clear the streamed text: it wasn't the answer (it preceded a tool call).
        case resetText
        /// What the agent is doing ("Searching meetings…").
        case status(String)
        /// Model-provided reasoning summary text (Claude's summarized thinking).
        case reasoning(String)
    }

    struct Result: Sendable {
        var answer: String
        var transcript: AgentTranscript
        var pendingActions: [AgentPendingAction]
        var proposals: [AgentDispatchProposal]
        /// Structured sources: meetings read, else those the answer names.
        var sources: [AgentMeetingRef]
        /// Every meeting the tools returned.
        var meetingsSeen: [AgentMeetingRef]
        var clarification: AgentClarification?
        var approvals: [AgentApproval]
        var followUps: [String]
        /// Pages the provider's web search returned during the run.
        var webResults: [AgentWebResult] = []
        /// Titles of meetings the tools returned (candidates for source chips).
        var meetingTitles: [String] { meetingsSeen.map(\.title) }
        var outcome: AgentTranscript.Outcome { transcript.outcome }
    }

    /// Which model and how to reach it.
    struct Endpoint: Sendable {
        var backend: any AgentBackend
        var family: AgentModelFamily
        var model: String
        /// Shown in the UI ("Qwen 3.5 4B", "claude-sonnet-5-5").
        var modelLabel: String
        var providerName: String
        var locality: DataLocality
    }

    private static let logger = Logger(subsystem: "io.lidia.app", category: "AgentHarness")

    let endpoint: Endpoint
    let tools: AgentToolRegistry
    let configuration: Configuration

    init(endpoint: Endpoint, tools: AgentToolRegistry, configuration: Configuration) {
        self.endpoint = endpoint
        self.tools = tools
        var configuration = configuration
        configuration.maxSteps = max(1, configuration.maxSteps)
        self.configuration = configuration
    }

    /// The system prompt this harness sends for `prompt`.
    func systemPrompt(_ prompt: AgentPromptContext) -> String {
        var context = prompt
        context.tools = tools.specs
        context.toolFormat = endpoint.backend.kind == .jsonActions ? .jsonActions : .native
        context.maxSteps = configuration.maxSteps
        return AgentPromptProfiles.system(for: endpoint.family, context: context)
    }

    // MARK: - Run

    /// A live run object for the UI, labelled with this endpoint.
    func makeRun(question: String) -> AgentRun {
        AgentRun(question: question, modelLabel: endpoint.modelLabel, providerName: endpoint.providerName, locality: endpoint.locality)
    }

    /// Runs one user turn. Never throws: failures end the run with an outcome
    /// and a short message as the answer, and the transcript says what happened.
    /// `live`, when given, is updated as the run progresses and finished at the end.
    func run(
        prompt: AgentPromptContext,
        history: [AgentMessage],
        userMessage: String,
        context: AgentToolContext,
        live: AgentRun? = nil,
        onEvent: @escaping @MainActor (Event) -> Void = { _ in }
    ) async -> Result {
        let system = systemPrompt(prompt)
        let state = RunState(transcript: AgentTranscript(
            task: prompt.task.rawValue,
            model: endpoint.modelLabel,
            providerName: endpoint.providerName,
            locality: endpoint.locality,
            backend: endpoint.backend.kind,
            profileID: AgentPromptProfiles.profileID(endpoint.family),
            profileVersion: AgentPromptProfiles.version,
            effort: configuration.effort,
            maxSteps: configuration.maxSteps,
            deadlineSeconds: configuration.deadline,
            systemPrompt: system,
            tools: tools.tools.map {
                AgentTranscript.ToolDefinition(name: $0.name, description: $0.spec.description, schemaJSON: $0.spec.jsonSchemaText, effect: $0.effect)
            }
        ))
        state.transcript.messages = history + [.user(userMessage)]
        state.live = live

        // One ordered channel for everything the UI sees.
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let pump = Task { @MainActor in
            for await event in events {
                switch event {
                case .text(let text): live?.appendAnswer(text)
                case .resetText: live?.resetAnswer()
                case .reasoning(let text): live?.appendReasoning(text)
                case .status: break
                }
                onEvent(event)
            }
        }

        let started = Date()
        do {
            try await withDeadline(seconds: configuration.deadline, step: "answer") { [self] in
                try await self.loop(state: state, system: system, context: context, events: continuation)
            }
        } catch is PipelineTimeoutError {
            state.transcript.outcome = .deadline
            state.transcript.errorMessage = "Stopped after \(Int(configuration.deadline)) seconds."
            if state.answer.isEmpty { state.answer = "That took too long, so I stopped. Try a narrower question or a faster model." }
        } catch is CancellationError {
            state.transcript.outcome = .cancelled
        } catch let AgentBackendError.invalidAction(problem, outputs) {
            state.transcript.outcome = .failed
            state.transcript.errorMessage = AgentBackendError.invalidAction(problem).localizedDescription
            for (index, output) in outputs.enumerated() {
                state.transcript.entries.append(.note("Rejected reply \(index + 1): \(output)"))
            }
            state.answer = "Sorry, I couldn't work that out. Try asking another way, or pick a larger model in Settings → AI."
        } catch {
            if Task.isCancelled {
                state.transcript.outcome = .cancelled
            } else {
                state.transcript.outcome = .failed
                state.transcript.errorMessage = error.localizedDescription
                state.answer = "[Error: \(error.localizedDescription)]"
                Self.logger.error("Agent run failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        continuation.finish()
        await pump.value
        state.transcript.seconds = Date().timeIntervalSince(started)

        let sources = AgentRunPresentation.sources(read: state.meetingsRead, seen: state.meetingsSeen, answer: state.answer)
        // Kanban turns proposals into its own sheet; elsewhere they are approvals.
        let approvals = AgentRunPresentation.approvals(
            pending: state.pending,
            proposals: prompt.task == .comment ? [] : state.proposals,
            clarification: state.clarification
        )
        let followUps = state.clarification == nil && state.transcript.outcome == .answered
            ? AgentRunPresentation.followUps(question: userMessage, toolsUsed: state.transcript.toolRuns.map(\.call.name), sources: sources, hasApprovals: !approvals.isEmpty)
            : []
        live?.finish(answer: state.answer, sources: sources, followUps: followUps, approvals: approvals, transcript: state.transcript)

        return Result(
            answer: state.answer,
            transcript: state.transcript,
            pendingActions: state.pending,
            proposals: state.proposals,
            sources: sources,
            meetingsSeen: state.meetingsSeen,
            clarification: state.clarification,
            approvals: approvals,
            followUps: followUps,
            webResults: state.webResults
        )
    }

    private func loop(state: RunState, system: String, context: AgentToolContext, events: AsyncStream<Event>.Continuation) async throws {
        let specs = tools.specs
        for step in 1...configuration.maxSteps {
            try Task.checkCancellation()
            let offerTools = step < configuration.maxSteps && !specs.isEmpty
            let sent = state.transcript.messages.count
            var native: AgentNativeToolRunner?
            if endpoint.backend.kind == .appleTools, offerTools {
                native = { @Sendable [weak self] (call: AgentToolCall) async -> String in
                    guard let self else { return "Cancelled." }
                    return await self.runNativeTool(call, step: step, state: state, context: context, events: events)
                }
            }
            let request = AgentTurnRequest(
                system: system,
                messages: state.transcript.messages,
                tools: offerTools ? specs : [],
                model: endpoint.model,
                effort: configuration.effort,
                onText: { events.yield(.text($0)) },
                runTool: native,
                onReasoning: { events.yield(.reasoning($0)) },
                serverTools: offerTools ? configuration.serverTools : []
            )
            let callStart = Date()
            let response = try await endpoint.backend.turn(request)
            try Task.checkCancellation()

            if response.retractStreamedText { events.yield(.resetText) }
            if let problem = response.repairProblem {
                state.transcript.entries.append(.repair(step: step, problem: problem, rejectedOutput: response.rejectedOutput ?? ""))
            }
            state.transcript.entries.append(.modelCall(.init(
                step: step,
                sentMessageCount: sent,
                toolsOffered: offerTools,
                outputText: response.text,
                toolCalls: response.toolCalls,
                seconds: Date().timeIntervalSince(callStart),
                stopReason: response.stopReason
            )))
            var assistant = AgentMessage.assistant(response.text)
            assistant.toolCalls = response.toolCalls
            assistant.nativeContentJSON = response.nativeContentJSON
            state.transcript.messages.append(assistant)
            for result in response.webResults where !state.webResults.contains(result) { state.webResults.append(result) }
            // The provider paused a long server-tool turn: let it continue.
            if response.stopReason == "pause_turn", response.toolCalls.isEmpty, step < configuration.maxSteps { continue }

            guard !response.toolCalls.isEmpty else {
                let answer = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                state.answer = answer.isEmpty ? "I couldn't find an answer to that." : answer
                state.transcript.outcome = .answered
                return
            }
            guard offerTools else {
                // A native backend called a tool it wasn't offered on the last step.
                state.transcript.outcome = .stepLimit
                state.answer = response.text.isEmpty ? "I ran out of steps before finding an answer. Try a more specific question." : response.text
                return
            }
            events.yield(.resetText)
            for call in response.toolCalls {
                events.yield(.status(Self.statusText(for: call.name)))
                let message = await execute(call, step: step, state: state, context: context)
                state.transcript.messages.append(message)
            }
            if let clarification = state.clarification {
                // The agent asked the user: stop and wait for their reply.
                state.answer = clarification.question
                state.transcript.outcome = .answered
                return
            }
        }
        state.transcript.outcome = .stepLimit
        if state.answer.isEmpty { state.answer = "I ran out of steps before finding an answer. Try a more specific question." }
    }

    /// Apple's session calls tools itself; budget them like steps.
    private func runNativeTool(_ call: AgentToolCall, step: Int, state: RunState, context: AgentToolContext, events: AsyncStream<Event>.Continuation) async -> String {
        state.nativeToolCalls += 1
        if state.nativeToolCalls > configuration.maxSteps - 1 {
            let text = "No more tool calls. Answer now with what you have."
            state.transcript.entries.append(.toolRun(.init(step: step, call: call, status: .skipped, result: text, seconds: 0)))
            return text
        }
        events.yield(.resetText)
        events.yield(.status(Self.statusText(for: call.name)))
        let message = await execute(call, step: step, state: state, context: context)
        var assistant = AgentMessage.assistant("")
        assistant.toolCalls = [call]
        state.transcript.messages.append(assistant)
        state.transcript.messages.append(message)
        return message.text
    }

    /// Validates, gates and runs one call; records it; returns the tool message.
    private func execute(_ call: AgentToolCall, step: Int, state: RunState, context: AgentToolContext) async -> AgentMessage {
        let started = Date()
        let stepID = "\(step)-\(call.id)"
        let parsed: AgentArguments? = if case .success(let valid) = tools[call.name]?.spec.validate(call.argumentsJSON) { valid } else { nil }
        state.live?.stepStarted(.init(
            id: stepID, toolName: call.name,
            summary: AgentRunPresentation.stepSummary(tool: call.name, arguments: parsed, output: nil),
            argumentsJSON: call.argumentsJSON, status: .running, startedAt: started
        ))
        func finish(_ status: AgentTranscript.ToolRun.Status, _ text: String, error: Bool, output: AgentToolOutput? = nil) -> AgentMessage {
            let limited = text.agentTruncated(configuration.toolResultLimit)
            state.transcript.entries.append(.toolRun(.init(step: step, call: call, status: status, result: limited, seconds: Date().timeIntervalSince(started))))
            let liveStatus: AgentRun.Step.Status = status == .executed ? .succeeded : (status == .awaitingConfirmation ? .awaitingApproval : .failed)
            state.live?.stepFinished(
                id: stepID, status: liveStatus,
                summary: output.map { AgentRunPresentation.stepSummary(tool: call.name, arguments: parsed, output: $0) },
                resultCount: output?.resultCount
            )
            if let output { state.live?.noteMeetings(output.meetings, read: call.name == "get_meeting") }
            return AgentMessage(role: .tool, text: limited, toolCallID: call.id, toolName: call.name, isError: error)
        }

        guard let tool = tools[call.name] else {
            return finish(.unknownTool, "Unknown tool \"\(call.name)\". Available: \(tools.specs.map(\.name).joined(separator: ", ")).", error: true)
        }
        let arguments: AgentArguments
        switch tool.spec.validate(call.argumentsJSON) {
        case .failure(let error):
            return finish(.invalidArguments, error.localizedDescription, error: true)
        case .success(let valid):
            arguments = valid
        }

        switch tool.effect {
        case .mutating:
            let summary = tool.describe?(arguments, context) ?? "\(tool.name) \(call.argumentsJSON)"
            state.pending.append(AgentPendingAction(toolName: tool.name, argumentsJSON: call.argumentsJSON, summary: summary))
            return finish(.awaitingConfirmation, "Prepared, not done yet: \(summary). It happens only when the user confirms it in the app.", error: false)
        case .readOnly, .proposal:
            do {
                let output = try await tool.handler(arguments, context)
                if let proposal = output.proposal { state.proposals.append(proposal) }
                if let clarification = output.clarification { state.clarification = clarification }
                for ref in output.meetings where !state.meetingsSeen.contains(where: { $0.id == ref.id }) { state.meetingsSeen.append(ref) }
                if tool.name == "get_meeting" { state.meetingsRead += output.meetings }
                return finish(.executed, output.text, error: false, output: output)
            } catch {
                return finish(.failed, "The tool failed: \(error.localizedDescription)", error: true)
            }
        }
    }

    static func statusText(for tool: String) -> String {
        switch tool {
        case "search_meetings": "Searching meetings…"
        case "get_meeting": "Reading the meeting…"
        case "list_action_items": "Checking action items…"
        case "list_projects": "Looking at projects…"
        case "create_action_item", "update_action_item_status": "Preparing a change for you to confirm…"
        case "propose_dispatch": "Drafting a proposal…"
        default: "Working…"
        }
    }

    // MARK: - Confirmation

    /// Runs a pending action. Only UI code calls this, after the user
    /// confirms; the model has no way to reach it.
    static func confirm(_ action: AgentPendingAction, tools: AgentToolRegistry, context: AgentToolContext) async -> AgentPendingAction {
        var action = action
        guard action.state == .pending else { return action }
        guard let tool = tools[action.toolName], tool.effect == .mutating else {
            action.state = .failed
            action.resultMessage = "This action isn't available."
            return action
        }
        switch tool.spec.validate(action.argumentsJSON) {
        case .failure(let error):
            action.state = .failed
            action.resultMessage = error.localizedDescription
        case .success(let arguments):
            do {
                let output = try await tool.handler(arguments, context)
                action.state = .confirmed
                action.resultMessage = output.text
            } catch {
                action.state = .failed
                action.resultMessage = error.localizedDescription
            }
        }
        return action
    }

    // MARK: - State

    @MainActor
    private final class RunState {
        var transcript: AgentTranscript
        var answer = ""
        var pending: [AgentPendingAction] = []
        var proposals: [AgentDispatchProposal] = []
        var meetingsSeen: [AgentMeetingRef] = []
        var meetingsRead: [AgentMeetingRef] = []
        var clarification: AgentClarification?
        var live: AgentRun?
        var nativeToolCalls = 0
        var webResults: [AgentWebResult] = []

        init(transcript: AgentTranscript) { self.transcript = transcript }
    }
}
