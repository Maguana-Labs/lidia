import Foundation
import SwiftData

/// LidIA's agent tools over the meeting library. Small on purpose: four
/// readers, two writers that only run after confirmation, and one drafter.
///
/// Handlers run on the main actor and fetch every model by ID from the run's
/// context each time (LiveModel rule): nothing is held across an await.
/// Results are compact text with 8-character ids the model can copy.
@MainActor
enum LidIATools {
    static func all(destinations: AgentDestinations) -> AgentToolRegistry {
        AgentToolRegistry([
            searchMeetings, getMeeting, listActionItems, listProjects,
            createActionItem, updateActionItemStatus, proposeDispatch(destinations), askUser,
        ])
    }

    /// The Kanban "Comment to AI" tools.
    static func commentTools(destinations: AgentDestinations) -> AgentToolRegistry {
        AgentToolRegistry([proposeDispatch(destinations), updateActionItemStatus])
    }

    static let statusValues = ["todo", "in_progress", "waiting", "done"]

    // MARK: - search_meetings

    static let searchMeetings = AgentTool(
        spec: AgentToolSpec(
            name: "search_meetings",
            description: "Find meetings by words (title, notes, transcript), person or dates.",
            parameters: [
                AgentParameter(name: "query", kind: .string, description: "Key words, e.g. a company, topic or project"),
                AgentParameter(name: "person", kind: .string, description: "A participant's name or email"),
                AgentParameter(name: "from", kind: .date, description: "Earliest meeting date"),
                AgentParameter(name: "to", kind: .date, description: "Latest meeting date"),
                AgentParameter(name: "limit", kind: .integer, description: "Most results to return, 1-10 (default 5)"),
            ]
        ),
        effect: .readOnly
    ) { arguments, context in
        let limit = min(10, max(1, arguments.integer("limit") ?? 5))
        let terms = searchTerms(arguments.string("query") ?? "")
        let person = arguments.string("person").map(AttendeeParser.fold)
        let from = arguments.date("from")
        let to = arguments.date("to").map { Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }

        var meetings = try context.modelContext.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        meetings = meetings.filter { meeting in
            if let from, meeting.date < from { return false }
            if let to, meeting.date >= to { return false }
            if let person {
                let people = AttendeeParser.fold((meeting.calendarAttendees ?? []).joined(separator: " ") + " " + meeting.title)
                if !people.contains(person) { return false }
            }
            return true
        }

        var scored: [(Meeting, Int)]
        if terms.isEmpty {
            scored = meetings.map { ($0, 0) }
        } else {
            scored = meetings.compactMap { meeting in
                let score = metadataScore(meeting, terms: terms)
                return score > 0 ? (meeting, score) : nil
            }
            // Transcripts are big: only read them when the rest found too little.
            if scored.count < limit {
                let found = Set(scored.map { $0.0.id })
                for meeting in meetings where !found.contains(meeting.id) {
                    let transcript = transcriptText(meeting)
                    let hits = terms.filter { mentions(transcript, $0) }.count
                    if hits > 0 { scored.append((meeting, hits)) }
                    if scored.count >= limit * 2 { break }
                }
            }
            // Keep the strong matches (at least half the best score), newest
            // first, so "last time" lands on the latest relevant meeting.
            let best = scored.map(\.1).max() ?? 0
            scored = scored.filter { $0.1 * 2 >= best }
            scored.sort { $0.0.date > $1.0.date }
        }

        let top = scored.prefix(limit).map(\.0)
        guard !top.isEmpty else {
            return AgentToolOutput("No meetings found.", resultCount: 0)
        }
        let lines = top.map { meeting -> String in
            var line = "[\(shortID(meeting.id))] \(AgentDates.readable(meeting.date)) · \(meeting.title)"
            let people = attendeeNames(meeting).prefix(4)
            if !people.isEmpty { line += " · with \(people.joined(separator: ", "))" }
            if let project = ProjectCatalog.project(ofFolder: meeting.folder) { line += " · project \(project)" }
            if meeting.date > context.now { line += " · upcoming" }
            if let snippet = snippet(summaryText(meeting), terms: terms, length: 110) { line += "\n  match: \(snippet)" }
            return line
        }
        return AgentToolOutput(
            "\(top.count) meeting\(top.count == 1 ? "" : "s"). Matches are fragments, not content: call get_meeting with an id before answering about a meeting.\n" + lines.joined(separator: "\n"),
            meetings: top.map { ref($0, excerpt: snippet(summaryText($0), terms: terms, length: 160)) },
            resultCount: top.count
        )
    }

    // MARK: - get_meeting

