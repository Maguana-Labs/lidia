import AppKit
import SwiftData
import SwiftUI

/// Every meeting: fast search, filters (people, company, source, date),
/// recurring meetings grouped into series, and keyboard navigation
/// (arrows move, Return opens, ⌘F searches).
struct MeetingsLibraryView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @Bindable var nav: NavigationState
    var onRetryMeeting: (Meeting) -> Void
    var onDeleteMeeting: (Meeting) -> Void
    var onAsk: (String) -> Void

    @State private var filter = MeetingLibraryFilter()
    @AppStorage("library.groupSeries") private var groupSeries = true
    @State private var selection: String?
    @State private var attendeeCache: [UUID: [MeetingAttendee]] = [:]
    @FocusState private var searchFocused: Bool
    @State private var intelligence = IntelligenceResults.empty

    var body: some View {
        Group {
            if let key = nav.librarySeriesKey, let series = series(for: key) {
                MeetingSeriesView(
                    series: series,
                    everyone: unionAttendees(series.items),
                    onBack: { nav.librarySeriesKey = nil },
                    onOpen: { open($0) },
                    onAsk: onAsk
                )
            } else {
                library
            }
        }
        .navigationTitle(nav.librarySeriesKey == nil ? "Meetings" : "Series")
        .onAppear {
            MeetingAttendeeContext.currentUserName = settings.displayName
            #if DEBUG
            MainWindowSnapshotDriver.shared?.libraryFilter = { filter = $0 }
            #endif
        }
        .intelligence(meetings: meetings, results: $intelligence)
        .task(id: meetings.count) {
            MeetingAttendeeContext.currentUserName = settings.displayName
            attendeeCache = Dictionary(meetings.map { ($0.id, $0.libraryAttendees) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Data

    private func attendees(of meeting: Meeting) -> [MeetingAttendee] {
        if let cached = attendeeCache[meeting.id] { return cached }
        return meeting.libraryAttendees
    }

    private var filtered: [Meeting] {
        let now = Date.now
        return meetings.filter { filter.matches($0, now: now) }
    }

    private var entries: [MeetingLibraryEntry<Meeting>] {
        // Searching shows matching meetings one by one.
        MeetingLibraryModel.entries(filtered, groupSeries: groupSeries && filter.query.isEmpty)
    }

    private func series(for key: String) -> MeetingSeries<Meeting>? {
        MeetingLibraryModel.series(meetings).first { $0.key == key }
    }

    private var allAttendees: [MeetingAttendee] {
        var seen: [String: (MeetingAttendee, Int)] = [:]
        for meeting in meetings {
            for attendee in attendees(of: meeting) where !attendee.isCurrentUser {
                seen[attendee.id, default: (attendee, 0)].1 += 1
            }
        }
        return seen.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }.map(\.0)
    }

    private var allCompanies: [String] {
        var counts: [String: Int] = [:]
        let userCompany = meetings.lazy.compactMap { meeting in
            self.attendees(of: meeting).first(where: \.isCurrentUser)?.company
        }.first
        for meeting in meetings {
            for company in Set(attendees(of: meeting).compactMap(\.company)) { counts[company, default: 0] += 1 }
        }
        return counts.keys.sorted { lhs, rhs in
            if (lhs == userCompany) != (rhs == userCompany) { return rhs == userCompany }
            return counts[lhs]! != counts[rhs]! ? counts[lhs]! > counts[rhs]! : lhs < rhs
        }
    }

    // MARK: - Library

    private var library: some View {
        let entries = entries
        let sections = MeetingLibraryModel.sections(entries, date: \.date)
        return VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(sections, id: \.label) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                row(entry).tag(entry.id)
                            }
                        } header: {
                            Text(section.label)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let meeting = meeting(forEntryID: id) {
                        MeetingRowContextMenu(meeting: meeting, onRetry: onRetryMeeting, onDelete: onDeleteMeeting)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { activate(id) }
                }
                .onChange(of: selection) { _, id in
                    // A click opens at once; arrow keys only move the selection
                    // (Return opens).
                    guard let id, let event = NSApp.currentEvent,
                          [.leftMouseDown, .leftMouseUp].contains(event.type) else { return }
                    activate(id)
                }
            }
        }
        .background(alignment: .topLeading) { shortcuts }
    }

    private var shortcuts: some View {
        Button("Find") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func row(_ entry: MeetingLibraryEntry<Meeting>) -> some View {
        switch entry {
        case .meeting(let meeting):
            LibraryMeetingRow(
                meeting: meeting,
                attendees: attendees(of: meeting),
                suggestion: meeting.projectName == nil ? intelligence.projectSuggestions[meeting.id] : nil,
                onAccept: { accept($0, for: [meeting.id]) },
                onReject: { IntelligenceStore.shared.rejectProject($0.project, for: [meeting.id]) }
            )
        case .series(let series):
            let unassigned = series.items.filter { $0.projectName == nil }.map(\.id)
            LibrarySeriesRow(
                series: series,
                attendees: unionAttendees(series.items),
                suggestion: unassigned.isEmpty ? nil : intelligence.seriesSuggestion(for: unassigned),
                onAccept: { accept($0, for: unassigned) },
                onReject: { IntelligenceStore.shared.rejectProject($0.project, for: unassigned) }
            )
        }
    }

    private func accept(_ suggestion: ProjectSuggester.Suggestion, for ids: [UUID]) {
        withAnimation {
            IntelligenceEngine.assign(ids, to: suggestion.project, in: meetings, store: .shared, context: modelContext)
        }
    }

    private func unionAttendees(_ items: [Meeting]) -> [MeetingAttendee] {
        AttendeeParser.parse(items.flatMap { $0.calendarAttendees ?? [] }, currentUserName: settings.displayName)
    }

    private func meeting(forEntryID id: String) -> Meeting? {
        guard id.hasPrefix("meeting:"), let uuid = UUID(uuidString: String(id.dropFirst(8))) else { return nil }
        return meetings.first { $0.id == uuid }
    }

    private func activate(_ id: String) {
        if id.hasPrefix("series:") {
            nav.librarySeriesKey = String(id.dropFirst(7))
            selection = nil
        } else if let meeting = meeting(forEntryID: id) {
            open(meeting)
        }
    }

    private func open(_ meeting: Meeting) {
        nav.show(meeting)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                searchField
                Toggle(isOn: $groupSeries) {
                    Label("Group Series", systemImage: "square.stack")
                }
                .toggleStyle(.button)
                .help("Show recurring meetings as one series")
            }
            HStack(spacing: 6) {
                peopleMenu
                companyMenu
                sourceMenu
                dateMenu
                if filter.hasFilters {
                    Button("Clear") {
                        let query = filter.query
                        filter = MeetingLibraryFilter()
                        filter.query = query
                    }
                    .buttonStyle(.accentLink)
                    .font(.callout)
                    .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                Text(countText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var countText: String {
        let count = filtered.count
        if filter.isActive { return "\(count) of \(meetings.count)" }
        return "\(count) meeting\(count == 1 ? "" : "s")"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search titles, people, notes", text: $filter.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    filter.query = ""
                    return .handled
                }
                .accessibilityLabel("Search meetings")
            if !filter.query.isEmpty {
                Button {
                    filter.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: searchFocused ? 1.5 : 0.5)
        }
    }

    private var peopleMenu: some View {
        LibraryFilterMenu(title: "People", systemImage: "person", activeCount: filter.people.count) {
            let people = allAttendees
            if people.isEmpty { Text("No people yet") }
            ForEach(people.prefix(40)) { person in
                Toggle(isOn: binding(for: person.id, in: \.people)) {
                    Text(person.company.map { "\(person.name) · \($0)" } ?? person.name)
                }
            }
        }
    }

    private var companyMenu: some View {
        LibraryFilterMenu(title: "Company", systemImage: "building.2", activeCount: filter.companies.count) {
            let companies = allCompanies
            if companies.isEmpty { Text("No companies yet") }
            ForEach(companies, id: \.self) { company in
                Toggle(company, isOn: binding(for: company, in: \.companies))
            }
        }
    }

    private var sourceMenu: some View {
        LibraryFilterMenu(title: "Source", systemImage: "tray", activeCount: filter.sources.count) {
            ForEach(MeetingSource.allCases) { source in
                Toggle(isOn: Binding(
                    get: { filter.sources.contains(source) },
                    set: { on in if on { filter.sources.insert(source) } else { filter.sources.remove(source) } }
                )) {
                    Label(sourceTitle(source), systemImage: source.systemImage)
                }
            }
        }
    }

    private func sourceTitle(_ source: MeetingSource) -> String {
        guard source == .imported else { return source.title }
        let names = Set(meetings.compactMap { MeetingSource.importerName($0.externalSourceID) })
        return names.count == 1 ? "Imported from \(names.first!)" : "Imported"
    }

    private var dateMenu: some View {
        LibraryFilterMenu(
            title: filter.dateRange == .any ? "Date" : filter.dateRange.title,
            systemImage: "calendar",
            activeCount: filter.dateRange == .any ? 0 : 1,
            showsCount: false
        ) {
            Picker("Date", selection: $filter.dateRange) {
                ForEach(MeetingDateRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func binding(for value: String, in keyPath: WritableKeyPath<MeetingLibraryFilter, Set<String>>) -> Binding<Bool> {
        Binding(
            get: { filter[keyPath: keyPath].contains(value) },
            set: { on in
                if on { filter[keyPath: keyPath].insert(value) } else { filter[keyPath: keyPath].remove(value) }
            }
        )
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        if meetings.isEmpty {
            ContentUnavailableView {
                Label("No Meetings Yet", systemImage: "rectangle.stack")
            } description: {
                Text("Record a meeting with ⌘R, write a note with ⌘N, or import your Granola notes from Settings › Import.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("No meetings match these filters.")
            } actions: {
                Button("Clear Search and Filters") { filter = MeetingLibraryFilter() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Filter menu

/// A filter pill: icon, title, and a count when active.
private struct LibraryFilterMenu<Content: View>: View {
    let title: String
    let systemImage: String
    let activeCount: Int
    var showsCount = true
    @ViewBuilder let content: () -> Content

    private var isActive: Bool { activeCount > 0 }

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                Text(showsCount && isActive ? "\(title) · \(activeCount)" : title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background(isActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(isActive ? "\(title) filter, \(activeCount) selected" : "\(title) filter")
    }
}

// MARK: - Rows

/// Calendar-style date tile: weekday over day number.
struct MeetingDateTile: View {
    let date: Date

    var body: some View {
        VStack(spacing: -1) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 17, weight: .medium).monospacedDigit())
        }
        .frame(width: 34, height: 34)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct LibraryMeetingRow: View {
    let meeting: Meeting
    let attendees: [MeetingAttendee]
    var suggestion: ProjectSuggester.Suggestion?
    var onAccept: (ProjectSuggester.Suggestion) -> Void = { _ in }
    var onReject: (ProjectSuggester.Suggestion) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            MeetingDateTile(date: meeting.date)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title.isEmpty ? "Untitled" : meeting.title.trimmingCharacters(in: .whitespaces))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let project = meeting.projectName {
                ProjectLabel(name: project)
            } else if let suggestion {
                ProjectSuggestionChip(
                    suggestion: suggestion,
                    onAccept: { onAccept(suggestion) },
                    onReject: { onReject(suggestion) }
                )
            }
            MeetingStatusBadge(status: meeting.status)
            if attendees.count > 1 {
                AttendeeAvatarStack(attendees: attendees, maxVisible: 3, size: 20)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meeting.title.isEmpty ? "Untitled" : meeting.title), \(detail)")
    }

    private var detail: String {
        var parts: [String] = [meeting.date.formatted(date: .omitted, time: .shortened)]
        if let duration = MeetingRowFormat.duration(meeting.duration) { parts.append(duration) }
        if let who = MeetingRowFormat.withWhom(attendees) { parts.append(who) }
        switch meeting.librarySource {
        case .note: parts.append("Note")
        case .imported: if let name = MeetingSource.importerName(meeting.externalSourceID) { parts.append(name) }
        case .recorded: break
        }
        return parts.joined(separator: " · ")
    }
}

struct LibrarySeriesRow: View {
    let series: MeetingSeries<Meeting>
    let attendees: [MeetingAttendee]
    var suggestion: ProjectSuggester.Suggestion?
    var onAccept: (ProjectSuggester.Suggestion) -> Void = { _ in }
    var onReject: (ProjectSuggester.Suggestion) -> Void = { _ in }

    private var project: String? {
        let projects = Set(series.items.compactMap(\.projectName))
        return projects.count == 1 ? projects.first : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .offset(x: 3, y: -3)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay {
                        Text("\(series.count)")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
            }
            .frame(width: 31, height: 31)
            .padding(.top, 3)
            .padding(.trailing, 3)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(series.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let suggestion {
                ProjectSuggestionChip(
                    suggestion: suggestion,
                    onAccept: { onAccept(suggestion) },
                    onReject: { onReject(suggestion) }
                )
            } else if let project {
                ProjectLabel(name: project)
            }
            if attendees.count > 1 {
                AttendeeAvatarStack(attendees: attendees, maxVisible: 3, size: 20)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Series: \(series.title), \(detail)")
        .accessibilityHint("Opens the series timeline")
    }

    private var detail: String {
        var parts = ["\(series.count) meetings"]
        if let cadence = series.cadence { parts.append(cadence) }
        parts.append("Latest \(MeetingRowFormat.relativeDay(series.latestDate))")
        if let who = MeetingRowFormat.withWhom(attendees) { parts.append(who) }
        return parts.joined(separator: " · ")
    }
}
