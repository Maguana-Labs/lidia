import AppIntents
import Foundation
import LidIAKit
import SwiftUI

// The intents both apps offer, over the shared library. Titles, descriptions
// and parameter descriptions are written for Siri: say what the intent does,
// what it returns and when to use it. Lines marked `siri-27.3:` turn these
// into Siri AI tools when the 27.3 SDK is installed (docs/siri.md).

// MARK: - Find meetings

// siri-27.3: @AppIntent(.tool)
public struct FindMeetingsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Meetings"
    public static let description = IntentDescription(
        "Finds meetings in LidIA by who was there, the project, words they mention, or a date range, newest first. Returns each meeting's title, date and attendees. To read what was said, get the meeting's summary next.",
        categoryName: "Meetings",
        searchKeywords: ["meeting", "notes", "search", "reunión", "buscar"]
    )
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Person", description: "Someone who was in the meeting, by name or email.")
    public var person: PersonEntity?

    @Parameter(title: "Project", description: "The project the meeting is filed in.")
    public var project: ProjectEntity?

    @Parameter(title: "Words", description: "What the meeting was about: a company, topic or phrase. Matched against titles, notes and transcripts.")
    public var keyword: String?

    @Parameter(title: "From", description: "The earliest date to include.")
    public var from: Date?

    @Parameter(title: "To", description: "The latest date to include; the whole day counts.")
    public var to: Date?

    // siri-27.3: @Parameter(title: "Search", description: "The whole search at once, filled from the request: who, which project, what about, and which dates.")
    // siri-27.3: public var request: MeetingSearchRequest?

    public static var parameterSummary: some ParameterSummary {
        Summary("Find meetings with \(\.$person) about \(\.$keyword)") {
            \.$project
            \.$from
            \.$to
        }
    }

    public init() {}

    public init(person: PersonEntity? = nil, project: ProjectEntity? = nil, keyword: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.person = person
        self.project = project
        self.keyword = keyword
        self.from = from
        self.to = to
    }

    var search: SiriMeetingSearch {
        let search = SiriMeetingSearch(person: person?.name ?? person?.email, project: project?.name, keyword: keyword, from: from, to: to)
        // siri-27.3: if let request { return request.merged(into: search) }
        return search
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[MeetingEntity]> & ProvidesDialog & ShowsSnippetView {
        let context = try LidIASiri.context()
        let records = try SiriStore.meetingRecords(in: context)
        let found = SiriLibrary.findMeetings(records, search) { id in
            SiriStore.meeting(id, in: context).map(SiriStore.transcriptText) ?? ""
        }
        let entities = found.map(MeetingEntity.init(record:))
        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: SiriSpeech.foundMeetings(found)),
            view: MeetingListSnippet(meetings: entities, heading: entities.isEmpty ? "No meetings found" : "Meetings")
        )
    }
}

// MARK: - Summary and decisions

// siri-27.3: @AppIntent(.tool)
public struct GetMeetingSummaryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Meeting Summary"
    public static let description = IntentDescription(
        "Reads a meeting's notes from LidIA: the summary, the decisions, and the action items with owners and due dates. Use it for \"summarize this\" or \"what did we decide\". Meeting notes are private: Siri asks the user to authenticate, and LidIA leaves the summary out when the user keeps meeting content from Siri.",
        categoryName: "Meetings",
        searchKeywords: ["summary", "recap", "decisions", "notes", "resumen"]
    )
    public static let supportedModes: IntentModes = .background
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Meeting", description: "The meeting to summarize: the one on screen, or one found by person, project or date.")
    public var meeting: MeetingEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the summary of \(\.$meeting)")
    }

    public init() {}

    public init(meeting: MeetingEntity) {
        self.meeting = meeting
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let context = try LidIASiri.context()
        guard let model = SiriStore.meeting(meeting.id, in: context) else { throw LidIASiriError.meetingNotFound }
        let policy = SiriContentPolicy.current()
        let record = SiriStore.record(model, includeSearchText: false)
        let items = model.actionItems.filter { !$0.isDeleted }.map(SiriStore.itemRecord)
        let content = policy.allowsMeetingContent ? SiriStore.content(of: model) : nil
        let recap = SiriRecap.plainText(meeting: record, content: content, items: items, blockedMessage: policy.blockedMessage)
        let points = content.map { SiriRecap.plainSummary($0.summary).components(separatedBy: "\n").map { $0.replacingOccurrences(of: "• ", with: "") }.filter { !$0.hasSuffix(":") && !$0.isEmpty } } ?? []
        return .result(
            value: recap,
            dialog: IntentDialog(stringLiteral: SiriSpeech.summary(record: record, content: content, items: items, blockedMessage: policy.blockedMessage)),
            view: MeetingSummarySnippet(meeting: MeetingEntity(record: record), points: points, decisions: content?.decisions ?? [], blockedMessage: policy.blockedMessage)
        )
    }
}