    static let getMeeting = AgentTool(
        spec: AgentToolSpec(
            name: "get_meeting",
            description: "A meeting's summary, notes, action items, and transcript passages matching query.",
            parameters: [
                AgentParameter(name: "meeting_id", kind: .string, description: "The meeting's id from search_meetings", required: true),
                AgentParameter(name: "query", kind: .string, description: "Words to find in the transcript"),
            ]
        ),
        effect: .readOnly
    ) { arguments, context in
        guard let meeting = findMeeting(arguments.string("meeting_id") ?? "", in: context.modelContext) else {
            return AgentToolOutput("No meeting with that id. Use search_meetings to find one.")
        }
        var parts: [String] = []
        var header = "[\(shortID(meeting.id))] \(meeting.title)\nDate: \(AgentDates.readable(meeting.date))"
        if meeting.duration > 0 { header += " · \(Int((meeting.duration / 60).rounded())) min" }
        parts.append(header)
        let people = attendeeNames(meeting)
        if !people.isEmpty { parts.append("Participants: \(people.prefix(12).joined(separator: ", "))") }
        if let project = ProjectCatalog.project(ofFolder: meeting.folder) { parts.append("Project: \(project)") }

        let summary = summaryText(meeting)
        parts.append("Summary:\n" + (summary.isEmpty ? "(none)" : summary.agentTruncated(3_000)))
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("User's notes:\n" + notes.agentTruncated(1_000)) }

        let items = meeting.actionItems.sorted { $0.title < $1.title }
        if !items.isEmpty {
            parts.append("Action items:\n" + items.prefix(15).map { actionItemLine($0, includeMeeting: false) }.joined(separator: "\n"))
        }

