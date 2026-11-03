#if DEBUG
import Foundation
import SwiftData

/// Deterministic agent runs for the chat snapshot shots: loading, thinking,
/// streaming with citations, approvals, action items, a table. Built on
/// meetings from the library COPY so titles and dates are real; excerpts and
/// answers are fixed text.
@MainActor
enum ChatSnapshotFixtures {
    /// Messages the meeting page's Ask shows on its next appearance.
    static var pendingMeetingAskMessages: [ChatBarMessage]?

    struct Refs {
        var recent: AgentMeetingRef
        var earlier: AgentMeetingRef
        var other: AgentMeetingRef
    }

    static let question = "What did we agree with Northwind about the AWS account structure?"

    static func refs(in context: ModelContext) -> Refs {
        let all = (try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let series = all.filter { $0.title.localizedCaseInsensitiveContains(SnapshotCast.project) }
        let other = all.first { $0.title.localizedCaseInsensitiveContains(SnapshotCast.otherCall) } ?? all.dropFirst(2).first
        let calendar = Calendar.current
        func fallback(_ title: String, daysAgo: Int) -> AgentMeetingRef {
            AgentMeetingRef(id: UUID(), title: title, date: calendar.date(byAdding: .day, value: -daysAgo, to: .now)!, excerpt: nil)
        }
        // Two meetings of the series on different days (the copy can hold
        // several recordings from one day).
        let first = series.first
        let second = first.flatMap { f in series.first { !calendar.isDate($0.date, inSameDayAs: f.date) } }
        var recent = first.map { LidIATools.ref($0, excerpt: nil) } ?? fallback("Northwind x Harborcloud - SaaS Platform on AWS", daysAgo: 6)
        var earlier = second.map { LidIATools.ref($0, excerpt: nil) } ?? fallback("Northwind x Harborcloud - SaaS Platform on AWS", daysAgo: 13)
        var third = other.map { LidIATools.ref($0, excerpt: nil) } ?? fallback("TAPR call [Pinecrest]", daysAgo: 4)
        recent.excerpt = "[12:04] Daniel: Let's go with separate prod and staging accounts under Organizations, and a shared-services account for CI and logs."
        earlier.excerpt = "[31:40] Mateo: The data team will want a sandbox, but let's park that until we have the landing zone."
        third.excerpt = "Reviewed the reliability pillar; backups exist but restores were never tested."
        return Refs(recent: recent, earlier: earlier, other: third)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    // MARK: Answers

    static func agreementAnswer(_ r: Refs) -> String {
        """
        You agreed on a **multi-account setup under AWS Organizations**, with production and staging kept apart from day one.

        - **Accounts:** separate prod and staging accounts, plus a shared-services account for CI and logging. Daniel confirmed this in \(r.recent.title) on \(day(r.recent.date)).
        - **Guardrails:** SCPs limit workloads to `eu-central-1` and `eu-west-1`; Felix owns the first draft.
        - **Still open:** whether the data team gets its own sandbox. It came up in \(r.earlier.title) on \(day(r.earlier.date)) and was parked.

        Next check-in is Monday, when you share the account plan.
        """
    }

    static func actionItemsAnswer(_ r: Refs) -> String {
        """
        Four items came out of \(r.recent.title) on \(day(r.recent.date)); three are still open.

        ### Action items
        - [ ] Share the AWS account plan with Northwind — Alex, due Thursday
        - [ ] Draft the SCP guardrails (Owner: Felix, due \(AgentDates.day(Calendar.current.date(byAdding: .day, value: 4, to: .now)!)))
        - [ ] Confirm whether the data team needs a sandbox — Daniel
        - [x] Send the kickoff recap — Alex
        """
    }

    static func tableAnswer(_ r: Refs) -> String {
        """
        The two Northwind meetings, side by side:

        | | \(day(r.earlier.date)) | \(day(r.recent.date)) |
        |---|---|---|
        | **Focus** | Kickoff and scope | Account structure |
        | **Decided** | Start from the landing zone | Separate prod and staging accounts |
        | **Open** | Who owns the budget | Data team sandbox |
        | **Next step** | Share requirements | Account plan by Thursday |

        The scope narrowed from the whole platform to the landing zone first [2][1].
        """
    }

    // MARK: Runs

    private static func transcript(question: String, answer: String, model: String, provider: String, locality: DataLocality, seconds: Double) -> AgentTranscript {
        var transcript = AgentTranscript(
            task: "ask", model: model, providerName: provider, locality: locality,
            backend: locality == .cloud ? .anthropicTools : .jsonActions,
            profileID: locality == .cloud ? "claude" : "qwen", profileVersion: AgentPromptProfiles.version,
            effort: .medium, maxSteps: 6, deadlineSeconds: 90,
            systemPrompt: "You are LidIA, the assistant in the user's meeting-notes app on their Mac.", tools: []
        )
        transcript.seconds = seconds
        transcript.messages = [AgentMessage(role: .user, text: question), AgentMessage(role: .assistant, text: answer)]
        return transcript
    }

    private static func step(_ id: String, _ tool: String, _ summary: String, startedAgo: TimeInterval) -> AgentRun.Step {
        AgentRun.Step(id: id, toolName: tool, summary: summary, argumentsJSON: "{}", status: .running, startedAt: Date(timeIntervalSinceNow: -startedAgo))
    }

    private static func cloudRun(question: String, seconds: TimeInterval) -> AgentRun {
        AgentRun(question: question, modelLabel: "claude-sonnet-4-5", providerName: "Anthropic", locality: .cloud, startedAt: Date(timeIntervalSinceNow: -seconds))
    }

    private static func localRun(question: String, seconds: TimeInterval) -> AgentRun {
        AgentRun(question: question, modelLabel: "Qwen 3.5 4B", providerName: "MLX", locality: .onDevice, startedAt: Date(timeIntervalSinceNow: -seconds))
    }

    /// Searched, then read two meetings.
    private static func addReadingSteps(_ run: AgentRun, _ r: Refs, finish: Bool = true) {
        run.stepStarted(step("1", "search_meetings", "Searched meetings: Northwind AWS accounts", startedAgo: 3.6))
        run.noteMeetings([r.recent, r.earlier, r.other], read: false)
        run.stepFinished(id: "1", status: .succeeded, summary: "Searched meetings: Northwind AWS accounts", resultCount: 6)
        run.stepStarted(step("2", "get_meeting", "Read “\(r.recent.title)”, \(AgentDates.day(r.recent.date))", startedAgo: 2.9))
        run.noteMeetings([r.recent], read: true)
        run.stepFinished(id: "2", status: .succeeded, summary: nil, resultCount: 1)
        run.stepStarted(step("3", "get_meeting", "Read “\(r.earlier.title)”, \(AgentDates.day(r.earlier.date))", startedAgo: 2.4))
        if finish {
            run.noteMeetings([r.earlier], read: true)
            run.stepFinished(id: "3", status: .succeeded, summary: nil, resultCount: 1)
        }
    }

    static func loading(_ r: Refs) -> AgentRun {
        let run = localRun(question: question, seconds: 1.0)
        run.stepStarted(step("1", "search_meetings", "Searched meetings: Northwind AWS accounts", startedAgo: 0.6))
        return run
    }

    static func streaming(_ r: Refs) -> AgentRun {
        let run = localRun(question: question, seconds: 4.0)
        addReadingSteps(run, r)
        let full = agreementAnswer(r)
        let cut = full.range(of: "- **Still open:**")?.lowerBound ?? full.endIndex
        run.appendAnswer(String(full[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
        return run
    }

    static func finishedAgreement(_ r: Refs, local: Bool = false) -> ChatBarMessage {
        let run = local ? localRun(question: question, seconds: 6.2) : cloudRun(question: question, seconds: 4.3)
        addReadingSteps(run, r)
        if !local {
            run.appendReasoning("The user wants the agreed account structure. Search found six Northwind meetings; the two most recent discuss AWS accounts, so I read both. The latest has the decision and who confirmed it; the earlier one has the open sandbox question. I'll cite both and keep it to the decision, guardrails and what's open.")
        }
        let answer = agreementAnswer(r)
        let sources = AgentRunPresentation.sources(read: [r.recent, r.earlier], seen: [], answer: answer)
        let followUps = AgentRunPresentation.followUps(question: question, toolsUsed: ["search_meetings", "get_meeting"], sources: sources, hasApprovals: false)
        let transcript = transcript(question: question, answer: answer, model: run.modelLabel, provider: run.providerName, locality: run.locality, seconds: run.elapsed)
        run.finish(answer: answer, sources: sources, followUps: followUps, approvals: [], transcript: transcript)
        return message(answer, run: run)
    }

    static func approvals(_ r: Refs) -> ChatBarMessage {
        let q = "Send Northwind the account plan and set up the follow-ups"
        let run = cloudRun(question: q, seconds: 5.1)
        addReadingSteps(run, r)
        run.stepStarted(step("4", "propose_dispatch", "Drafted a ClickUp proposal", startedAgo: 1.1))
        run.stepFinished(id: "4", status: .succeeded, summary: nil, resultCount: nil)
        run.stepStarted(step("5", "create_action_item", "Prepared a new action item: Draft the SCP guardrails", startedAgo: 0.8))
        run.stepFinished(id: "5", status: .awaitingApproval, summary: nil, resultCount: nil)
        let answer = "I drafted three things from \(r.recent.title) on \(day(r.recent.date)). Nothing is sent or created until you confirm each one."
        let built = AgentRunPresentation.approvals(
            pending: [AgentPendingAction(
                toolName: "create_action_item",
                argumentsJSON: #"{"title":"Draft the SCP guardrails","assignee":"Felix","due":"Friday"}"#,
                summary: "Create the action item “Draft the SCP guardrails” for Felix"
            )],
            proposals: [AgentDispatchProposal(
                destination: "clickup",
                title: "Share the AWS account plan with Northwind",
                body: "Prod, staging and shared-services accounts under AWS Organizations; SCP guardrails for eu-central-1 and eu-west-1. Review together on Monday.",
                actionItemID: UUID()
            )],
            clarification: AgentClarification(
                question: "Which recap should go to Daniel?",
                options: ["A short summary of the decisions", "The full recap with next steps", "Only the account plan"]
            )
        )
        // The question first, then the suggestion, then the change.
        let ordered = built.filter { $0.kind == .clarification } + built.filter { if case .dispatch = $0.kind { true } else { false } } + built.filter { if case .change = $0.kind { true } else { false } }
        let sources = AgentRunPresentation.sources(read: [r.recent, r.earlier], seen: [], answer: answer)
        let transcript = transcript(question: q, answer: answer, model: run.modelLabel, provider: run.providerName, locality: run.locality, seconds: run.elapsed)
        run.finish(answer: answer, sources: sources, followUps: [], approvals: ordered, transcript: transcript)
        run.onApproval = { _, _ in .resolved("Done") }
        return message(answer, run: run)
    }

    static func actionItems(_ r: Refs) -> ChatBarMessage {
        let q = "What's still open from the last Northwind meeting?"
        let run = localRun(question: q, seconds: 3.4)
        run.stepStarted(step("1", "list_action_items", "Listed action items: open, project Northwind", startedAgo: 2.0))
        run.stepFinished(id: "1", status: .succeeded, summary: nil, resultCount: 4)
        run.stepStarted(step("2", "get_meeting", "Read “\(r.recent.title)”, \(AgentDates.day(r.recent.date))", startedAgo: 1.4))
        run.noteMeetings([r.recent], read: true)
        run.stepFinished(id: "2", status: .succeeded, summary: nil, resultCount: 1)
        let answer = actionItemsAnswer(r)
        let sources = [r.recent]
        let followUps = AgentRunPresentation.followUps(question: q, toolsUsed: ["list_action_items", "get_meeting"], sources: sources, hasApprovals: false)
        run.finish(answer: answer, sources: sources, followUps: followUps, approvals: [],
                   transcript: transcript(question: q, answer: answer, model: run.modelLabel, provider: run.providerName, locality: run.locality, seconds: run.elapsed))
        return message(answer, run: run)
    }

    static func table(_ r: Refs) -> ChatBarMessage {
        let q = "Compare the last two Northwind meetings"
        let run = cloudRun(question: q, seconds: 5.8)
        addReadingSteps(run, r)
        let answer = tableAnswer(r)
        let sources = [r.recent, r.earlier]
        run.finish(answer: answer, sources: sources, followUps: ["Which of these decisions are still open?", "Draft a follow-up email for Northwind"], approvals: [],
                   transcript: transcript(question: q, answer: answer, model: run.modelLabel, provider: run.providerName, locality: run.locality, seconds: run.elapsed))
        return message(answer, run: run)
    }

    /// The meeting page's Ask: one question about this meeting.
    static func meetingAsk(meeting: Meeting) -> [ChatBarMessage] {
        let q = "What did Daniel commit to?"
        var ref = LidIATools.ref(meeting, excerpt: "[12:04] Daniel: I'll confirm the data team's sandbox needs by Friday and review the SCPs with Felix.")
        ref.title = meeting.title
        let run = localRun(question: q, seconds: 2.8)
        run.stepStarted(step("1", "get_meeting", "Read “\(meeting.title)”, \(AgentDates.day(meeting.date))", startedAgo: 2.0))
        run.noteMeetings([ref], read: true)
        run.stepFinished(id: "1", status: .succeeded, summary: nil, resultCount: 1)
        let answer = """
        Daniel took two things in \(meeting.title):

        1. **Confirm the data team's sandbox needs** by Friday.
        2. **Review the SCP guardrails** with Felix before Monday's check-in.
        """
        run.finish(answer: answer, sources: [ref], followUps: ["Draft a follow-up email to Daniel", "What did Felix commit to?"], approvals: [],
                   transcript: transcript(question: q, answer: answer, model: run.modelLabel, provider: run.providerName, locality: run.locality, seconds: run.elapsed))
        return [ChatBarMessage(role: .user, text: q), message(answer, run: run)]
    }

    private static func message(_ answer: String, run: AgentRun) -> ChatBarMessage {
        var message = ChatBarMessage(
            role: .assistant, text: answer,
            sourceMeetings: ChatBarViewModel.sourceLabels(run.sources),
            modelLabel: "\(run.modelLabel) · \(run.locality.label)"
        )
        message.agentRun = run
        message.agentTranscript = run.transcript
        return message
    }
}
#endif