// MARK: - Action items

// siri-27.3: @AppIntent(.tool)
public struct ListActionItemsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List Action Items"
    public static let description = IntentDescription(
        "Lists action items from LidIA meetings, open ones by default, soonest due first, with who owns each, when it's due and the meeting it came from. Filter to the user's own items, a person's, a project's, one meeting's (such as the one on screen), or those due by a date.",
        categoryName: "Action Items",
        searchKeywords: ["action items", "tasks", "to do", "follow up", "pendientes", "tareas"]
    )
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Whose", description: "Mine for the user's own items (owner is the user); Everyone's for all.", default: .everyone)
    public var owner: ActionItemOwnerAppEnum

    @Parameter(title: "Person", description: "Only items this person owns.")
    public var person: PersonEntity?

    @Parameter(title: "Project", description: "Only items from meetings in this project.")
    public var project: ProjectEntity?

    @Parameter(title: "Meeting", description: "Only items from this meeting, for example the one on screen.")
    public var meeting: MeetingEntity?

    @Parameter(title: "Due By", description: "Only items due on or before this day.")
    public var dueBy: Date?

    @Parameter(title: "Include Done", description: "Also list items already done.", default: false)
    public var includeDone: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("List \(\.$owner) action items") {
            \.$person
            \.$project
            \.$meeting
            \.$dueBy
            \.$includeDone
        }
    }

    public init() {}

    var search: SiriActionItemSearch {
        let ownerFilter: SiriItemOwner
        if let person { ownerFilter = .person(person.name.isEmpty ? (person.email ?? "") : person.name) }
        else if owner == .mine { ownerFilter = .mine }
        else { ownerFilter = .anyone }
        return SiriActionItemSearch(owner: ownerFilter, includeDone: includeDone, project: project?.name, meetingID: meeting?.id, dueBy: dueBy)
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ActionItemEntity]> & ProvidesDialog & ShowsSnippetView {
        let context = try LidIASiri.context()
        let found = SiriLibrary.findActionItems(try SiriStore.itemRecords(in: context), search, userName: LidIASiri.userName)
        let entities = found.compactMap { SiriStore.actionItem($0.id, in: context) }.map(ActionItemEntity.make)
        let heading = owner == .mine && person == nil ? "Your action items" : "Action items"
        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: SiriSpeech.actionItems(found, mine: owner == .mine && person == nil)),
            view: ActionItemListSnippet(items: entities, heading: heading)
        )
    }
}

// siri-27.3: @AppIntent(.tool)
public struct AddActionItemIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Action Item"
    public static let description = IntentDescription(
        "Adds an action item to LidIA, optionally to a meeting, with an owner and a due date. It's saved in the user's library only; nothing is sent to anyone.",
        categoryName: "Action Items",
        searchKeywords: ["add task", "action item", "to do", "añadir tarea"]
    )
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Title", description: "What has to be done, starting with a verb, e.g. \"Send the proposal\".", requestValueDialog: "What needs to be done?")
    public var itemTitle: String

    @Parameter(title: "Meeting", description: "The meeting it came from, such as the one on screen. Leave empty if it isn't from a meeting.")
    public var meeting: MeetingEntity?

    @Parameter(title: "Owner", description: "Who owns it: a person's name, or empty for the user.")
    public var owner: String?

    @Parameter(title: "Due Date", description: "When it's due.")
    public var dueDate: Date?

    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$itemTitle) to action items") {
            \.$meeting
            \.$owner
            \.$dueDate
        }
    }

    public init() {}

    public init(itemTitle: String, meeting: MeetingEntity? = nil, owner: String? = nil, dueDate: Date? = nil) {
        self.itemTitle = itemTitle
        self.meeting = meeting
        self.owner = owner
        self.dueDate = dueDate
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<ActionItemEntity> & ProvidesDialog & ShowsSnippetView {
        let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw $itemTitle.needsValueError("What needs to be done?") }
        let context = try LidIASiri.context()
        let ownerName = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ActionItem(title: title, assignee: (ownerName?.isEmpty ?? true) ? nil : ownerName)
        item.setPreciseDeadline(dueDate)
        var meetingModel: Meeting?
        if let meeting {
            guard let found = SiriStore.meeting(meeting.id, in: context) else { throw LidIASiriError.meetingNotFound }
            meetingModel = found
        }
        context.insert(item)
        if let meetingModel {
            item.meeting = meetingModel
            meetingModel.actionItems.append(item)
        }
        try context.save()
        LidIASiri.host?.libraryDidChange(meetingID: meetingModel?.id)
        let entity = ActionItemEntity.make(item)
        let detail = [ownerName.flatMap { $0.isEmpty ? nil : $0 }, dueDate.map { "due " + $0.formatted(date: .abbreviated, time: .omitted) }, meetingModel.map { "from " + $0.title }]
            .compactMap { $0 }.joined(separator: " · ")
        return .result(
            value: entity,
            dialog: IntentDialog(stringLiteral: "Added \u{201C}\(title)\u{201D} to your action items."),
            view: SiriConfirmationSnippet(symbol: "plus.circle.fill", title: title, detail: detail.isEmpty ? "Added to your action items" : detail)
        )
    }
}