        let transcript = transcriptText(meeting)
        var excerpt = snippet(summary, terms: [], length: 200)
        if let query = arguments.string("query") {
            let excerpts = transcriptExcerpts(transcript, terms: searchTerms(query), maxCount: 3, radius: 300)
            parts.append(excerpts.isEmpty ? "Transcript: no passage matches \"\(query)\"." : "Transcript excerpts:\n" + excerpts.map { "… \($0) …" }.joined(separator: "\n"))
            if let first = excerpts.first { excerpt = first.agentTruncated(200) }
        } else if summary.isEmpty, !transcript.isEmpty {
            parts.append("Transcript start:\n" + transcript.agentTruncated(1_500))
            excerpt = transcript.agentTruncated(200)
        }
        return AgentToolOutput(parts.joined(separator: "\n\n"), meetings: [ref(meeting, excerpt: excerpt)], resultCount: 1)
    }

    // MARK: - list_action_items

    static let listActionItems = AgentTool(
        spec: AgentToolSpec(
            name: "list_action_items",
            description: "Action items; open ones by default, soonest due first.",
            parameters: [
                AgentParameter(name: "status", kind: .oneOf(["open", "todo", "in_progress", "waiting", "done", "all"]), description: "Which items (default open)"),
                AgentParameter(name: "assignee", kind: .string, description: "Owner's name"),
                AgentParameter(name: "meeting_id", kind: .string, description: "Only items from this meeting"),
                AgentParameter(name: "project", kind: .string, description: "Only items from meetings in this project"),
                AgentParameter(name: "limit", kind: .integer, description: "Most items, 1-30 (default 15)"),
            ]
        ),
        effect: .readOnly
    ) { arguments, context in
        let status = arguments.string("status") ?? "open"
        let limit = min(30, max(1, arguments.integer("limit") ?? 15))
        let assignee = arguments.string("assignee").map(AttendeeParser.fold)
        let project = arguments.string("project").map(ProjectCatalog.fold)
        var meetingID: UUID?
        if let raw = arguments.string("meeting_id") {
            guard let meeting = findMeeting(raw, in: context.modelContext) else {
                return AgentToolOutput("No meeting with that id.")
            }
            meetingID = meeting.id
        }

        let all = try context.modelContext.fetch(FetchDescriptor<ActionItem>())
        let items = all.filter { item in
            switch status {
            case "open": if item.isCompleted { return false }
            case "all": break
            default: if boardValue(item.boardStatus) != status { return false }
            }
            if let assignee, !AttendeeParser.fold(item.assignee ?? "").contains(assignee) { return false }
            if let meetingID, item.meeting?.id != meetingID { return false }
            if let project {
                guard let name = ProjectCatalog.project(ofFolder: item.meeting?.folder), ProjectCatalog.fold(name).contains(project) else { return false }
            }
            return true
        }
        .sorted { lhs, rhs in
            switch (lhs.deadlineDate, rhs.deadlineDate) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (lhs.meeting?.date ?? .distantPast) > (rhs.meeting?.date ?? .distantPast)
            }
        }
        guard !items.isEmpty else { return AgentToolOutput("No matching action items.", resultCount: 0) }
        let shown = items.prefix(limit)
        var text = "\(items.count) item\(items.count == 1 ? "" : "s")\(items.count > shown.count ? " (showing \(shown.count))" : ""):\n"
        text += shown.map { actionItemLine($0, includeMeeting: true) }.joined(separator: "\n")
        var seenMeetings = Set<UUID>()
        let meetings = shown.compactMap(\.meeting).filter { seenMeetings.insert($0.id).inserted }
        return AgentToolOutput(text, meetings: meetings.map { ref($0, excerpt: nil) }, resultCount: items.count)
    }

    // MARK: - list_projects

    static let listProjects = AgentTool(
        spec: AgentToolSpec(
            name: "list_projects",
            description: "Projects with meeting count, last meeting and open items.",
            parameters: []
        ),
        effect: .readOnly
    ) { _, context in
        let meetings = try context.modelContext.fetch(FetchDescriptor<Meeting>())
        struct Row { var name: String; var count = 0; var last: Date?; var open = 0 }
        var rows: [String: Row] = [:]
        for meeting in meetings {
            guard let name = ProjectCatalog.project(ofFolder: meeting.folder) else { continue }
            let key = ProjectCatalog.fold(name)
            var row = rows[key] ?? Row(name: name)
            row.count += 1
            if row.last.map({ meeting.date > $0 }) ?? true { row.last = meeting.date }
            row.open += meeting.actionItems.filter { !$0.isCompleted }.count
            rows[key] = row
        }
        for name in IntelligenceStore.shared.state.knownProjects where rows[ProjectCatalog.fold(name)] == nil {
            rows[ProjectCatalog.fold(name)] = Row(name: name)
        }
        guard !rows.isEmpty else { return AgentToolOutput("No projects yet.", resultCount: 0) }
        let sorted = rows.values.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        return AgentToolOutput(sorted.map { row in
            "- \(row.name): \(row.count) meeting\(row.count == 1 ? "" : "s")"
                + (row.last.map { ", last \(AgentDates.day($0))" } ?? "")
                + ", \(row.open) open item\(row.open == 1 ? "" : "s")"
        }.joined(separator: "\n"), resultCount: sorted.count)
    }

    // MARK: - ask_user

    static let askUser = AgentTool(
        spec: AgentToolSpec(
            name: "ask_user",
            description: "Ask the user to choose or clarify, then stop.",
            parameters: [
                AgentParameter(name: "question", kind: .string, description: "The question", required: true),
                AgentParameter(name: "options", kind: .string, description: "Choices separated by |"),
            ]
        ),
        effect: .readOnly
    ) { arguments, _ in
        let question = arguments.string("question") ?? ""
        let options = (arguments.string("options") ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return AgentToolOutput("Asked the user. Wait for their reply.", clarification: AgentClarification(question: question, options: Array(options.prefix(4))))
    }

    // MARK: - create_action_item (mutating)

    static let createActionItem = AgentTool(
        spec: AgentToolSpec(
            name: "create_action_item",
            description: "Prepare a new action item (made once the user confirms).",
            parameters: [
                AgentParameter(name: "title", kind: .string, description: "The task, starting with a verb", required: true),
                AgentParameter(name: "assignee", kind: .string, description: "Who owns it"),
                AgentParameter(name: "deadline", kind: .date, description: "Due date"),
                AgentParameter(name: "meeting_id", kind: .string, description: "The meeting it comes from"),
            ]
        ),
        effect: .mutating,
        describe: { arguments, context in
            var text = "Create action item “\(arguments.string("title") ?? "")”"
            if let assignee = arguments.string("assignee") { text += " for \(assignee)" }
            if let deadline = arguments.string("deadline") { text += ", due \(deadline)" }
            if let id = arguments.string("meeting_id"), let meeting = findMeeting(id, in: context.modelContext) {
                text += ", in “\(meeting.title)”"
            }
            return text
        }
    ) { arguments, context in
        guard let title = arguments.string("title") else { return AgentToolOutput("Missing title.") }
        let deadline = arguments.date("deadline")
        let item = ActionItem(title: title, assignee: arguments.string("assignee"), deadline: arguments.string("deadline"), deadlineDate: deadline)
        if let id = arguments.string("meeting_id"), let meeting = findMeeting(id, in: context.modelContext) {
            item.meeting = meeting
            meeting.actionItems.append(item)
        }
        context.modelContext.insert(item)
        try context.modelContext.save()
        return AgentToolOutput("Created [\(shortID(item.id))] \(title)")
    }

    // MARK: - update_action_item_status (mutating)

    static let updateActionItemStatus = AgentTool(
        spec: AgentToolSpec(
            name: "update_action_item_status",
            description: "Prepare a status change (made once the user confirms).",
            parameters: [
                AgentParameter(name: "action_item_id", kind: .string, description: "The item's id from list_action_items or get_meeting", required: true),
                AgentParameter(name: "status", kind: .oneOf(statusValues), description: "New status", required: true),
            ]
        ),
        effect: .mutating,
        describe: { arguments, context in
            let status = boardStatus(arguments.string("status") ?? "")?.title ?? (arguments.string("status") ?? "")
            if let item = findActionItem(arguments.string("action_item_id") ?? "", in: context.modelContext) {
                return "Move “\(item.title)” to \(status)"
            }
            return "Move action item \(arguments.string("action_item_id") ?? "") to \(status)"
        }
    ) { arguments, context in
        guard let item = findActionItem(arguments.string("action_item_id") ?? "", in: context.modelContext) else {
            return AgentToolOutput("No action item with that id.")
        }
        guard let status = boardStatus(arguments.string("status") ?? "") else { return AgentToolOutput("Unknown status.") }
        item.boardStatus = status
        try context.modelContext.save()
        return AgentToolOutput("Moved “\(item.title)” to \(status.title)")
    }

    // MARK: - propose_dispatch (proposal)

    static func proposeDispatch(_ destinations: AgentDestinations) -> AgentTool {
        AgentTool(
            spec: AgentToolSpec(
                name: "propose_dispatch",
                description: "Draft sending an action item somewhere. Nothing is sent.",
                parameters: [
                    AgentParameter(name: "destination", kind: .oneOf(destinations.identifiers), description: "Where it would go", required: true),
                    AgentParameter(name: "title", kind: .string, description: "Short title for the task or email subject", required: true),
                    AgentParameter(name: "body", kind: .string, description: "One to three sentences of context, from the item and meeting only"),
                    AgentParameter(name: "action_item_id", kind: .string, description: "The action item it is about"),
                ]
            ),
            effect: .proposal
        ) { arguments, context in
            guard let destination = arguments.string("destination"), context.destinations.identifiers.contains(destination) else {
                return AgentToolOutput("That destination isn't set up. Use one of: \(context.destinations.identifiers.joined(separator: ", ")).")
            }
            var itemID: UUID?
            if let raw = arguments.string("action_item_id") {
                guard let item = findActionItem(raw, in: context.modelContext) else {
                    return AgentToolOutput("No action item with that id.")
                }
                itemID = item.id
            }
            let title = (arguments.string("title") ?? "").agentTruncated(140)
            let body = (arguments.string("body") ?? "").agentTruncated(600)
            let proposal = AgentDispatchProposal(destination: destination, title: title, body: body, actionItemID: itemID)
            return AgentToolOutput(
                "Proposal drafted: \(CommentToAction.displayName(destination)) “\(title)”. Nothing was sent; the user will review it and confirm.",
                proposal: proposal
            )
        }
    }

    // MARK: - Lookup

    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func ref(_ meeting: Meeting, excerpt: String?) -> AgentMeetingRef {
        AgentMeetingRef(id: meeting.id, title: meeting.title, date: meeting.date, excerpt: excerpt)
    }

    /// A meeting by full id, id prefix (from `shortID`), or, failing that, title.
    static func findMeeting(_ raw: String, in context: ModelContext) -> Meeting? {
        let key = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \"'")).lowercased()
        guard !key.isEmpty else { return nil }
        if let uuid = UUID(uuidString: key) { return LiveModel.meeting(uuid, in: context) }
        let all = (try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        if key.count >= 6, let match = all.first(where: { $0.id.uuidString.lowercased().hasPrefix(key) }) { return match }
        let folded = AttendeeParser.fold(key)
        return all.first { AttendeeParser.fold($0.title) == folded } ?? all.first { AttendeeParser.fold($0.title).contains(folded) }
    }

    static func findActionItem(_ raw: String, in context: ModelContext) -> ActionItem? {
        let key = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \"'")).lowercased()
        guard !key.isEmpty else { return nil }
        if let uuid = UUID(uuidString: key) { return LiveModel.actionItem(uuid, in: context) }
        guard key.count >= 6 else { return nil }
        let all = (try? context.fetch(FetchDescriptor<ActionItem>())) ?? []
        return all.first { $0.id.uuidString.lowercased().hasPrefix(key) }
    }

    // MARK: - Text

    static func summaryText(_ meeting: Meeting) -> String {
        (meeting.userEditedSummary ?? meeting.summary).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcriptText(_ meeting: Meeting) -> String {
        if let edited = meeting.userEditedTranscript, !edited.isEmpty { return edited }
        if !meeting.refinedTranscript.isEmpty { return meeting.refinedTranscript }
        return meeting.rawTranscript.map(\.word).joined(separator: " ")
    }

    static func attendeeNames(_ meeting: Meeting) -> [String] {
        (meeting.calendarAttendees ?? []).map { raw in
            let parsed = RelationshipStore.parseAttendee(raw)
            if let name = parsed.displayName, !name.isEmpty { return name }
            if let email = parsed.email { return RelationshipStore.displayNameFromEmail(email) }
            return raw
        }
    }

    static func boardValue(_ status: ActionItemStatus) -> String {
        switch status {
        case .todo: "todo"
        case .inProgress: "in_progress"
        case .waiting: "waiting"
        case .done: "done"
        }
    }

    static func boardStatus(_ value: String) -> ActionItemStatus? {
        switch value {
        case "todo": .todo
        case "in_progress": .inProgress
        case "waiting": .waiting
        case "done": .done
        default: nil
        }
    }

    static func actionItemLine(_ item: ActionItem, includeMeeting: Bool) -> String {
        var line = "[\(shortID(item.id))] [\(boardValue(item.boardStatus))] \(item.title)"
        if let assignee = item.assignee, !assignee.isEmpty { line += " · owner \(assignee)" }
        if let deadline = item.displayDeadline { line += " · due \(deadline)" }
        if includeMeeting, let meeting = item.meeting {
            line += " · from “\(meeting.title)” \(AgentDates.day(meeting.date)) [\(shortID(meeting.id))]"
        }
        return line
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about", "at", "by",
        "is", "are", "was", "were", "be", "it", "this", "that", "what", "when", "who", "how",
        "did", "do", "does", "we", "i", "my", "me", "our", "you", "last", "time", "meeting", "meetings",
        "el", "la", "los", "las", "de", "del", "con", "que", "en", "y", "un", "una", "por", "para",
    ]

    /// Folded search words without stopwords.
    static func searchTerms(_ query: String) -> [String] {
        AttendeeParser.fold(query)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    private static func metadataScore(_ meeting: Meeting, terms: [String]) -> Int {
        let title = AttendeeParser.fold(meeting.title)
        let people = AttendeeParser.fold((meeting.calendarAttendees ?? []).joined(separator: " "))
        let project = AttendeeParser.fold(meeting.folder ?? "")
        let body = AttendeeParser.fold(summaryText(meeting) + " " + meeting.notes)
        var score = 0
        for term in terms {
            if title.contains(term) { score += 3 }
            if people.contains(term) { score += 3 }
            if project.contains(term) { score += 2 }
            if body.contains(term) { score += 1 }
        }
        return score
    }

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func mentions(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: matchOptions) != nil
    }

    /// A passage around the first term found, else the opening.
    static func snippet(_ text: String, terms: [String], length: Int) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        for term in terms {
            if let range = flat.range(of: term, options: matchOptions) {
                let start = flat.index(range.lowerBound, offsetBy: -min(length / 3, flat.distance(from: flat.startIndex, to: range.lowerBound)))
                return String(flat[start...]).agentTruncated(length)
            }
        }
        return flat.agentTruncated(length)
    }

    /// Up to `maxCount` non-overlapping passages around matches, in order.
    static func transcriptExcerpts(_ transcript: String, terms: [String], maxCount: Int, radius: Int) -> [String] {
        guard !terms.isEmpty, !transcript.isEmpty else { return [] }
        var excerpts: [String] = []
        var searchStart = transcript.startIndex
        while excerpts.count < maxCount, searchStart < transcript.endIndex {
            let next = terms
                .compactMap { transcript.range(of: $0, options: matchOptions, range: searchStart..<transcript.endIndex) }
                .min { $0.lowerBound < $1.lowerBound }
            guard let range = next else { break }
            let lower = transcript.index(range.lowerBound, offsetBy: -radius, limitedBy: transcript.startIndex) ?? transcript.startIndex
            let upper = transcript.index(range.upperBound, offsetBy: radius, limitedBy: transcript.endIndex) ?? transcript.endIndex
            excerpts.append(String(transcript[lower..<upper]).replacingOccurrences(of: "\n", with: " "))
            searchStart = upper
        }
        return excerpts
    }
}
