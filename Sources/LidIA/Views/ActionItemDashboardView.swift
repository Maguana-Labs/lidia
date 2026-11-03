import SwiftData
import SwiftUI

struct ActionItemDashboardView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    /// Observed directly (not cached): an item deleted elsewhere (MCP inbox, voice
    /// assistant, sync, Regenerate) leaves this query before any row can read it.
    @Query private var actionItems: [ActionItem]
    @Binding var selectedMeeting: Meeting?

    @AppStorage("actionItems.showCompleted") private var showCompleted = false
    @AppStorage("actionItems.showMyItemsOnly") private var showMyItemsOnly = true
    @AppStorage("actionItems.priorityFilter") private var priorityFilter = "all"
    @AppStorage("actionItems.layout") private var layout = "board"
    @AppStorage("actionItems.boardGrouping") private var boardGrouping: ActionItemBoardGrouping = .none
    @AppStorage("actionItems.showWaiting") private var showWaiting = true
    @State private var filterText = ""
    @State private var isSyncingToNotion = false
    @State private var alertTitle: String = "Action Items"
    @State private var alertMessage: String?
    @State private var hoveredItemID: UUID?
    @State private var isDispatching = false
    @State private var newActionItemTitle = ""
    @State private var intentSheet: IntentSheetItem?

    /// Intents for the open items of recent meetings (older ones on demand).
    private func refreshIntents() {
        let cutoff = Date.now.addingTimeInterval(-45 * 86_400)
        var ids: [UUID] = []
        for (item, meeting) in filtered(includeCompleted: false) where !item.isCompleted && meeting.date >= cutoff && !ids.contains(meeting.id) {
            ids.append(meeting.id)
        }
        IntentRuntime.refresh(
            meetingIDs: ids, settings: settings, modelManager: modelManager,
            eventKit: eventKitManager, google: googleCalendarMonitor, modelContext: modelContext
        )
    }

    /// Action items of complete meetings, newest meeting first.
    static func rows(from items: [ActionItem]) -> [(ActionItem, Meeting)] {
        items
            .compactMap { item in
                guard let meeting = item.meeting, meeting.status == .complete else { return nil }
                return (item, meeting)
            }
            .sorted { $0.1.date > $1.1.date }
    }

    private var isBoard: Bool { layout == "board" }

    private var filteredItems: [(ActionItem, Meeting)] { filtered(includeCompleted: showCompleted) }

    /// The board always shows Done; the list hides completed items unless asked.
    private func filtered(includeCompleted: Bool) -> [(ActionItem, Meeting)] {
        Self.rows(from: actionItems).filter { item, meeting in
            if item.isDeleted { return false }
            if !includeCompleted && item.isCompleted { return false }
            if priorityFilter == "urgent" && !item.isUrgent { return false }
            if priorityFilter != "all" && priorityFilter != "urgent" && item.priority != priorityFilter { return false }
            if showMyItemsOnly {
                let displayName = settings.displayName
                let assigneeIsMe = item.assignee?.localizedStandardContains(displayName) ?? false
                let assigneeIsEmpty = item.assignee?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
                if !assigneeIsMe && !assigneeIsEmpty { return false }
            }
            if !filterText.isEmpty {
                let titleMatch = item.title.localizedStandardContains(filterText)
                let personMatch = item.assignee?.localizedStandardContains(filterText) ?? false
                let meetingMatch = meeting.title.localizedStandardContains(filterText)
                let attendeeMatch = meeting.calendarAttendees?.contains(where: {
                    $0.localizedStandardContains(filterText)
                }) ?? false
                if !titleMatch && !personMatch && !meetingMatch && !attendeeMatch { return false }
            }
            return true
        }
        .sorted { a, b in
            if a.0.priorityLevel != b.0.priorityLevel { return a.0.priorityLevel > b.0.priorityLevel }
            if a.0.isUrgent != b.0.isUrgent { return a.0.isUrgent }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("Layout", selection: $layout) {
                    Label("Board", systemImage: "square.grid.3x1.below.line.grid.1x2").tag("board")
                    Label("List", systemImage: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .fixedSize()
                .help("Show action items as a board or a list")

                Picker("Show", selection: $showMyItemsOnly) {
                    Text("Mine").tag(true)
                    Text("Everyone").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show items assigned to you, or everyone's")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TextField("Search action items", text: $filterText)
                        .accessibilityLabel("Filter action items")
                        .textFieldStyle(.plain)
                    if !filterText.isEmpty {
                        Button { filterText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter")
                        .help("Clear filter")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
                .frame(maxWidth: 260)

                Menu {
                    if isBoard {
                        Picker("Group By", selection: $boardGrouping) {
                            ForEach(ActionItemBoardGrouping.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Toggle("Waiting Column", isOn: $showWaiting)
                    } else {
                        Toggle("Show Completed", isOn: $showCompleted)
                    }
                    Divider()
                    Picker("Priority", selection: $priorityFilter) {
                        Text("Any Priority").tag("all")
                        Text("Urgent").tag("urgent")
                        Divider()
                        Text("Critical").tag("critical")
                        Text("High").tag("high")
                        Text("Medium").tag("medium")
                        Text("Low").tag("low")
                    }
                    .pickerStyle(.inline)
                    if isFiltered {
                        Divider()
                        Button("Reset Filters") {
                            showCompleted = false
                            priorityFilter = "all"
                        }
                    }
                } label: {
                    Label("Filter", systemImage: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show completed items or filter by priority")

                Spacer(minLength: 8)

                Text("\(openCount) open")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if canSendToNotion || !confirmedItems.isEmpty {
                    Menu {
                        if !confirmedItems.isEmpty {
                            Button("Send \(confirmedItems.count) Confirmed \(confirmedItems.count == 1 ? "Item" : "Items")") {
                                Task { await dispatchConfirmedItems() }
                            }
                            .disabled(isDispatching)
                        }
                        if canSendToNotion {
                            Button("Send \(filteredItems.count) Shown to Notion") {
                                Task { await syncVisibleItemsToNotion() }
                            }
                            .disabled(isSyncingToNotion || filteredItems.isEmpty)
                        }
                    } label: {
                        if isDispatching || isSyncingToNotion {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Send", systemImage: "paperplane")
                        }
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(settings.localOnlyMode)
                    .help(settings.localOnlyMode
                          ? "Sending is off in Local-only mode"
                          : "Send action items to Notion, Reminders or your other destinations")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if isBoard {
                ActionItemBoardView(
                    rows: filtered(includeCompleted: true),
                    grouping: boardGrouping,
                    showWaiting: showWaiting,
                    onOpenMeeting: { selectedMeeting = $0 },
                    onDelete: { item, meeting in deleteActionItem(item, from: meeting) }
                )
            } else {
                list
            }
        }
        .navigationTitle("Action Items")
        .task(id: IntentRuntime.fingerprint(filtered(includeCompleted: false))) { refreshIntents() }
        #if DEBUG
        .onAppear { MainWindowSnapshotDriver.shared?.actionItemsFilter = { filterText = $0 } }
        #endif
        .sheet(item: $intentSheet) { sheet in
            IntentConfirmSheet(intent: sheet.intent, item: sheet.item, meeting: sheet.meeting)
        }
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var list: some View {
            List {
                ForEach(filteredItems, id: \.0.id) { item, meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        EditableActionItemRow(
                            item: item,
                            meetingTitle: meeting.title,
                            onSelectMeeting: {
                                selectedMeeting = meeting
                            },
                            onDelete: {
                                deleteActionItem(item, from: meeting)
                            }
                        )
                        if !item.isCompleted {
                            IntentSummaryView(
                                item: item, meeting: meeting, compact: true,
                                onDismissItem: { deleteActionItem(item, from: meeting) },
                                onOpen: { intentSheet = IntentSheetItem(intent: $0, item: item, meeting: meeting) }
                            )
                            .padding(.leading, 34)
                            .padding(.bottom, 4)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    .listRowSeparator(.hidden)
                    .background {
                        if hoveredItemID == item.id {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.clear)
                                .glassEffect(.regular, in: .rect(cornerRadius: 6))
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            hoveredItemID = hovering ? item.id : nil
                        }
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.title3)

                    TextField("Add action item...", text: $newActionItemTitle)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .onSubmit {
                            addActionItem()
                        }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if filteredItems.isEmpty && newActionItemTitle.isEmpty {
                    ContentUnavailableView(
                        "No Action Items",
                        systemImage: "checkmark.circle",
                        description: Text(filterText.isEmpty ? "Add one above, or record a meeting and LidIA picks them out for you." : "No action items match \u{201C}\(filterText)\u{201D}.")
                    )
                }
            }
    }

    private var isFiltered: Bool { showCompleted || priorityFilter != "all" }

    private var openCount: Int { filteredItems.filter { !$0.0.isCompleted }.count }

    private var canSendToNotion: Bool {
        !settings.notionAPIKey.isEmpty && !settings.notionTasksDatabaseID.isEmpty
    }

    private var confirmedItems: [(ActionItem, Meeting)] {
        filteredItems.filter { $0.0.confirmedDestination != nil && !$0.0.isCompleted }
    }

    private func addActionItem() {
        let trimmed = newActionItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Attach to most recent completed meeting, or create a standalone one
        let targetMeeting: Meeting
        if let recent = meetings.first(where: { $0.status == .complete }) {
            targetMeeting = recent
        } else {
            let standalone = Meeting(title: "Action Items", date: .now)
            standalone.status = .complete
            modelContext.insert(standalone)
            targetMeeting = standalone
        }

        let newItem = ActionItem(title: trimmed)
        newItem.meeting = targetMeeting
        targetMeeting.actionItems.append(newItem)
        try? modelContext.save()
        newActionItemTitle = ""
    }

    private func deleteActionItem(_ item: ActionItem, from meeting: Meeting) {
        meeting.actionItems.removeAll { $0.id == item.id }
        modelContext.delete(item)
        try? modelContext.save()
    }

    @MainActor
    private func dispatchConfirmedItems() async {
        isDispatching = true
        defer { isDispatching = false }

        var successCount = 0
        var failCount = 0
        for (item, meeting) in confirmedItems {
            guard let destination = item.confirmedDestination else { continue }
            do {
                try await ActionItemDispatcher.dispatch(
                    item: item,
                    meetingTitle: meeting.title,
                    destination: destination,
                    settings: settings,
                    eventKitManager: eventKitManager,
                    modelContext: modelContext
                )
                successCount += 1
            } catch {
                failCount += 1
            }
        }

        alertTitle = "Dispatch"
        if successCount > 0 || failCount > 0 {
            var msg = "Dispatched \(successCount) action items."
            if failCount > 0 { msg += " \(failCount) failed." }
            alertMessage = msg
        }
    }

    @MainActor
    private func syncVisibleItemsToNotion() async {
        isSyncingToNotion = true
        defer { isSyncingToNotion = false }

        do {
            let result = try await ActionItemNotionSyncService.sync(
                targets: filteredItems.map {
                    ActionItemNotionSyncService.SyncTarget(
                        item: $0.0,
                        meetingTitle: $0.1.title.isEmpty ? "Untitled" : $0.1.title
                    )
                },
                settings: settings,
                modelContext: modelContext
            )
            alertTitle = "Notion Export"
            alertMessage = result.updatedCount > 0
                ? "Synced \(result.syncedCount) action items to Notion (\(result.createdCount) created, \(result.updatedCount) updated)."
                : "Sent \(result.syncedCount) action items to Notion."
        } catch {
            alertTitle = "Notion Export"
            alertMessage = error.localizedDescription
        }
    }
}
