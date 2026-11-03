import Foundation
import Testing
@testable import LidIA

@Suite("Chat presentation")
struct ChatPresentationTests {
    private static func day(_ text: String, hour: Int = 10) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let base = AgentDates.parse(text)!
        return calendar.date(byAdding: .hour, value: hour, to: base)!
    }

    private static let northwind = AgentMeetingRef(id: UUID(), title: "Northwind x Harborcloud", date: day("2026-10-28"), excerpt: "… [12:04] Daniel: we go with separate accounts …")
    private static let northwindEarlier = AgentMeetingRef(id: UUID(), title: "Northwind x Harborcloud", date: day("2026-10-21"), excerpt: nil)
    private static let tapr = AgentMeetingRef(id: UUID(), title: "TAPR call [Pinecrest]", date: day("2026-10-30"), excerpt: "Reviewed the reliability pillar")

    // MARK: Model labels

    @Test("Raw model IDs become readable names")
    func prettyModelNames() {
        #expect(ChatModelLabel.pretty("mlx-community/gemma-3-4b-it-4bit") == "Gemma 3 4B")
        #expect(ChatModelLabel.pretty("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
        #expect(ChatModelLabel.pretty("qwen3:4b") == "Qwen 3 4B")
        #expect(ChatModelLabel.pretty("gpt-4o-mini") == "GPT-4o mini")
        #expect(ChatModelLabel.pretty("Qwen 3.5 4B") == "Qwen 3.5 4B")
        #expect(ChatModelLabel.pretty("Apple Intelligence (on-device)") == "Apple Intelligence")
        #expect(!ChatModelLabel.pretty("mlx-community/Qwen3-4B-Instruct-2507-4bit").contains("/"))
    }

    @Test("One line per answer: model and where it ran")
    func modelLine() {
        #expect(ChatModelLabel.line(model: "claude-sonnet-4-5", locality: .cloud, providerName: "Anthropic") == "Claude Sonnet 4.5 · Anthropic")
        #expect(ChatModelLabel.line(stored: "mlx-community/gemma-3-4b-it-4bit · On this Mac") == "Gemma 3 4B · On this Mac")
        #expect(ChatModelLabel.line(stored: "Anthropic: claude-sonnet-4-5 · Cloud provider, your key") == "Claude Sonnet 4.5 · Anthropic")
    }

    // MARK: Sources

    @Test("Sources dedupe by ID and by same meeting on the same day, keeping dates apart")
    func sourceDedupe() {
        var copy = Self.northwind
        copy.excerpt = nil
        var sameDayRecording = AgentMeetingRef(id: UUID(), title: "northwind x harborcloud", date: Self.day("2026-10-28", hour: 11), excerpt: nil)
        sameDayRecording.excerpt = "other"
        let result = ChatSources.dedupe([copy, Self.northwind, sameDayRecording, Self.northwindEarlier, Self.tapr])
        #expect(result.map(\.id) == [Self.northwind.id, Self.northwindEarlier.id, Self.tapr.id])
        // The first card keeps an excerpt found later.
        #expect(result[0].excerpt == Self.northwind.excerpt)
    }

    @Test("A transcript timestamp in an excerpt links the citation")
    func excerptTimestamp() {
        #expect(ChatSources.timestamp(in: Self.northwind.excerpt) == 724)
        #expect(ChatSources.timestamp(in: "[1:02:03] Them: hi") == 3723)
        #expect(ChatSources.timestamp(in: "no stamp") == nil)
        #expect(ChatSources.cleanExcerpt("… hello there …") == "hello there")
        let now = Self.day("2026-11-03")
        #expect(ChatSources.prettifyDates("Action items on 2026-11-02?", now: now).contains("Nov"))
        #expect(!ChatSources.prettifyDates("from 2026-10-28", now: now).contains("2026"))
    }

    // MARK: Citations

    @Test("Short IDs match the ones the tools print") @MainActor
    func shortIDsMatchTools() {
        let id = UUID()
        #expect(ChatSources.shortID(id) == LidIATools.shortID(id))
    }

    @Test("Explicit markers and short IDs become citation links")
    func explicitCitations() {
        let sources = [Self.northwind, Self.tapr]
        let shortID = ChatSources.shortID(Self.tapr.id)
        let text = "Separate accounts were agreed [1]. The review is pending [\(shortID)]. See also [7] and [deadbeef]."
        let result = ChatCitations.link(text, sources: sources)
        #expect(result.markdown.contains("[1](lidia-cite://1)"))
        #expect(result.markdown.contains("[2](lidia-cite://2)"))
        #expect(!result.markdown.contains(shortID))
        #expect(!result.markdown.contains("deadbeef"))
        // Out-of-range numbers stay as written.
        #expect(result.markdown.contains("[7]"))
        #expect(result.cited == [1, 2])
    }

    @Test("A source named in the answer gets a citation at the end of the sentence")
    func implicitCitations() {
        let text = "In TAPR call [Pinecrest] on 30 Oct we reviewed reliability. Nothing else."
        let result = ChatCitations.link(text, sources: [Self.northwind, Self.tapr])
        #expect(result.markdown == "In TAPR call [Pinecrest] on 30 Oct we reviewed reliability [2](lidia-cite://2). Nothing else.")
        #expect(result.cited == [2])
    }

    @Test("Recurring titles cite the meeting whose date is on the line")
    func recurringTitles() {
        let text = "- Northwind x Harborcloud (2026-10-21): kickoff\n- Northwind x Harborcloud (Oct 28): accounts agreed"
        let result = ChatCitations.link(text, sources: [Self.northwind, Self.northwindEarlier])
        let lines = result.markdown.components(separatedBy: "\n")
        #expect(lines[0].hasSuffix("[2](lidia-cite://2)"))
        #expect(lines[1].hasSuffix("[1](lidia-cite://1)"))
        #expect(result.cited == [2, 1])
    }

    @Test("Citations never go inside code blocks, and adjacent ones join")
    func citationsSkipCode() {
        let text = "```\nNorthwind x Harborcloud\n```\nNorthwind x Harborcloud and TAPR call [Pinecrest] both happened."
        let result = ChatCitations.link(text, sources: [Self.northwind, Self.tapr])
        let lines = result.markdown.components(separatedBy: "\n")
        #expect(lines[1] == "Northwind x Harborcloud")
        #expect(lines[3].contains("happened [1](lidia-cite://1)[2](lidia-cite://2)."))
        #expect(ChatCitations.number(from: ChatCitations.url(3)) == 3)
        // Table rows never get a citation column.
        let table = ChatCitations.link("| Topic | 28 Oct |\n|---|---|\n| Accounts | Northwind x Harborcloud |", sources: [Self.northwind])
        #expect(!table.markdown.contains("lidia-cite"))
    }

    // MARK: Mentions and commands

    @Test("The @ or / being typed is found, and completing it inserts the label")
    func mentionTrigger() {
        let trigger = ChatMentions.activeTrigger(in: "What did @North")
        #expect(trigger?.symbol == "@")
        #expect(trigger?.query == "North")
        #expect(ChatMentions.activeTrigger(in: "email me@work") == nil)
        #expect(ChatMentions.activeTrigger(in: "/sum")?.query == "sum")
        #expect(ChatMentions.activeTrigger(in: "and/or") == nil)
        #expect(ChatMentions.activeTrigger(in: "hello /sum") == nil)
        let completed = ChatMentions.complete("What did @North", trigger: trigger!, with: "Northwind x Harborcloud")
        #expect(completed == "What did @Northwind x Harborcloud ")
    }

    @Test("Mentions round-trip through the stored text and scope the agent")
    func mentionEncoding() {
        let meetingID = UUID()
        let meeting = ChatMention(kind: .meeting, key: meetingID.uuidString, label: "Northwind x Harborcloud [AWS]", date: Self.day("2026-10-28"))
        let person = ChatMention(kind: .person, key: "Daniel", label: "Daniel")
        let stored = ChatMentions.encode("What did @Daniel say in @Northwind x Harborcloud [AWS]?", mentions: [meeting, person])
        #expect(stored.contains("lidia-mention://meeting/"))
        let (plain, mentions) = ChatMentions.decode(stored)
        #expect(plain == "What did Daniel say in Northwind x Harborcloud [AWS]?")
        #expect(mentions.count == 2)
        #expect(mentions.first { $0.kind == .meeting }?.meetingID == meetingID)
        #expect(mentions.first { $0.kind == .meeting }.flatMap(\.date).map(AgentDates.day) == "2026-10-28")
        let note = ChatMentions.scopeNote(mentions) ?? ""
        #expect(note.contains("[\(ChatSources.shortID(meetingID))]"))
        #expect(note.contains("person Daniel"))
    }

    @Test("Mention candidates rank prefix matches first")
    func mentionFilter() {
        let candidates = [
            ChatMention(kind: .meeting, key: "1", label: "Weekly sync with Northwind"),
            ChatMention(kind: .project, key: "Northwind", label: "Northwind"),
            ChatMention(kind: .person, key: "Greta", label: "Greta"),
        ]
        #expect(ChatMentions.filter(candidates, query: "north").map(\.label) == ["Northwind", "Weekly sync with Northwind"])
    }

    @Test("Slash commands parse and expand into prompts")
    func slashCommands() {
        let parsed = ChatCommand.parse("/summarize Northwind kickoff")
        #expect(parsed?.command == .summarize)
        #expect(parsed?.argument == "Northwind kickoff")
        #expect(ChatCommand.parse("/follow-up")?.command == .followUp)
        #expect(ChatCommand.parse("/followup")?.command == .followUp)
        #expect(ChatCommand.parse("/nope") == nil)
        #expect(ChatCommand.parse("summarize") == nil)
        #expect(ChatCommand.prep.prompt(argument: "").contains("my next meeting"))
        #expect(ChatCommand.matching("f") == [.followUp])
    }

    // MARK: Starters and steps

    @Test("Starters come from the next meeting, the latest one and open items")
    func starters() {
        let now = Self.day("2026-11-03", hour: 9)
        let starters = ChatStarters.make(
            next: .init(title: "TAPR call [Pinecrest]", date: Self.day("2026-11-04", hour: 15)),
            latest: .init(title: "Northwind x Harborcloud", date: Self.day("2026-11-02")),
            openItems: 7, overdueItems: 2, now: now
        )
        #expect(starters.count == 4)
        #expect(starters[0].title == "Prep for “TAPR call [Pinecrest]”")
        #expect(starters[0].subtitle?.hasPrefix("Tomorrow") == true)
        #expect(starters[1].subtitle == "Yesterday")
        #expect(starters[2].title == "Review 7 open action items")
        #expect(starters[2].subtitle == "2 overdue")
        let empty = ChatStarters.make(next: nil, latest: nil, openItems: 0, overdueItems: 0, now: now)
        #expect(empty.count == 2)
    }

    @Test("Meeting starters name a participant and the meeting's open items")
    func meetingStarters() {
        let starters = ChatStarters.forMeeting(people: ["Daniel Reyes"], openItems: 3)
        #expect(starters.map(\.title) == ["What did we decide?", "Review 3 action items", "What did Daniel commit to?", "Draft a follow-up email"])
        #expect(ChatStarters.forMeeting(people: [], openItems: 0).count == 3)
    }

    @Test("A stored message keeps mentions; the agent gets names, the command and the scope") @MainActor
    func agentQuestion() {
        let mention = ChatMention(kind: .project, key: "Northwind", label: "Northwind")
        let question = ChatBarViewModel.agentQuestion(plain: "/summarize @Northwind", mentions: [mention])
        #expect(question.hasPrefix("Summarize Northwind: the decisions"))
        #expect(question.hasSuffix("(Scope: project Northwind. Use only these unless I say otherwise.)"))
    }

    @Test("Tool chips read like a person wrote them")
    func stepChips() {
        let now = Self.day("2026-11-03")
        #expect(ChatStepPresentation.chipTitle(tool: "search_meetings", summary: "", resultCount: 6) == "Searched 6 meetings")
        let read = ChatStepPresentation.chipTitle(tool: "get_meeting", summary: "Read “Northwind x Harborcloud”, 2026-10-28", resultCount: 1, now: now)
        #expect(read.hasPrefix("Read · Northwind x Harborcloud · "))
        #expect(ChatStepPresentation.elapsed(2.42) == "2.4s")
        #expect(ChatStepPresentation.elapsed(65) == "1m 05s")
        #expect(ChatStepPresentation.thoughtFor(4.2) == "Thought for 4s")
        #expect(ChatStepPresentation.phaseLabel(phase: .searching, runningTool: "search_meetings", runningSummary: nil) == "Searching your meetings")
    }

    @Test("Evidence comes from facts, not the model's own confidence")
    func evidence() {
        #expect(ChatEvidence.of(linkedToItem: true, meetingsRead: 2, hasBody: true).level == 3)
        #expect(ChatEvidence.of(linkedToItem: false, meetingsRead: 0, hasBody: false).label == "Needs review")
        #expect(ChatEvidence.of(linkedToItem: false, meetingsRead: 1, hasBody: true).detail == "From 1 meeting · Not linked to an action item")
    }
}