// siri-27.3: @AppIntent(.tool)
public struct CompleteActionItemIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mark Action Item Done"
    public static let description = IntentDescription(
        "Marks an action item in LidIA as done. Nothing is sent to anyone.",
        categoryName: "Action Items",
        searchKeywords: ["done", "complete", "finish", "check off", "hecho", "completar"]
    )
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Action Item", description: "The item that's done: the one on screen, or one found by its words.")
    public var item: ActionItemEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$item) as done")
    }

    public init() {}

    public init(item: ActionItemEntity) {
        self.item = item
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<ActionItemEntity> & ProvidesDialog {
        let context = try LidIASiri.context()
        guard let model = SiriStore.actionItem(item.id, in: context) else { throw LidIASiriError.actionItemNotFound }
        let wasDone = model.isCompleted
        model.boardStatus = .done
        try context.save()
        LidIASiri.host?.libraryDidChange(meetingID: model.meeting?.id)
        let title = model.title
        return .result(
            value: ActionItemEntity.make(model),
            dialog: IntentDialog(stringLiteral: wasDone ? "\u{201C}\(title)\u{201D} was already done." : "Marked \u{201C}\(title)\u{201D} as done.")
        )
    }
}

// MARK: - Open

// siri-27.3: @AppIntent(.tool)
public struct OpenMeetingIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Meeting"
    public static let description = IntentDescription(
        "Opens a meeting in LidIA, with its notes, action items and transcript.",
        categoryName: "Meetings"
    )

    @Parameter(title: "Meeting", description: "The meeting to open.")
    public var target: MeetingEntity

    public init() {}

    public init(target: MeetingEntity) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let host = LidIASiri.host else { throw LidIASiriError.notReady }
        try await host.openMeeting(id: target.id)
        return .result()
    }
}

// MARK: - Ask

// siri-27.3: @AppIntent(.tool)
public struct AskLidIAIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask LidIA"
    public static let description = IntentDescription(
        "Answers a question about the user's meetings with LidIA's own assistant, which reads across meetings and cites them. It follows the same AI and privacy settings as Ask in the app. Use it for questions that need several meetings, like what was agreed with someone or how a project changed.",
        categoryName: "Ask",
        searchKeywords: ["ask", "question", "what did", "preguntar"]
    )
    public static let supportedModes: IntentModes = .background
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Question", description: "The question about the user's meetings, in the user's words.", requestValueDialog: "What do you want to know?")
    public var question: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Ask LidIA \(\.$question)")
    }

    public init() {}

    public init(question: String) {
        self.question = question
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let policy = SiriContentPolicy.current()
        if let blocked = policy.blockedMessage {
            return .result(value: blocked, dialog: IntentDialog(stringLiteral: blocked))
        }
        guard let host = LidIASiri.host else { throw LidIASiriError.notReady }
        let answer = try await host.ask(question.trimmingCharacters(in: .whitespacesAndNewlines))
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Every intent the shared package defines, for the apps' `AppIntentsPackage`.
public struct LidIAAppIntentsPackage: AppIntentsPackage {}
