import LidIAKit
import SwiftData
import SwiftUI

/// Every commitment, grouped by when it's due. Swipe right to complete.
struct ActionItemsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open"
        case mine = "Mine"
        case done = "Done"
        var id: String { rawValue }
    }

    @Environment(AppRouter.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query private var items: [ActionItem]
    @State private var filter: Filter = .open

    private var filtered: [ActionItem] {
        switch filter {
        case .open: return items.filter { !$0.isCompleted }
        case .done: return items.filter(\.isCompleted)
        case .mine:
            return items.filter { item in
                guard !item.isCompleted else { return false }
                guard let owner = item.assignee, !owner.isEmpty else { return true }
                return ActionItemRow.isMe(owner, settings: settings)
            }
        }
    }

    private var groups: [(due: ActionItem.Due, items: [ActionItem])] {
        if filter == .done {
            let sorted = filtered.sorted { ($0.meeting?.date ?? .distantPast) > ($1.meeting?.date ?? .distantPast) }
            return sorted.isEmpty ? [] : [(.none, sorted)]
        }
        return Dictionary(grouping: filtered, by: \.due)
            .map { (due: $0.key, items: $0.value.sorted { ($0.deadlineDate ?? .distantFuture, $0.title) < ($1.deadlineDate ?? .distantFuture, $1.title) }) }
            .sorted { $0.due < $1.due }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .sensoryFeedback(.selection, trigger: filter)
            }

            if groups.isEmpty {
                Section {
                    CardEmptyState(
                        symbol: filter == .done ? "checkmark.circle" : "sparkles",
                        title: filter == .done ? "Nothing done yet" : "You’re all caught up",
                        message: filter == .done ? "Swipe an item right to complete it." : "Commitments from your meetings land here, with who owns them and when they’re due."
                    )
                }
            }

            ForEach(groups, id: \.due) { group in
                Section {
                    ForEach(group.items) { item in
                        ActionItemRow(item: item) {
                            ActionItemActions.toggle(item, context: context, toasts: toasts, sync: sync)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .contentShape(.rect)
                        .onTapGesture { router.actionItemDetail = .init(id: item.id) }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                ActionItemActions.toggle(item, context: context, toasts: toasts, sync: sync)
                            } label: {
                                Label(item.isCompleted ? "Reopen" : "Done", systemImage: item.isCompleted ? "arrow.uturn.backward" : "checkmark")
                            }
                            .tint(item.isCompleted ? .gray : .green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                snooze(item)
                            } label: {
                                Label("Tomorrow", systemImage: "moon.zzz")
                            }
                            .tint(.indigo)
                        }
                    }
                } header: {
                    if filter != .done {
                        HStack {
                            Text(group.due.title)
                            Spacer()
                            Text("\(group.items.count)")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(group.due == .overdue ? .red : .secondary)
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .background(Surface.background)
        .navigationTitle("Action items")
        .animation(.snappy, value: filter)
        .refreshable { await sync.syncNow() }
    }

    private func snooze(_ item: ActionItem) {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        item.setPreciseDeadline(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow))
        try? context.save()
        sync.push(item)
        toasts.show("Moved to tomorrow", symbol: "moon.zzz.fill", style: .info)
    }
}

/// An action item as a sheet: the item is the hero, two big actions, a
/// grouped details list with copy actions.
struct ActionItemDetailSheet: View {
    let itemID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppRouter.self) private var router
    @Query private var matches: [ActionItem]
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var pickingDate = false

    init(itemID: UUID) {
        self.itemID = itemID
        _matches = Query(filter: #Predicate<ActionItem> { $0.id == itemID })
    }

    var body: some View {
        NavigationStack {
            if let item = matches.first {
                content(item)
            } else {
                ContentUnavailableView("Item not found", systemImage: "checklist")
            }
        }
    }

    private func content(_ item: ActionItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hero: the commitment itself.
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Chip(text: item.isCompleted ? "Done" : (item.dueLabel ?? "No date"), symbol: item.isCompleted ? "checkmark" : "calendar", tint: item.isCompleted ? .green : item.dueTint == .secondary ? .accentColor : item.dueTint)
                        Spacer()
                        if let assignee = item.assignee, !assignee.isEmpty {
                            PersonAvatar(name: assignee, size: 30)
                        }
                    }
                    Text(item.title)
                        .font(.title2.weight(.bold))
                        .strikethrough(item.isCompleted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let meeting = item.meeting {
                        Label("From \(meeting.displayTitle) · \(Format.day(meeting.date))", systemImage: "rectangle.stack")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.card, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))

                HStack(spacing: 12) {
                    ActionTile(
                        title: item.isCompleted ? "Reopen" : "Mark done",
                        symbol: item.isCompleted ? "arrow.uturn.backward" : "checkmark",
                        tint: .green
                    ) {
                        ActionItemActions.toggle(item, context: context, toasts: toasts, sync: sync)
                        if item.isCompleted { dismiss() }
                    }
                    ActionTile(title: "Due date", symbol: "calendar", tint: .orange) {
                        pickingDate.toggle()
                    }
                }

                if pickingDate {
                    DatePicker(
                        "Due",
                        selection: Binding(
                            get: { item.deadlineDate ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)! },
                            set: { item.setPreciseDeadline($0); try? context.save(); sync.push(item) }
                        ),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .padding(12)
                    .background(Surface.card, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Details")
                    Card {
                        DetailRow(label: "Task", value: item.title, actionTitle: "Copy") {
                            UIPasteboard.general.string = item.title
                            toasts.show("Task copied to clipboard")
                        }
                        RowDivider(leading: 16)
                        DetailRow(label: "Owner", value: item.assignee?.isEmpty == false ? item.assignee! : "Unassigned")
                        RowDivider(leading: 16)
                        DetailRow(label: "Due", value: item.displayDeadline ?? "No date")
                        if let quote = item.sourceQuote, !quote.isEmpty {
                            RowDivider(leading: 16)
                            DetailRow(label: "What was said", value: "“\(quote)”", actionTitle: "Copy") {
                                UIPasteboard.general.string = quote
                                toasts.show("Quote copied to clipboard")
                            }
                        }
                        if let meeting = item.meeting {
                            RowDivider(leading: 16)
                            DetailRow(label: "Meeting", value: meeting.displayTitle, actionTitle: "Open") {
                                dismiss()
                                router.open(meeting.id)
                            }
                        }
                    }
                }
            }
            .padding(Metrics.gutter)
            .animation(.snappy, value: pickingDate)
        }
        .background(Surface.background)
        .navigationTitle("Action item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit task", systemImage: "pencil") {
                        draftTitle = item.title
                        editingTitle = true
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        sync.deleteActionItem(id: item.id)
                        context.delete(item)
                        try? context.save()
                        dismiss()
                        toasts.show("Action item deleted", symbol: "trash.fill", style: .info)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .alert("Edit task", isPresented: $editingTitle) {
            TextField("Task", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                item.title = trimmed
                try? context.save()
                sync.push(item)
                toasts.show("Saved")
            }
        }
    }
}
