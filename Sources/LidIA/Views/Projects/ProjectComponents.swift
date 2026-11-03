import SwiftData
import SwiftUI

extension ProjectPalette {
    /// Warm, muted hues beside her red (the same eight as people).
    static let colors: [Color] = Brand.avatarPalette

    @MainActor
    static func color(for project: String) -> Color {
        colors[IntelligenceStore.shared.colorIndex(for: project) % colors.count]
    }
}

/// "▸ Northwind": a project's folder icon in its colour, then its name.
struct ProjectLabel: View {
    let name: String
    var font: Font = .caption

    var body: some View {
        Label {
            Text(name)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(ProjectPalette.color(for: name))
        }
        .labelStyle(.titleAndIcon)
        .font(font)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Project \(name)")
    }
}

/// Granola-style "Add to · Northwind ✓ ✕" chip. Hover shows why.
struct ProjectSuggestionChip: View {
    let suggestion: ProjectSuggester.Suggestion
    var compact = false
    var onAccept: () -> Void
    var onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(Brand.red)
                .accessibilityHidden(true)
            if !compact {
                Text("Add to")
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "folder.fill")
                .font(.caption2)
                .foregroundStyle(ProjectPalette.color(for: suggestion.project))
                .accessibilityHidden(true)
            Text(suggestion.project)
                .fontWeight(.medium)
                .lineLimit(1)
            Divider().frame(height: 12)
            Button(action: onAccept) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help("Add to \(suggestion.project)")
            .accessibilityLabel("Add to \(suggestion.project)")
            Button(action: onReject) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Not in \(suggestion.project). LidIA won't suggest it again for this meeting.")
            .accessibilityLabel("Don't add to \(suggestion.project)")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(Brand.red.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.red.opacity(0.22), lineWidth: 0.5))
        .help("Suggested because: " + suggestion.reasons.joined(separator: "; "))
        .fixedSize()
    }
}

/// The meeting page's project chip: shows the project, or offers one, and
/// lets the user pick, create or remove it.
struct MeetingProjectMenu: View {
    @Bindable var meeting: Meeting
    var suggestion: ProjectSuggester.Suggestion?
    var projects: [String]

    @Environment(\.modelContext) private var modelContext
    @State private var showsNewProject = false
    @State private var newName = ""

    var body: some View {
        Group {
            if meeting.projectName == nil, let suggestion {
                ProjectSuggestionChip(
                    suggestion: suggestion,
                    onAccept: { assign(suggestion.project) },
                    onReject: { IntelligenceStore.shared.rejectProject(suggestion.project, for: [meeting.id]) }
                )
            } else {
                menu
            }
        }
        .alert("New Project", isPresented: $showsNewProject) {
            TextField("Name", text: $newName)
            Button("Create") { assign(newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Gather every meeting about one client or initiative, like “Northwind”.")
        }
    }

    private var menu: some View {
        Menu {
            ForEach(projects, id: \.self) { project in
                Button {
                    assign(project)
                } label: {
                    if project == meeting.projectName {
                        Label(project, systemImage: "checkmark")
                    } else {
                        Text(project)
                    }
                }
            }
            if !projects.isEmpty { Divider() }
            Button("New Project…") {
                newName = ""
                showsNewProject = true
            }
            if meeting.projectName != nil {
                Button("Remove from Project", role: .destructive) {
                    meeting.setProject(nil)
                    try? modelContext.save()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: meeting.projectName == nil ? "folder.badge.plus" : "folder.fill")
                    .foregroundStyle(meeting.projectName.map(ProjectPalette.color(for:)) ?? .secondary)
                    .imageScale(.small)
                Text(meeting.projectName ?? "Project")
                    .foregroundStyle(meeting.projectName == nil ? .secondary : .primary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(MeetingChipButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(meeting.projectName.map { "In project \($0)" } ?? "Add this meeting to a project")
        .accessibilityLabel(meeting.projectName.map { "Project: \($0)" } ?? "Add to a project")
    }

    private func assign(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        IntelligenceStore.shared.registerProject(trimmed)
        meeting.setProject(trimmed)
        try? modelContext.save()
    }
}

/// The meeting page's project chip, with LidIA's suggestion worked out
/// from the whole library on this Mac.
struct MeetingProjectChip: View {
    @Bindable var meeting: Meeting
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]
    @Environment(AppSettings.self) private var settings

    @State private var suggestion: ProjectSuggester.Suggestion?
    @State private var projects: [String] = []

    var body: some View {
        let store = IntelligenceStore.shared
        MeetingProjectMenu(meeting: meeting, suggestion: suggestion, projects: projects)
            .task(id: IntelligenceEngine.fingerprint(allMeetings, events: [], store: store)) {
                MeetingAttendeeContext.currentUserName = settings.displayName
                let signals = allMeetings.filter { !$0.isDeleted && $0.status != .recording }.map { MeetingSignals($0) }
                let context = ProjectSuggester.Context.build(signals)
                let known = store.state.knownProjects
                projects = ProjectCatalog.projects(meetings: signals, known: known).map(\.name)
                guard meeting.projectName == nil else {
                    suggestion = nil
                    return
                }
                let fits = ProjectSuggester.suggestions(for: signals, knownProjects: known, rejected: store.state.rejectedProjects, context: context)
                let clusters = ProjectSuggester.clusters(
                    signals, existingProjects: known, dismissed: store.state.dismissedClusters,
                    excluding: Set(fits.keys), context: context
                )
                suggestion = IntelligenceEngine.projectSuggestions(signals, clusters: clusters, context: context, store: store)[meeting.id]
            }
    }
}

/// Card background shared by Today, projects and the board.
struct LidiaCard: ViewModifier {
    var tint: Color?
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .primary).opacity(tint == nil ? 0.035 : 0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder((tint ?? Color(nsColor: .separatorColor)).opacity(tint == nil ? 0.5 : 0.25), lineWidth: 0.5)
            )
    }
}

extension View {
    func lidiaCard(tint: Color? = nil, radius: CGFloat = 12) -> some View {
        modifier(LidiaCard(tint: tint, radius: radius))
    }
}

/// A live, cached `IntelligenceResults` for a view: recomputed when the
/// library, the agenda or the user's choices change.
struct IntelligenceRefresher: ViewModifier {
    let meetings: [Meeting]
    let events: [AgendaEvent]
    @Binding var results: IntelligenceResults
    var autoAssign = false

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        let store = IntelligenceStore.shared
        content
            .task(id: IntelligenceEngine.fingerprint(meetings, events: events, store: store) &+ (settings.autoAssignProjects ? 1 : 0)) {
                var computed = IntelligenceEngine.compute(meetings: meetings, events: events, settings: settings, store: store)
                if autoAssign, IntelligenceEngine.autoAssign(computed, meetings: meetings, settings: settings, store: store, context: modelContext) > 0 {
                    computed = IntelligenceEngine.compute(meetings: meetings, events: events, settings: settings, store: store)
                }
                results = computed
            }
    }
}

extension View {
    func intelligence(meetings: [Meeting], events: [AgendaEvent] = [], results: Binding<IntelligenceResults>, autoAssign: Bool = false) -> some View {
        modifier(IntelligenceRefresher(meetings: meetings, events: events, results: results, autoAssign: autoAssign))
    }
}
