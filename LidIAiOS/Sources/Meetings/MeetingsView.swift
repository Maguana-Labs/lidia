import LidIAKit
import SwiftData
import SwiftUI

/// Every meeting: search, projects, recurring series, then everything by day.
struct MeetingsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(SyncCoordinator.self) private var sync
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var library: [Meeting] {
        meetings.filter { $0.date <= .now.addingTimeInterval(60) }
    }

    var body: some View {
        @Bindable var router = router
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if query.isEmpty {
                    if !projects.isEmpty { projectsSection }
                    if !series.isEmpty { seriesSection }
                    daySections
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Surface.background)
        .navigationTitle("Meetings")
        .searchable(text: $query, isPresented: $router.meetingsSearchFocused, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles, notes, transcripts, people")
        .refreshable { await sync.syncNow() }
        .navigationDestination(for: ProjectRoute.self) { route in
            MeetingCollectionView(title: route.name, symbol: route.isSeries ? "arrow.triangle.2.circlepath" : "folder.fill") { meeting in
                route.isSeries ? meeting.seriesKey == route.key : meeting.folder == route.key
            }
        }
    }

    // MARK: - Projects ("pots")

    struct ProjectRoute: Hashable {
        var name: String
        var key: String
        var isSeries: Bool
    }

    private var projects: [(name: String, count: Int, last: Date)] {
        let grouped = Dictionary(grouping: library.filter { ($0.folder ?? "").isEmpty == false }, by: { $0.folder! })
        return grouped.map { (name: $0.key, count: $0.value.count, last: $0.value.map(\.date).max() ?? .distantPast) }
            .sorted { $0.last > $1.last }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Projects")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(projects, id: \.name) { project in
                        NavigationLink(value: ProjectRoute(name: project.name, key: project.name, isSeries: false)) {
                            ProjectCard(name: project.name, count: project.count, last: project.last)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    // MARK: - Series

    private var series: [(key: String, title: String, meetings: [Meeting])] {
        Dictionary(grouping: library.filter { $0.status == .complete }, by: \.seriesKey)
            .filter { $0.value.count >= 2 && !$0.key.isEmpty }
            .map { (key: $0.key, title: $0.value.first!.displayTitle, meetings: $0.value) }
            .sorted { ($0.meetings.first?.date ?? .distantPast) > ($1.meetings.first?.date ?? .distantPast) }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Series", subtitle: "Meetings that repeat")
            Card {
                let items = Array(series.prefix(4))
                ForEach(Array(items.enumerated()), id: \.element.key) { index, entry in
                    NavigationLink(value: ProjectRoute(name: entry.title, key: entry.key, isSeries: true)) {
                        HStack(spacing: 14) {
                            MeetingGlyph(symbol: "arrow.triangle.2.circlepath", tint: Tint.color(for: entry.key))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(entry.meetings.count) meetings · \(Format.day(entry.meetings.first!.date))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let open = entry.meetings.reduce(0) { $0 + $1.openItems.count }
                            if open > 0 {
                                Chip(text: "\(open) open", tint: .orange)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle())
                    if index < items.count - 1 { RowDivider() }
                }
            }
        }
    }

    // MARK: - By day

    private var dayGroups: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let monthStart = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        var groups: [(String, [Meeting])] = []
        func add(_ title: String, _ filter: (Meeting) -> Bool, from pool: inout [Meeting]) {
            let matched = pool.filter(filter)
            pool.removeAll(where: filter)
            if !matched.isEmpty { groups.append((title, matched)) }
        }
        var pool = library
        add("Today", { calendar.isDateInToday($0.date) }, from: &pool)
        add("Yesterday", { calendar.isDateInYesterday($0.date) }, from: &pool)
        add("Earlier this week", { $0.date >= weekStart }, from: &pool)
        add("Earlier this month", { $0.date >= monthStart }, from: &pool)
        let byMonth = Dictionary(grouping: pool) { calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
        for month in byMonth.keys.sorted(by: >) {
            groups.append((month.formatted(.dateTime.month(.wide).year()), byMonth[month] ?? []))
        }
        return groups
    }

    @ViewBuilder
    private var daySections: some View {
        if library.isEmpty {
            Card {
                CardEmptyState(
                    symbol: "rectangle.stack",
                    title: "Your meetings live here",
                    message: "Record in person with the red button, or turn on sync in Settings to bring in the meetings from your Mac."
                )
            }
            .padding(.top, 12)
        }
        ForEach(dayGroups, id: \.title) { group in
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: group.title)
                Card {
                    ForEach(Array(group.meetings.enumerated()), id: \.element.id) { index, meeting in
                        NavigationLink(value: MeetingRoute(id: meeting.id)) {
                            MeetingRow(meeting: meeting, showsDay: !(Calendar.current.isDateInToday(meeting.date) || Calendar.current.isDateInYesterday(meeting.date)), timeOnly: true)
                        }
                        .buttonStyle(PressableStyle())
                        if index < group.meetings.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    // MARK: - Search

    private var matches: [Meeting] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return library.filter { meeting in
            meeting.displayTitle.localizedStandardContains(needle)
                || meeting.summaryText.localizedStandardContains(needle)
                || meeting.notes.localizedStandardContains(needle)
                || meeting.attendeeNames.contains { $0.localizedStandardContains(needle) }
                || (meeting.folder ?? "").localizedStandardContains(needle)
                || meeting.transcriptText.localizedStandardContains(needle)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = matches
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: results.isEmpty ? "No matches" : "\(results.count) meeting\(results.count == 1 ? "" : "s")")
            if results.isEmpty {
                Card {
                    CardEmptyState(symbol: "magnifyingglass", title: "Nothing for “\(query)”", message: "Try a name, a project or a word someone said. Or ask LidIA.")
                    Button {
                        router.askSheet = .init(meetingID: nil, meetingTitle: nil)
                    } label: {
                        Label("Ask LidIA instead", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .padding([.horizontal, .bottom], 16)
                }
            } else {
                Card {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, meeting in
                        NavigationLink(value: MeetingRoute(id: meeting.id)) {
                            VStack(alignment: .leading, spacing: 0) {
                                MeetingRow(meeting: meeting, showsDay: true)
                                if let snippet = snippet(for: meeting) {
                                    Text(snippet)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .padding(.leading, Metrics.rowIcon + 30)
                                        .padding(.trailing, 16)
                                        .padding(.bottom, 12)
                                        .padding(.top, -6)
                                }
                            }
                        }
                        .buttonStyle(PressableStyle())
                        if index < results.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    private func snippet(for meeting: Meeting) -> AttributedString? {
        let needle = query.trimmingCharacters(in: .whitespaces)
        for text in [meeting.summaryText, meeting.notes, meeting.transcriptText] {
            guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "#", with: "") + (end < text.endIndex ? "…" : "")
            var attributed = AttributedString(excerpt)
            if let hit = attributed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[hit].foregroundColor = .primary
                attributed[hit].font = .footnote.weight(.semibold)
            }
            return attributed
        }
        return nil
    }
}

/// A project card in the horizontal row.
private struct ProjectCard: View {
    let name: String
    let count: Int
    let last: Date

    var body: some View {
        let tint = Tint.color(for: name)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                WaveMark(amplitude: 0.3)
                    .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(height: 60)
                    .offset(x: 30, y: -14)
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .frame(height: 76)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) meeting\(count == 1 ? "" : "s") · \(Format.day(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
        }
        .frame(width: 164)
        .background(Surface.card)
        .clipShape(.rect(cornerRadius: Metrics.tileRadius, style: .continuous))
    }
}

/// Meetings in one project or series.
struct MeetingCollectionView: View {
    let title: String
    let symbol: String
    let include: (Meeting) -> Bool
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]

    var body: some View {
        let list = meetings.filter(include)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    MeetingGlyph(symbol: symbol, tint: Tint.color(for: title), size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(list.count) meetings")
                            .font(.headline)
                        let open = list.reduce(0) { $0 + $1.openItems.count }
                        Text(open == 0 ? "Nothing open" : "\(open) action items open")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                Card {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, meeting in
                        NavigationLink(value: MeetingRoute(id: meeting.id)) {
                            MeetingRow(meeting: meeting, showsDay: true)
                        }
                        .buttonStyle(PressableStyle())
                        if index < list.count - 1 { RowDivider() }
                    }
                }
            }
            .padding(Metrics.gutter)
        }
        .background(Surface.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}
