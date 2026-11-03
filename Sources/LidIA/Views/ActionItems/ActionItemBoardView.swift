import LidIAAppIntents
import SwiftData
import SwiftUI

/// How the board groups cards inside each column.
enum ActionItemBoardGrouping: String, CaseIterable, Identifiable {
    case none, project, person

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No Grouping"
        case .project: "Project"
        case .person: "Person"
        }
    }
}

/// Pure board layout, for tests and the view.
enum ActionItemBoardModel {
    struct Group<Item>: Identifiable {
        var title: String
        var items: [Item]
        var id: String { title }
    }

    static func columns(showWaiting: Bool) -> [ActionItemStatus] {
        showWaiting ? [.todo, .inProgress, .waiting, .done] : [.todo, .inProgress, .done]
    }

    /// Items grouped under titles, largest group first, the catch-all last.
    static func groups<Item>(_ items: [Item], title: (Item) -> String?, fallback: String) -> [Group<Item>] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let key = title(item).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fallback
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order
            .map { Group(title: $0, items: buckets[$0] ?? []) }
            .sorted { lhs, rhs in
                if (lhs.title == fallback) != (rhs.title == fallback) { return rhs.title == fallback }
                return lhs.items.count != rhs.items.count ? lhs.items.count > rhs.items.count : lhs.title < rhs.title
            }
    }
}

/// Action items as a Kanban board: To Do, In Progress, (Waiting), Done.
/// Cards drag between columns and can be grouped by project or person.
struct ActionItemBoardView: View {
    /// Items to show, completed ones included (they fill Done).
    let rows: [(ActionItem, Meeting)]
    var grouping: ActionItemBoardGrouping
    var showWaiting: Bool
    var onOpenMeeting: (Meeting) -> Void
    var onDelete: (ActionItem, Meeting) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var proposal: PendingProposal?
    @State private var intentSheet: IntentSheetItem?

    /// Done shows the latest completed cards only.
    static let doneLimit = 30

    var body: some View {
        GeometryReader { proxy in
            let columns = ActionItemBoardModel.columns(showWaiting: showWaiting)
            let width = max(230, (proxy.size.width - 32 - CGFloat(columns.count - 1) * 12) / CGFloat(columns.count))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { status in
                        BoardColumn(
                            status: status,
                            rows: rows(for: status),
                            grouping: grouping,
                            onMove: { id in move(id, to: status) },
                            onOpenMeeting: onOpenMeeting,
                            onDelete: onDelete,
                            onPropose: { proposal = $0 },
                            onIntent: { intentSheet = $0 }
                        )
                        .frame(width: width)
                    }
                }
                .padding(16)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
        .sheet(item: $proposal) { pending in
            ActionProposalSheet(pending: pending)
        }
        .sheet(item: $intentSheet) { sheet in
            IntentConfirmSheet(intent: sheet.intent, item: sheet.item, meeting: sheet.meeting)
        }
        #if DEBUG
        .onAppear {
            MainWindowSnapshotDriver.shared?.boardIntent = { match in
                for (item, meeting) in rows where !item.isCompleted && item.title.localizedCaseInsensitiveContains(match) {
                    if let intent = IntentStore.shared.intent(for: item.id) {
                        intentSheet = IntentSheetItem(intent: intent, item: item, meeting: meeting)
                        return
                    }
                }
            }
            MainWindowSnapshotDriver.shared?.boardComment = { comment in
                guard let (item, meeting) = rows.first(where: { !$0.0.isCompleted }).map({ ($0.0, $0.1) }),
                      let interpreted = CommentToAction.interpret(comment, itemTitle: item.title, available: .init(clickUp: true))
                else { return }
                proposal = PendingProposal(item: item, meeting: meeting, comment: comment, proposal: interpreted)
            }
        }
        #endif
    }

    private func rows(for status: ActionItemStatus) -> [(ActionItem, Meeting)] {
        let matching = rows.filter { item, _ in
            let column = item.boardStatus
            // Without a Waiting column, waiting cards stay in progress.
            if !showWaiting, column == .waiting { return status == .inProgress }
            return column == status
        }
        return status == .done ? Array(matching.prefix(Self.doneLimit)) : matching
    }

    private func move(_ id: String, to status: ActionItemStatus) {
        guard let uuid = UUID(uuidString: id), let row = rows.first(where: { $0.0.id == uuid }) else { return }
        let item = row.0
        withAnimation(.easeOut(duration: 0.15)) { item.boardStatus = status }
        try? modelContext.save()
        if status == .done { SiriDonations.completed(item) }
    }
}