@Suite("Chat markdown")
struct ChatMarkdownTests {
    @Test("Headings, paragraphs, nested and ordered lists, quotes, rules")
    func basicBlocks() {
        let blocks = ChatMarkdown.parse("""
        ## Summary
        First line
        continues here.

        - One
          - Nested
        - Two

        1. First
        2) Second

        > Quoted

        ---
        """)
        #expect(blocks[0] == .heading(level: 2, text: "Summary"))
        #expect(blocks[1] == .paragraph("First line\ncontinues here."))
        guard case .list(false, let items) = blocks[2] else { Issue.record("expected a bullet list"); return }
        #expect(items.map(\.indent) == [0, 1, 0])
        guard case .list(true, let ordered) = blocks[3] else { Issue.record("expected an ordered list"); return }
        #expect(ordered.map(\.number) == [1, 2])
        #expect(blocks[4] == .quote("Quoted"))
        #expect(blocks[5] == .rule)
    }

    @Test("Tables keep header, alignment, escaped pipes and pad short rows")
    func tables() {
        let blocks = ChatMarkdown.parse("""
        | Topic | Oct 21 | Oct 28 |
        |:------|:------:|-------:|
        | Accounts | Open | Agreed \\| signed |
        | Budget | TBD |
        """)
        guard case .table(let header, let alignments, let rows) = blocks.first else { Issue.record("expected a table"); return }
        #expect(header == ["Topic", "Oct 21", "Oct 28"])
        #expect(alignments == [.leading, .center, .trailing])
        #expect(rows[0][2] == "Agreed | signed")
        #expect(rows[1] == ["Budget", "TBD", ""])
    }

