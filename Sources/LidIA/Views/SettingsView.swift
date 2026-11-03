import SwiftData
import SwiftUI

/// The Settings window: a searchable sidebar of panes and a detail column
/// with a large title and a centered grouped form.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable private var router = SettingsRouter.shared
    @State private var ai = AISettingsModel()
    @State private var mcp = MCPSettingsModel()
    @State private var selectedResult: String?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !router.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: SettingsLayout.sidebarWidth, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $router.path) {
                paneView(router.pane)
                    .navigationDestination(for: SettingsSubpage.self) { subpage in
                        subpageView(subpage)
                    }
            }
        }
        .searchable(text: $router.searchText, placement: .sidebar, prompt: "Search settings")
        .searchFocused($searchFocused)
        .background {
            Button("Search Settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: router.searchText) { _, text in
            if text.isEmpty { selectedResult = nil }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
    }

    // MARK: - Sidebar

    private enum SidebarItem: Hashable {
        case pane(SettingsPane)
        case result(String)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if isSearching { return selectedResult.map(SidebarItem.result) }
                return .pane(router.pane)
            },
            set: { item in
                switch item {
                case .pane(let pane):
                    router.pane = pane
                case .result(let id):
                    selectedResult = id
                    if let entry = SettingsSearchIndex.entries.first(where: { $0.id == id }) {
                        router.reveal(entry.location)
                    }
                case nil:
                    break
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            if isSearching {
                searchResults
            } else {
                Section {
                    ProfileHeader(settings: settings)
                        .selectionDisabled()
                }
                ForEach(Array(SettingsPane.sidebarGroups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                SettingsIconTile(symbol: pane.symbol, tint: pane.tint, accessibilityName: "\(pane.title) icon")
                            }
                            .tag(SidebarItem.pane(pane))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onExitCommand { router.searchText = "" }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsSearchIndex.search(router.searchText)
        if results.isEmpty {
            Text("No results for \u{201C}\(router.searchText)\u{201D}")
                .foregroundStyle(.secondary)
                .selectionDisabled()
        } else {
            Section("Results") {
                ForEach(results) { entry in
                    HStack(spacing: 8) {
                        SettingsIconTile(symbol: entry.pane.symbol, tint: entry.pane.tint, size: 20, accessibilityName: "\(entry.pane.title) icon")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                                .lineLimit(1)
                            Text(entry.breadcrumb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 1)
                    .tag(SidebarItem.result(entry.id))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens \(entry.breadcrumb)")
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func paneView(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(settings: settings)
        case .recording: RecordingPane(settings: settings)
        case .notes: NotesTemplatesPane(settings: settings)
        case .ai: AIPane(settings: settings, ai: ai)
        case .calendars: CalendarsPane(settings: settings)
        case .notifications: NotificationsPane(settings: settings)
        case .actionItems: ActionItemsPane(settings: settings)
        case .voice: VoicePane(settings: settings)
        case .dictation: DictationPane(settings: settings)
        case .apps: AppsExtensionsPane(settings: settings, mcp: mcp)
        case .sync: SyncPane(settings: settings)
        case .privacy: PrivacyPane(settings: settings)
        case .importData: ImportPane()
        case .about: AboutPane()
        }
    }

    @ViewBuilder
    private func subpageView(_ subpage: SettingsSubpage) -> some View {
        switch subpage {
        case .vocabulary: VocabularyPage(settings: settings)
        case .onDeviceModels: OnDeviceModelsPage(settings: settings, ai: ai)
        case .aiAdvanced: AIAdvancedPage(settings: settings, ai: ai)
        case .template(let id): TemplateDetailPage(settings: settings, templateID: id)
        case .integration(let kind): IntegrationDetailPage(settings: settings, kind: kind)
        }
    }
}

// MARK: - Profile header

/// Avatar, name and what the name is for. Click to edit the name.
private struct ProfileHeader: View {
    @Bindable var settings: AppSettings
    @State private var isEditing = false

    private var name: String {
        settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var body: some View {
        Button {
            isEditing = true
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.85), .accentColor], startPoint: .top, endPoint: .bottom))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(initials)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? "Add your name" : name)
                        .font(.headline)
                        .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Text("How LidIA finds your action items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.isEmpty ? "Add your name" : "Your name, \(name)")
        .accessibilityHint("Edit the name LidIA uses to find your action items.")
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your name")
                    .font(.headline)
                TextField("Your name", text: $settings.displayName, prompt: Text("First and last name"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { isEditing = false }
                Text("LidIA uses it to find your action items and label you in transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}