/// An intent waiting for the user's confirmation.
struct IntentSheetItem: Identifiable {
    let intent: ActionIntent
    let item: ActionItem
    let meeting: Meeting
    var id: UUID { item.id }
}

/// An action item and the comment-to-AI proposal waiting for confirmation.
struct PendingProposal: Identifiable {
    let id = UUID()
    let item: ActionItem
    let meeting: Meeting
    var comment: String
    var proposal: ActionProposal
    /// What the agent was sent and did, when AI wrote the proposal.
    var transcript: AgentTranscript?
}

// MARK: - Column

private struct BoardColumn: View {
    let status: ActionItemStatus
    let rows: [(ActionItem, Meeting)]
    var grouping: ActionItemBoardGrouping
    var onMove: (String) -> Void
    var onOpenMeeting: (Meeting) -> Void
    var onDelete: (ActionItem, Meeting) -> Void
    var onPropose: (PendingProposal) -> Void
    var onIntent: (IntentSheetItem) -> Void

    @State private var isTargeted = false

    private var tint: Color {
        switch status {
        case .todo: .secondary
        case .inProgress: .blue
        case .waiting: .orange
        case .done: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(status.title)
                    .font(.headline)
                Text("\(rows.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if rows.isEmpty {
                        Text(status == .done ? "Finished items land here." : "Drag cards here.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else if grouping == .none {
                        cards(rows)
                    } else {
                        ForEach(groups) { group in
                            HStack(spacing: 6) {
                                if grouping == .project, group.title != "No project" {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(ProjectPalette.color(for: group.title))
                                }
                                Text(group.title)
                                    .lineLimit(1)
                                Text("\(group.items.count)")
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                            cards(group.items)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            (isTargeted ? tint.opacity(0.10) : Color.primary.opacity(0.025)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? tint.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.4), lineWidth: isTargeted ? 1 : 0.5)
        )
        .dropDestination(for: String.self) { ids, _ in
            ids.forEach(onMove)
            return !ids.isEmpty
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    private var groups: [ActionItemBoardModel.Group<(ActionItem, Meeting)>] {
        switch grouping {
        case .none: []
        case .project: ActionItemBoardModel.groups(rows, title: { $0.1.projectName }, fallback: "No project")
        case .person: ActionItemBoardModel.groups(rows, title: { $0.0.assignee }, fallback: "Unassigned")
        }
    }

    private func cards(_ rows: [(ActionItem, Meeting)]) -> some View {
        ForEach(rows, id: \.0.id) { item, meeting in
            ActionItemCard(
                item: item,
                meeting: meeting,
                onOpenMeeting: { onOpenMeeting(meeting) },
                onDelete: { onDelete(item, meeting) },
                onPropose: onPropose,
                onIntent: onIntent
            )
            .draggable(item.id.uuidString) {
                Text(item.title)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: 220)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Card

private struct ActionItemCard: View {
    @Bindable var item: ActionItem
    let meeting: Meeting
    var onOpenMeeting: () -> Void
    var onDelete: () -> Void
    var onPropose: (PendingProposal) -> Void
    var onIntent: (IntentSheetItem) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.modelContext) private var modelContext

    @State private var hovering = false
    @State private var showsComment = false
    @State private var comment = ""
    @State private var isThinking = false
    @State private var status: String?
    @FocusState private var commentFocused: Bool

    private var commentToAI: Bool {
        IntelligenceStore.shared.commentToAI(for: item.id, global: settings.commentToAIEnabled)
    }

    private var isOverdue: Bool {
        guard let deadline = item.deadlineDate, !item.isCompleted else { return false }
        return deadline < Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        card.siriOnscreen(item: item)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(item.isCompleted, color: .secondary)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.isUrgent && !item.isCompleted {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(item.priority == "critical" ? .red : .orange)
                        .help(item.priority == "none" ? "Due soon" : "Priority: \(item.priority)")
                        .accessibilityLabel("Urgent")
                }
                menu
                    .opacity(hovering ? 1 : 0.001)
            }

            HStack(spacing: 6) {
                if let project = meeting.projectName {
                    ProjectLabel(name: project)
                } else {
                    Text(meeting.title.trimmingCharacters(in: .whitespaces))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let deadline = item.displayDeadline {
                    Text(deadline)
                        .font(.caption)
                        .foregroundStyle(isOverdue ? .red : .secondary)
                        .lineLimit(1)
                }
                if let assignee = item.assignee, !assignee.isEmpty {
                    AttendeeAvatar(attendee: MeetingAttendee(name: assignee, isCurrentUser: isMe(assignee)), size: 18)
                        .help(assignee)
                }
            }

            if !item.isCompleted {
                IntentSummaryView(
                    item: item,
                    meeting: meeting,
                    onDismissItem: onDelete,
                    onOpen: { onIntent(IntentSheetItem(intent: $0, item: item, meeting: meeting)) }
                )
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            if commentToAI && (showsComment || !comment.isEmpty) {
                commentField
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(hovering ? 0.9 : 0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 4 : 1, y: 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpenMeeting)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.boardStatus.title)")
    }

    // MARK: Comment to AI

    private var commentField: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Brand.red)
                .accessibilityHidden(true)
            TextField("Tell AI what to do, e.g. “open a ClickUp ticket”", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1...3)
                .focused($commentFocused)
                .onSubmit(submitComment)
                .disabled(isThinking)
            if isThinking {
                ProgressView().controlSize(.mini)
            } else if !comment.isEmpty {
                Button(action: submitComment) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.red)
                .accessibilityLabel("Ask AI")
            }
        }
        .padding(6)
        .background(Brand.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var available: CommentToAction.Available {
        CommentToAction.Available(
            clickUp: !settings.clickUpAPIKey.isEmpty && !settings.clickUpListID.isEmpty,
            notion: !settings.notionAPIKey.isEmpty && !settings.notionTasksDatabaseID.isEmpty,
            n8n: settings.n8nEnabled && !settings.n8nWebhookURL.isEmpty
        )
    }

    private func submitComment() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        isThinking = true
        let itemID = item.id
        let itemTitle = item.title
        let meetingTitle = meeting.title
        let meetingDate = meeting.date
        Task { @MainActor in
            defer { isThinking = false }
            let (result, transcript) = await CommentToAction.propose(
                comment: text, itemID: itemID, itemTitle: itemTitle, meetingTitle: meetingTitle, meetingDate: meetingDate,
                available: available, settings: settings, modelManager: modelManager, modelContext: modelContext
            )
            // The card may have been deleted while AI was thinking.
            guard let live = LiveModel.actionItem(itemID, in: modelContext), let liveMeeting = live.meeting else { return }
            guard let result else {
                flash("LidIA couldn't tell what to do. Try “open a ClickUp ticket” or “remind me Friday”.")
                return
            }
            onPropose(PendingProposal(item: live, meeting: liveMeeting, comment: text, proposal: result, transcript: transcript))
            comment = ""
            showsComment = false
        }
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            Menu("Move to") {
                ForEach(ActionItemStatus.allCases) { status in
                    Button(status.title, systemImage: status.systemImage) {
                        withAnimation { item.boardStatus = status }
                        try? modelContext.save()
                        if status == .done { SiriDonations.completed(item) }
                    }
                    .disabled(item.boardStatus == status)
                }
            }
            Menu("Send to") {
                Button("Apple Reminders", systemImage: "checklist") { propose(.dispatch(destination: "reminder")) }
                Button("Notion", systemImage: "doc.text") { propose(.dispatch(destination: "notion")) }
                    .disabled(!available.notion)
                Button("ClickUp", systemImage: "checkmark.square") { propose(.dispatch(destination: "clickup")) }
                    .disabled(!available.clickUp)
                Button("n8n", systemImage: "arrow.triangle.branch") { propose(.dispatch(destination: "n8n")) }
                    .disabled(!available.n8n)
            }
            Button("Draft Follow-up Email", systemImage: "envelope") { propose(.email) }
            Divider()
            Toggle(isOn: Binding(
                get: { commentToAI },
                set: { IntelligenceStore.shared.setCommentToAI($0, for: item.id, global: settings.commentToAIEnabled) }
            )) {
                Label("Comment to AI", systemImage: "sparkles")
            }
            if commentToAI {
                Button("Write a Comment…", systemImage: "text.bubble") {
                    showsComment = true
                    commentFocused = true
                }
            }
            Divider()
            Button("Open Meeting", systemImage: "arrow.up.right", action: onOpenMeeting)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions")
        .accessibilityLabel("Actions for \(item.title)")
    }

    private func propose(_ kind: ActionProposal.Kind) {
        onPropose(PendingProposal(item: item, meeting: meeting, comment: "", proposal: ActionProposal(kind: kind, title: item.title)))
    }

    private func flash(_ message: String) {
        withAnimation { status = message }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { status = nil }
        }
    }

    private func isMe(_ name: String) -> Bool {
        let me = settings.displayName.trimmingCharacters(in: .whitespaces)
        return !me.isEmpty && name.localizedStandardContains(me.split(separator: " ").first.map(String.init) ?? me)
    }
}

// MARK: - Confirmation

/// Shows what an action will do and runs it only on Confirm. Outbound
/// actions say where the data goes; Local-only mode blocks them.
struct ActionProposalSheet: View {
    let pending: PendingProposal

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var note = ""
    @State private var isRunning = false
    @State private var errorMessage: String?

    private var proposal: ActionProposal { pending.proposal }
    private var blockedByLocalOnly: Bool { proposal.isOutbound && settings.localOnlyMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: icon, tint: proposal.isOutbound ? .purple : .blue, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.summary)
                        .font(.title3.weight(.semibold))
                    Text(pending.comment.isEmpty ? "For “\(pending.item.title)”" : "From your comment: “\(pending.comment)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if hasFields {
                Form {
                    TextField("Title", text: $title)
                    if proposal.kind != .dispatch(destination: "reminder") {
                        TextField("Note", text: $note, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: proposal.kind == .dispatch(destination: "reminder") ? 70 : 140)
            }

            if blockedByLocalOnly {
                LocalOnlyModeBanner(message: "Local-only mode is on, so nothing is sent to \(proposal.destinationName).")
            } else if proposal.isOutbound {
                Label("Sends this title and note to \(proposal.destinationName).", systemImage: "arrow.up.forward.app")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if proposal.kind == .email {
                Label("Opens a draft in Mail. Nothing is sent until you send it there.", systemImage: "envelope")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if proposal.byAI {
                Label("Suggested by AI from your comment. Check it before you confirm.", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if let transcript = pending.transcript {
                AgentTranscriptDisclosure(transcript: transcript)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    run()
                } label: {
                    if isRunning { ProgressView().controlSize(.small) } else { Text(confirmTitle) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || blockedByLocalOnly || (hasFields && title.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            title = proposal.title
            note = proposal.note ?? ""
        }
    }

    private var hasFields: Bool {
        if case .dispatch = proposal.kind { return true }
        return false
    }

    private var icon: String {
        switch proposal.kind {
        case .dispatch("clickup"): "checkmark.square"
        case .dispatch("notion"): "doc.text"
        case .dispatch("reminder"): "checklist"
        case .dispatch: "arrow.triangle.branch"
        case .email: "envelope"
        case .move(let status): status.systemImage
        }
    }

    private var confirmTitle: String {
        switch proposal.kind {
        case .dispatch("clickup"): "Create Task"
        case .dispatch("notion"): "Add to Notion"
        case .dispatch("reminder"): "Add Reminder"
        case .dispatch: "Send"
        case .email: "Open in Mail"
        case .move: "Move"
        }
    }

    private func run() {
        let item = pending.item
        let meeting = pending.meeting
        switch proposal.kind {
        case .move(let status):
            item.boardStatus = status
            try? modelContext.save()
            dismiss()
        case .email:
            MeetingAttendeeContext.currentUserName = settings.displayName
            let signals = MeetingSignals(meeting)
            let draft = FollowUpPlanner.itemDraft(
                itemTitle: item.title,
                meeting: signals,
                context: ProjectSuggester.Context.build([signals]),
                senderName: settings.displayName
            )
            MailComposer.open(to: draft.recipients.compactMap(\.email), subject: draft.subject, body: draft.body)
            dismiss()
        case .dispatch(let destination):
            isRunning = true
            errorMessage = nil
            let itemID = item.id
            let meetingTitle = meeting.title
            Task { @MainActor in
                defer { isRunning = false }
                guard LiveModel.actionItemExists(itemID, in: modelContext) else { dismiss(); return }
                do {
                    // The only path that sends: the user pressed Confirm.
                    try await AgentDispatch.confirmAndDispatch(
                        destination: destination,
                        actionItemID: itemID,
                        meetingTitle: meetingTitle,
                        title: title,
                        note: note,
                        settings: settings,
                        eventKitManager: eventKitManager,
                        modelContext: modelContext
                    )
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