    @Test("A table header without its separator yet stays a paragraph (streaming)")
    func partialTable() {
        #expect(ChatMarkdown.parse("| Topic | Oct 21 |") == [.paragraph("| Topic | Oct 21 |")])
    }

    @Test("Fenced code keeps its language; an unclosed fence runs to the end")
    func code() {
        #expect(ChatMarkdown.parse("```swift\nlet a = 1\n```\nAfter") == [.code(language: "swift", code: "let a = 1"), .paragraph("After")])
        #expect(ChatMarkdown.parse("```\npartial") == [.code(language: nil, code: "partial")])
    }

    @Test("Task lists and lists under an action-items heading become action rows")
    func actionItems() {
        let tasks = ChatMarkdown.parse("- [ ] Send the plan — Daniel\n- [x] Book the room")
        guard case .actionItems(let items) = tasks.first else { Issue.record("expected action items"); return }
        #expect(items[0] == ChatActionItemDraft(title: "Send the plan", assignee: "Daniel", due: nil, done: false))
        #expect(items[1].done)

        let headed = ChatMarkdown.parse("### Next steps\n- **Alex**: Share the account plan by Thursday\n- Review guardrails (Owner: Greta, due 2026-11-07)")
        guard case .actionItems(let next) = headed.last else { Issue.record("expected action items"); return }
        #expect(next[0] == ChatActionItemDraft(title: "Share the account plan", assignee: "Alex", due: "Thursday", done: false))
        #expect(next[1] == ChatActionItemDraft(title: "Review guardrails", assignee: "Greta", due: "2026-11-07", done: false))

        // An ordinary list stays a list.
        guard case .list = ChatMarkdown.parse("### Decisions\n- Use Organizations").last else { Issue.record("expected a list"); return }
    }

