import SwiftUI
import SwiftData

/// The app's sidebar: a pinned Now row, the main destinations, anything that
/// needs attention, and the five most recent meetings. The whole history
/// lives in the Meetings library. When the toolbar search has text, the list
/// is replaced by search results.
struct SidebarView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted }) private var openActionItems: [ActionItem]
    @Environment(RecordingSession.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var showsNewProject = false
    @State private var newProjectName = ""

    @Bindable var nav: NavigationState
    let agenda: [AgendaEvent]

    var onRecordEvent: (AgendaEvent, _ join: Bool) -> Void
    var onRecordNow: () -> Void
    var onStopRecording: () -> Void
    var onDeleteMeeting: (Meeting) -> Void
    var onRetryMeeting: (Meeting) -> Void
    var onAsk: (String) -> Void

    static let recentLimit = 5

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                // A meeting opened from the library that isn't listed here
                // keeps "Meetings" highlighted.
                if case .meeting(let id) = nav.sidebarSelection,
                   !visibleMeetingIDs.contains(id),
                   nav.meetingReturnDestination == .library {
                    return .library
                }
                return nav.sidebarSelection
            },
            set: { newValue in
                guard let newValue else { return }
                select(newValue)
            }
        )
    }

    private var attention: [Meeting] {
        MeetingListModel.attentionItems(meetings)
    }

    private var recent: [Meeting] {
        Array(meetings.lazy
            .filter { !MeetingListModel.needsAttention($0.status) && $0.status != .recording }
            .prefix(Self.recentLimit))
    }

    /// Projects from meetings plus the ones the user created, newest activity first.
    private var projects: [ProjectCatalog.Summary] {
        var byKey: [String: ProjectCatalog.Summary] = [:]
        for meeting in meetings where !meeting.isDeleted {
            guard let name = meeting.projectName else { continue }
            let key = ProjectCatalog.fold(name)
            var summary = byKey[key] ?? ProjectCatalog.Summary(name: name, meetingCount: 0, lastDate: nil)
            summary.meetingCount += 1
            if summary.lastDate.map({ meeting.date > $0 }) ?? true { summary.lastDate = meeting.date }
            byKey[key] = summary
        }
        for name in IntelligenceStore.shared.state.knownProjects where byKey[ProjectCatalog.fold(name)] == nil {
            byKey[ProjectCatalog.fold(name)] = ProjectCatalog.Summary(name: name, meetingCount: 0, lastDate: nil)
        }
        return byKey.values.sorted { ($0.lastDate ?? .distantPast) != ($1.lastDate ?? .distantPast)
            ? ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast)
            : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleMeetingIDs: Set<UUID> {
        Set(attention.map(\.id) + recent.map(\.id))
    }

    var body: some View {
        Group {
            if nav.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                mainList
            } else {
                SearchResultsView(
                    query: nav.searchText,
                    meetings: meetings,
                    actionItems: openActionItems,
                    onSelectMeeting: { nav.show($0) },
                    onSelectPerson: { personID in
                        nav.show(.people)
                        nav.detailPath.append(personID)
                    },
                    onOpenActionItems: { nav.show(.actionItems) },
                    onAsk: onAsk
                )
            }
        }
    }

    // MARK: - Main list

    private var mainList: some View {
        List(selection: selection) {
            Section {
                NowRow(
                    agenda: agenda,
                    onOpenRecording: {
                        if let meeting = session.currentMeeting { nav.show(meeting) }
                    },
                    onOpenEvent: { nav.show($0) },
                    onRecordEvent: onRecordEvent,
                    onRecordNow: onRecordNow,
                    onStop: onStopRecording
                )
                .selectionDisabled()
            }

            Section {
                Label("Today", systemImage: "sun.max")
                    .tag(SidebarSelection.today)
                Label("Meetings", systemImage: "rectangle.stack")
                    .tag(SidebarSelection.library)
                Label("Action Items", systemImage: "checklist")
                    .badge(openActionItems.count)
                    .tag(SidebarSelection.actionItems)
                Label("People", systemImage: "person.2")
                    .tag(SidebarSelection.people)
                Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    .tag(SidebarSelection.chats)
            }

            Section {
                ForEach(projects) { project in
                    Label {
                        Text(project.name)
                            .lineLimit(1)
                    } icon: {
                        // A shape keeps its colour; the sidebar tints symbol icons.
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(ProjectPalette.color(for: project.name).gradient)
                            .frame(width: 13, height: 11)
                            .overlay(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(ProjectPalette.color(for: project.name))
                                    .frame(width: 6, height: 3)
                                    .offset(x: 0.5, y: -2)
                            }
                            .accessibilityHidden(true)
                    }
                    .badge(project.meetingCount)
                    .tag(SidebarSelection.project(project.name))
                }
                Button {
                    newProjectName = ""
                    showsNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .help("Gather every meeting about one client or initiative")
            } header: {
                Text("Projects")
            }

            if !attention.isEmpty {
                Section("Needs Attention") {
                    ForEach(attention) { meeting in
                        meetingRow(meeting)
                    }
                }
            }

            Section("Recent") {
                if recent.isEmpty {
                    Text("Meetings you record or import show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(recent) { meeting in
                        meetingRow(meeting)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("New Project", isPresented: $showsNewProject) {
            TextField("Name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                IntelligenceStore.shared.registerProject(name)
                nav.showProject(name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A project gathers every meeting about one client or initiative, like “Northwind”. LidIA suggests meetings that belong in it.")
        }
        .onDeleteCommand {
            if case .meeting = nav.sidebarSelection, let meeting = nav.selectedMeeting {
                onDeleteMeeting(meeting)
            }
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        SidebarMeetingRow(meeting: meeting)
            .tag(SidebarSelection.meeting(meeting.id))
            .contextMenu {
                MeetingRowContextMenu(meeting: meeting, onRetry: onRetryMeeting, onDelete: onDeleteMeeting)
            }
    }

    private func select(_ selection: SidebarSelection) {
        switch selection {
        case .today: nav.showToday()
        case .library:
            nav.librarySeriesKey = nil
            nav.show(.library)
        case .actionItems: nav.show(.actionItems)
        case .people: nav.show(.people)
        case .chats: nav.show(.chat)
        case .project(let name): nav.showProject(name)
        case .meeting(let id):
            if let meeting = meetings.first(where: { $0.id == id }) {
                nav.show(meeting)
            }
        case .event(let id):
            if let event = agenda.first(where: { $0.id == id }) { nav.show(event) }
        }
    }
}

/// Context menu shared by meeting rows in the sidebar and the library.
struct MeetingRowContextMenu: View {
    let meeting: Meeting
    var onRetry: (Meeting) -> Void
    var onDelete: (Meeting) -> Void

    var body: some View {
        if meeting.status == .failed || meeting.status == .queued {
            Button("Retry Processing", systemImage: "arrow.clockwise") { onRetry(meeting) }
            Divider()
        }
        Button("Export as Markdown…", systemImage: "square.and.arrow.down") {
            ExportService.exportToFileShowingErrors(meeting)
        }
        Button("Copy as Markdown", systemImage: "doc.on.doc") {
            ExportService.copyToClipboard(ExportService.meetingToMarkdown(meeting))
        }
        Divider()
        Button("Delete Meeting…", systemImage: "trash", role: .destructive) { onDelete(meeting) }
            .disabled(meeting.status == .recording)
    }
}

// MARK: - Meeting row

/// A compact sidebar row: title, then when and with whom. A status shows
/// only while it matters (live, processing, queued, failed).
struct SidebarMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(meeting.title.isEmpty ? "Untitled" : meeting.title.trimmingCharacters(in: .whitespaces))
                    .lineLimit(1)
                Spacer(minLength: 4)
                MeetingStatusBadge(status: meeting.status)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [MeetingRowFormat.relativeDay(meeting.date)]
        if let who = MeetingRowFormat.withWhom(meeting.libraryAttendees) { parts.append(who) }
        return parts.joined(separator: " · ")
    }
}

/// Shared text for meeting rows (sidebar, library, Today).
enum MeetingRowFormat {
    /// "12:00" today, "Yesterday", "Tuesday" this week, "Oct 28", "Oct 28, 2025".
    static func relativeDay(_ date: Date, now: Date = .now, calendar: Calendar = .current, timeForToday: Bool = true) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeForToday ? date.formatted(date: .omitted, time: .shortened) : "today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return timeForToday ? "Yesterday" : "yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo, date <= now {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Leo", "Northwind", "Pinecrest, Northwind", or nil when alone.
    static func withWhom(_ attendees: [MeetingAttendee]) -> String? {
        let others = attendees.filter { !$0.isCurrentUser }
        guard !others.isEmpty else { return nil }
        if others.count == 1 { return others[0].name }
        let companies = AttendeeGrouping.externalCompanies(attendees)
        if companies.count == 1 { return companies[0] }
        if companies.count > 1 {
            return companies.prefix(2).joined(separator: ", ") + (companies.count > 2 ? " +\(companies.count - 2)" : "")
        }
        return "\(others.count) people"
    }

    /// "45 min", "1 h 5 min"; nil when unknown.
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let mins = Int(seconds) / 60
        if mins < 60 { return "\(mins) min" }
        return mins % 60 == 0 ? "\(mins / 60) h" : "\(mins / 60) h \(mins % 60) min"
    }
}
