import SwiftData
import SwiftUI

/// One project: its meetings, open action items and people, meetings LidIA
/// thinks belong here (✓/✕), and a Digest that asks LidIA for the project's
/// decisions, open items and next steps.
struct ProjectDetailView: View {
    let name: String
    @Bindable var nav: NavigationState
    var onAsk: (String) -> Void

    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var intelligence = IntelligenceResults.empty
    @State private var showsRename = false
    @State private var renameText = ""
    @State private var confirmsRemove = false

    private var folded: String { ProjectCatalog.fold(name) }

    private var meetings: [Meeting] {
        allMeetings.filter { !$0.isDeleted && $0.projectName.map(ProjectCatalog.fold) == folded }
    }

    private var suggested: [(Meeting, ProjectSuggester.Suggestion)] {
        allMeetings.compactMap { meeting in
            guard let suggestion = intelligence.projectSuggestions[meeting.id],
                  ProjectCatalog.fold(suggestion.project) == folded else { return nil }
            return (meeting, suggestion)
        }
    }

    private var openItems: [ActionItem] {
        meetings.flatMap { meeting in meeting.actionItems.filter { !$0.isDeleted && !$0.isCompleted } }
            .sorted { ($0.meeting?.date ?? .distantPast) > ($1.meeting?.date ?? .distantPast) }
    }

    /// Everyone but the user, most meetings first.
    private var people: [(MeetingAttendee, Int)] {
        var counts: [String: (MeetingAttendee, Int)] = [:]
        for meeting in meetings {
            for attendee in meeting.libraryAttendees where !attendee.isCurrentUser {
                counts[attendee.id, default: (attendee, 0)].1 += 1
            }
        }
        return counts.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !suggested.isEmpty { suggestedSection }
                meetingsSection
                if !openItems.isEmpty { actionItemsSection }
                if !people.isEmpty { peopleSection }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(name)
        .intelligence(meetings: allMeetings, results: $intelligence)
        .alert("Rename Project", isPresented: $showsRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove the project “\(name)”?", isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove Project", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(meetings.count) meetings stay in your library; they just leave this project.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ProjectPalette.color(for: name).gradient)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                onAsk(digestPrompt)
            } label: {
                Label("Digest", systemImage: "sparkles")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(meetings.isEmpty)
            .help("Ask LidIA for this project's decisions, open items and next steps")
            Menu {
                Button("Rename…") {
                    renameText = name
                    showsRename = true
                }
                @Bindable var settings = settings
                Toggle("Add Meetings Automatically When Certain", isOn: $settings.autoAssignProjects)
                Divider()
                Button("Remove Project…", role: .destructive) { confirmsRemove = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .controlSize(.large)
            .fixedSize()
            .accessibilityLabel("Project options")
        }
    }

    private var subtitle: String {
        var parts = ["\(meetings.count) \(meetings.count == 1 ? "meeting" : "meetings")"]
        if let latest = meetings.first { parts.append("latest \(MeetingRowFormat.relativeDay(latest.date))") }
        let companies = AttendeeGrouping.externalCompanies(people.map(\.0))
        if !companies.isEmpty { parts.append(companies.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var digestPrompt: String {
        let titles = Array(Set(meetings.prefix(12).map { $0.title.trimmingCharacters(in: .whitespaces) })).sorted()
        return "Give me a digest of the “\(name)” project across its \(meetings.count) meetings (\(titles.joined(separator: "; "))): the key decisions, open action items and owners, risks, and what's next."
    }

    // MARK: - Suggested

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Suggested for \(name)")
                Label("On this Mac", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if suggested.count > 1 {
                    Button("Add All \(suggested.count)") {
                        withAnimation {
                            IntelligenceEngine.assign(suggested.map(\.0.id), to: name, in: allMeetings, store: .shared, context: modelContext)
                        }
                    }
                    .buttonStyle(.accentLink)
                    .font(.callout)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(suggested.enumerated()), id: \.element.0.id) { index, pair in
                    if index > 0 { Divider().padding(.leading, 58) }
                    suggestedRow(pair.0, pair.1)
                }
            }
            .padding(.horizontal, 12)
            .lidiaCard(tint: .purple)
        }
    }

    private func suggestedRow(_ meeting: Meeting, _ suggestion: ProjectSuggester.Suggestion) -> some View {
        HStack(spacing: 12) {
            MeetingDateTile(date: meeting.date)
            VStack(alignment: .leading, spacing: 2) {
                Button { nav.show(meeting) } label: {
                    Text(meeting.title.isEmpty ? "Untitled" : meeting.title.trimmingCharacters(in: .whitespaces))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                BecauseLine(reasons: Array(suggestion.reasons.prefix(3)))
            }
            Spacer(minLength: 8)
            Button {
                withAnimation { IntelligenceEngine.assign([meeting.id], to: name, in: allMeetings, store: .shared, context: modelContext) }
            } label: {
                Label("Add", systemImage: "checkmark")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityLabel("Add \(meeting.title) to \(name)")
            Button {
                withAnimation { IntelligenceStore.shared.rejectProject(name, for: [meeting.id]) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Not in \(name)")
            .accessibilityLabel("Don't add \(meeting.title) to \(name)")
        }
        .padding(.vertical, 8)
    }

    // MARK: - Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Meetings")
            if meetings.isEmpty {
                Text("No meetings yet. Add one from its page (the folder chip next to the date), or accept a suggestion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .lidiaCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { Divider().padding(.leading, 58) }
                        Button { nav.show(meeting) } label: {
                            LibraryMeetingRow(meeting: meeting, attendees: meeting.libraryAttendees)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from \(name)") {
                                meeting.setProject(nil)
                                try? modelContext.save()
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .lidiaCard()
            }
        }
    }

    // MARK: - Action items

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Open Action Items")
                Text("\(openItems.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Board") { nav.show(.actionItems) }
                    .buttonStyle(.accentLink)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(openItems.prefix(8)) { item in
                    DueActionItemRow(item: item, onOpenMeeting: { nav.show($0) })
                }
            }
            .padding(14)
            .lidiaCard()
        }
    }

    // MARK: - People

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("People")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(people.prefix(12), id: \.0.id) { attendee, count in
                    HStack(spacing: 10) {
                        AttendeeAvatar(attendee: attendee, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attendee.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text([attendee.company, "\(count) \(count == 1 ? "meeting" : "meetings")"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .lidiaCard()
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Actions

    private func rename() {
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != name else { return }
        for meeting in meetings { meeting.setProject(new) }
        IntelligenceStore.shared.renameProject(name, to: new)
        try? modelContext.save()
        nav.showProject(new)
    }

    private func remove() {
        for meeting in meetings { meeting.setProject(nil) }
        IntelligenceStore.shared.forgetProject(name)
        try? modelContext.save()
        nav.showToday()
    }
}