    @Test("Adjacent citations, a mention and code render inline without losing runs") @MainActor
    func inlineCitations() {
        let text = "Scope narrowed [2](lidia-cite://2)[1](lidia-cite://1) for [@Northwind](lidia-mention://project/Northwind) in `eu-west-1`."
        let attributed = ChatInline.attributed(text, size: 14, caret: true)
        let links = attributed.runs.compactMap(\.link)
        #expect(links.filter { $0.scheme == ChatCitations.scheme }.compactMap(ChatCitations.number) == [2, 1])
        #expect(links.contains { $0.scheme == ChatMentions.scheme })
        let plain = String(attributed.characters)
        #expect(plain.hasPrefix("Scope narrowed \u{2009}2\u{2009}\u{2009}1\u{2009} for @Northwind in eu-west-1."))
        #expect(plain.hasSuffix("\u{25CF}"))
    }

    @Test("A heading above action items becomes the card title") @MainActor
    func actionHeadingFolds() {
        let folded = ChatMarkdownView.foldActionHeadings(ChatMarkdown.parse("### Next steps\n- [ ] Ship it — Alex"))
        #expect(folded.count == 1)
        #expect(folded[0].title == "Next steps")
    }

    @Test("Tool IDs and board statuses are stripped from action rows")
    func actionItemNoise() {
        let item = ChatActionItemDraft.parse("[a1b2c3d4] [done] Send invoices — Selin")
        #expect(item == ChatActionItemDraft(title: "Send invoices", assignee: "Selin", due: nil, done: true))
    }
}
