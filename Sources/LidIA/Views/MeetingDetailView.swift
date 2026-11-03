import os
import SwiftData
import SwiftUI

/// The meeting page: a centered title, one row of chips (AI notes / My
/// notes, Transcript, participants, date), the notes, a feedback bar and a
/// docked Ask field. Transcript and Ask open in the inspector. Live mode
/// while recording; a stage stepper while processing.
///
/// `selectedTab` keeps the old tab vocabulary so ⌘1–5 and the app shell keep
/// working: "summary" and "actions" show AI notes, "notes" shows My notes,
/// "transcript" and "chat" open the inspector on Transcript or Ask.
struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @Binding var selectedTab: String
    var nav: NavigationState?
    var backTitle: String = "Today"
    var onBack: (() -> Void)?
    var onAsk: ((String) -> Void)?
    var onDelete: ((Meeting) -> Void)?

    var body: some View {
        // Fresh page state (chat, player, banners) per meeting.
        MeetingPageView(
            meeting: meeting,
            selectedTab: $selectedTab,
            nav: nav,
            backTitle: backTitle,
            onBack: onBack,
            onAskAll: onAsk,
            onDelete: onDelete
        )
        .id(meeting.id)
        // Onscreen context: "summarize this", "what did they ask me to do here?"
        .siriOnscreen(meeting: meeting)
    }
}

/// A regenerate the user asked for, pending confirmation.
struct MeetingRegenerateRequest: Identifiable, Equatable {
    let id = UUID()
    var provider: AppSettings.LLMProvider?
    var overwriteUserEdits = false
}

private struct MeetingPageView: View {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "MeetingDetailView")

    @Bindable var meeting: Meeting
    @Binding var selectedTab: String
    var nav: NavigationState?
    var backTitle: String
    var onBack: (() -> Void)?
    var onAskAll: ((String) -> Void)?
    var onDelete: ((Meeting) -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.backgroundContext) private var backgroundContext
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(RecordingSession.self) private var session
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(\.meetingProcessingProgressSource) private var progressSource
    @Environment(\.chatOpenMeeting) private var openMeeting

    // Inspector
    @AppStorage("meetingPage.inspectorVisible") private var inspectorVisible = false
    @AppStorage("meetingPage.inspectorTab") private var inspectorTab: MeetingInspectorTab = .transcript
    @State private var liveInspectorVisible = false
    @State private var askViewModel = ChatBarViewModel()
    /// Titles a placeholder-titled note once the user pauses typing.
    @State private var titleDebouncer = Debouncer(delay: .seconds(2.5))
    @State private var isTitling = false
    @State private var audioPlayer = TranscriptAudioPlayer()

    // Document
    @State private var notesMode: MeetingNotesMode = .ai
    @State private var scrollRequest: MeetingDocumentScrollRequest?
    @State private var showsAttendees = false
    @State private var askDraft = ""
    @FocusState private var notesFocused: Bool

    // Operations and feedback
    @State private var banners: [MeetingPageBanner] = []
    @State private var inFlight: Set<MeetingPageOperation> = []
    @State private var pendingRegenerate: MeetingRegenerateRequest?
    @State private var regenerateSnapshot: RegenerateSnapshot?
    @State private var regenerateImpact: RegenerateImpact?
    @State private var libraryHealth = LibraryHealth.shared
    @State private var previousSummaryModel: String?
    @State private var showUndoBanner = false
    @State private var stepperCollapsed = false
    @State private var lastTemplate: MeetingTemplate?
    @State private var summaryModel: String?
    @State private var attendees: [MeetingAttendee] = []

    // Sheets
    @State private var isEditingSummary = false
    @State private var editableSummary = ""
    @State private var isEditingTranscript = false
    @State private var editableTranscript = ""
    @State private var recipeResult = ""
    @State private var showRecipeResult = false
    @State private var activeRecipeName = ""

    private let provenance = MeetingProvenanceStore()
    private let askIndex = MeetingAskThreadIndex()

    // MARK: - Derived state

    private var isLive: Bool {
        meeting.status == .recording && session.isRecording && session.currentMeeting?.id == meeting.id
    }

    private var progress: MeetingPageProgress {
        progressSource.progress(for: meeting)
    }

    private var inspectorBinding: Binding<Bool> {
        isLive ? $liveInspectorVisible : $inspectorVisible
    }

    private var effectiveSummary: String {
        let edited = meeting.userEditedSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? meeting.summary : edited
    }

    private var effectiveTranscript: String {
        let edited = meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? meeting.refinedTranscript : edited
    }

    private var hasAINotes: Bool {
        !effectiveSummary.isEmpty || meeting.structuredSummary != nil || streamingText != nil
    }

    /// The summary as the pipeline writes it, while it's summarising.
    private var streamingText: String? {
        let center = ProcessingProgressCenter.shared
        let text = center.streamingSummary[meeting.id]
        if let text, !text.isEmpty { return text }
        if let live = center.progress(for: meeting.id), live.currentStage == .summarizing, !live.isFinished {
            return ""
        }
        return nil
    }

    private var isTranscriptShown: Bool {
        inspectorBinding.wrappedValue && inspectorTab == .transcript
    }

    private var summaryCaption: String {
        var parts = ["Written by AI"]
        if let templateID = meeting.templateID,
           let template = settings.meetingTemplates.first(where: { $0.id == templateID }) {
            parts.append("\(template.name) template")
        }
        if let summaryModel, !summaryModel.isEmpty { parts.append(summaryModel) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Body

    var body: some View {
        pageWithLifecycle
            .confirmationDialog(
                "Regenerate the notes?",
                isPresented: regenerateDialogBinding,
                titleVisibility: .visible,
                presenting: pendingRegenerate
            ) { (request: MeetingRegenerateRequest) in
                Button("Regenerate") { runRegenerate(request) }
                Button("Cancel", role: .cancel) {}
            } message: { (request: MeetingRegenerateRequest) in
                Text(regenerateMessage(for: request))
            }
            .sheet(isPresented: $isEditingSummary) { summaryEditorSheet }
            .sheet(isPresented: $isEditingTranscript) { transcriptEditorSheet }
            .sheet(isPresented: $showRecipeResult) { recipeSheet }
    }

    private var regenerateDialogBinding: Binding<Bool> {
        Binding(get: { pendingRegenerate != nil }, set: { if !$0 { pendingRegenerate = nil } })
    }

    @ViewBuilder
    private var pageContent: some View {
        if isLive {
            LiveMeetingView(meeting: meeting, notesFocused: $notesFocused)
                .overlay(alignment: .bottom) { askDock }
        } else {
            MeetingDocumentView(
                meeting: meeting,
                mode: notesMode,
                streamingText: streamingText,
                summaryCaption: summaryCaption,
                isResummarizing: inFlight.contains(.resummarize),
                scrollRequest: scrollRequest,
                notesFocused: $notesFocused,
                isProcessing: progress.phase == .running || progress.phase == .queued
                    || meeting.status == .processing || meeting.status == .queued,
                onEditSummary: { beginEditingSummary() },
                onGenerateNotes: canGenerateNotes ? { requestRegenerate(MeetingRegenerateRequest()) } : nil
            ) {
                documentTop
            } feedback: {
                MeetingFeedbackBar(meetingID: meeting.id) {
                    regenerateMenuItems
                }
            }
            // An overlay, not a safe-area inset, so the dock never sets the
            // page's minimum width (the document leaves room at the bottom).
            .overlay(alignment: .bottom) { askDock }
        }
    }

    /// After Stop: notes can be written from the transcript (processing failed, or
    /// nothing has run yet).
    private var canGenerateNotes: Bool {
        !meeting.rawTranscript.isEmpty && !inFlight.contains(.regenerate)
            && meeting.status != .recording && meeting.status != .processing
    }

    @ViewBuilder
    private var askDock: some View {
        if !(inspectorBinding.wrappedValue && inspectorTab == .ask) {
            MeetingAskDock(
                text: $askDraft,
                isRecipeRunning: recipeIsRunning,
                onSubmit: { ask($0) },
                onRecipe: { runRecipe($0) }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 44)
            .frame(maxWidth: isLive ? 640 : .infinity)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                // Text fades out behind the dock instead of running under it.
                LinearGradient(
                    stops: [
                        .init(color: Color(nsColor: .textBackgroundColor).opacity(0), location: 0),
                        .init(color: Color(nsColor: .textBackgroundColor).opacity(0.92), location: 0.45),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    private var header: some View {
        MeetingHeaderView(
            meeting: meeting,
            isLive: isLive,
            attendees: attendees,
            notesMode: $notesMode,
            hasAINotes: hasAINotes,
            isTranscriptShown: isTranscriptShown,
            showsStatus: !showsStepper,
            onToggleTranscript: { toggleTranscript() },
            showsAttendees: $showsAttendees
        )
    }

    private var inspectorContent: some View {
        MeetingInspectorView(
            meeting: meeting,
            tab: $inspectorTab,
            liveWords: isLive ? session.transcriptWords : nil,
            player: audioPlayer,
            askViewModel: askViewModel,
            onEditTranscript: isLive ? nil : { beginEditingTranscript() }
        )
        .environment(\.chatOpenMeeting, inspectorOpenMeeting)
        .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
    }

    /// In this meeting's Ask, a citation of this meeting jumps to the moment
    /// in the transcript beside it; other meetings open as usual.
    private var inspectorOpenMeeting: ChatOpenMeetingAction {
        let meetingID = meeting.id
        let parent = openMeeting
        let nav = nav
        return ChatOpenMeetingAction { id, time in
            if id == meetingID {
                if let time { nav?.transcriptSeekRequest = time } else { nav?.inspectorRequest = .transcript }
            } else {
                parent(id, at: time)
            }
        }
    }

    private var pageWithInspector: some View {
        pageContent
            .inspector(isPresented: inspectorBinding) { inspectorContent }
            .toolbar { detailToolbar }
            .navigationTitle(meeting.title.isEmpty ? "Untitled Meeting" : meeting.title)
            .toolbar(removing: .title)
            .background { shortcutButtons }
    }

    private var isFailed: Bool { progress.phase == .failed }

    private var pageWithLifecycle: some View {
        pageWithInspector
        .onAppear {
            MeetingAskSession.configure(
                askViewModel,
                meeting: meeting,
                settings: settings,
                modelContext: modelContext,
                backgroundContext: backgroundContext,
                modelManager: modelManager,
                index: askIndex
            )
            summaryModel = provenance.summaryModel(for: meeting.id)
            refreshAttendees()
            notesMode = hasAINotes ? .ai : .mine
            apply(tab: selectedTab, scrolls: false)
            handleRequests()
        }
        .onDisappear { audioPlayer.unload() }
        .onChange(of: meeting.notes) { _, notes in scheduleAutoTitle(notes) }
        .onChange(of: selectedTab) { _, tab in apply(tab: tab) }
        .onChange(of: meeting.calendarAttendees) { refreshAttendees() }
        .onChange(of: hasAINotes) { _, has in
            // The summary just arrived: show it.
            if has, meeting.notes.isEmpty || !isLive { notesMode = .ai }
        }
        .onChange(of: nav?.inspectorRequest) { handleRequests() }
        .onChange(of: nav?.transcriptSeekRequest) { handleRequests() }
        .onChange(of: nav?.meetingPageRequest) { handleRequests() }
        .onChange(of: askViewModel.activeThreadID) { _, threadID in
            askIndex.setThreadID(threadID, for: meeting.id)
        }
        .onChange(of: isFailed) { _, failed in
            // Failures must always be visible, even after "Continue in background".
            if failed { stepperCollapsed = false }
        }
        .onChange(of: isLive) { _, live in
            if live {
                notesFocused = true
            } else if meeting.status != .recording {
                // Just stopped: the transcript stays in view while the notes are written.
                inspectorTab = .transcript
                inspectorVisible = true
                notesMode = .ai
            }
        }
    }

    private func refreshAttendees() {
        attendees = AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: settings.displayName)
    }

    /// One-shot requests from the app (commands, snapshot runs).
    private func handleRequests() {
        guard let nav else { return }
        if let request = nav.inspectorRequest {
            nav.inspectorRequest = nil
            switch request {
            case .hide: inspectorBinding.wrappedValue = false
            case .transcript:
                inspectorTab = .transcript
                inspectorBinding.wrappedValue = true
            case .ask:
                inspectorTab = .ask
                inspectorBinding.wrappedValue = true
            }
        }
        if let time = nav.transcriptSeekRequest {
            nav.transcriptSeekRequest = nil
            seekTranscript(to: time)
        }
        if let request = nav.meetingPageRequest {
            nav.meetingPageRequest = nil
            switch request {
            case .aiNotes: notesMode = .ai
            case .myNotes: notesMode = .mine
            case .showAttendees: showsAttendees = true
            case .closePopovers: showsAttendees = false
            }
        }
    }

    // MARK: - Document top: header, banners, stepper

    @ViewBuilder
    private var documentTop: some View {
        header
            .padding(.bottom, 4)

        if showsStartTranscribingChip {
            NoteTranscribeChip(isLive: false, onStart: startTranscribingNote, onStop: {})
                .frame(maxWidth: .infinity)
        }

        if let notice = libraryHealth.recoveryNotice {
            libraryRecoveryBanner(notice)
        }

        if meeting.status == .recording {
            MeetingBannerView(
                kind: .info,
                title: "This recording was interrupted",
                message: "LidIA is no longer recording this meeting. Your notes and any transcript captured so far are saved."
            )
        }

        if showsStepper {
            stepper
        }

        if showUndoBanner, regenerateSnapshot != nil {
            undoBanner
        }

        ForEach(banners) { banner in
            operationBanner(banner)
        }
    }

    private var showsStepper: Bool {
        progress.isVisible && !(stepperCollapsed && progress.phase == .running)
    }

    private func libraryRecoveryBanner(_ notice: StoreRecoveryNotice) -> some View {
        MeetingBannerView(
            kind: notice.isTemporaryLibrary ? .error : .info,
            title: notice.isTemporaryLibrary ? "Your library couldn't be opened" : "Your library was recovered",
            message: notice.message,
            onDismiss: { libraryHealth.dismissRecoveryNotice() },
            actions: {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([notice.backupURL])
                }
            }
        )
    }

    private var stepper: some View {
        ProcessingStepperView(
            progress: progress,
            onContinueInBackground: { continueInBackground() },
            onRetry: { requestRegenerate(MeetingRegenerateRequest()) },
            anotherModelMenu: {
                providerMenuItems { provider in
                    requestRegenerate(MeetingRegenerateRequest(provider: provider))
                }
            }
        )
    }

    private var undoBanner: some View {
        MeetingBannerView(
            kind: .success,
            title: "Notes regenerated",
            message: regenerateResultMessage,
            onDismiss: {
                showUndoBanner = false
                regenerateSnapshot = nil
            },
            actions: {
                Button("Undo") { undoRegenerate() }
            }
        )
    }

    private func operationBanner(_ banner: MeetingPageBanner) -> some View {
        MeetingBannerView(
            kind: banner.kind,
            title: banner.title,
            message: banner.message,
            onDismiss: { dismissBanner(banner.operation) },
            actions: {
                if banner.kind == .error {
                    Button("Retry") { retry(banner.operation) }
                        .disabled(inFlight.contains(banner.operation))
                }
                if banner.kind == .error, banner.operation == .regenerate {
                    Menu("Use another model") {
                        providerMenuItems { provider in
                            dismissBanner(.regenerate)
                            requestRegenerate(MeetingRegenerateRequest(provider: provider))
                        }
                    }
                    .fixedSize()
                }
            }
        )
    }

    // MARK: - Toolbar
    //
    // Two items: Share (export, copy, send to integrations) and More (AI,
    // template, recipes, edits, inspector, delete). Transcript and Ask live
    // on the page itself (header chip, docked field).

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                onBack?()
            } label: {
                Label("Back to \(backTitle)", systemImage: "chevron.left")
            }
            .help("Back to \(backTitle) (⌘[)")
            .keyboardShortcut("[", modifiers: .command)
            .disabled(onBack == nil)
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            shareMenu
        }
        ToolbarItem(placement: .primaryAction) {
            moreMenu
        }
    }

    private var shareMenu: some View {
        Menu {
            Section("Copy") {
                Button("Copy AI Notes", systemImage: "doc.on.doc") {
                    ExportService.copyToClipboard(ExportService.summaryToMarkdown(meeting))
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy Action Items", systemImage: "checklist") {
                    ExportService.copyToClipboard(ExportService.actionItemsToMarkdown(meeting))
                }
                Button("Copy Transcript", systemImage: "text.quote") {
                    let text = effectiveTranscript.isEmpty
                        ? meeting.rawTranscript.map(\.word).joined(separator: " ")
                        : effectiveTranscript
                    ExportService.copyToClipboard(text)
                }
                Button("Copy Everything", systemImage: "doc.richtext") {
                    ExportService.copyToClipboard(ExportService.meetingToMarkdown(meeting))
                }
            }
            Section {
                // ⇧⌘E for this lives in the app's File menu (AppCommands).
                Button("Export as Markdown…", systemImage: "square.and.arrow.down") { exportToFile() }
            }
            Section("Send To") {
                sendToItems
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Copy, export or send this meeting")
    }

    @ViewBuilder
    private var sendToItems: some View {
        let notion = !settings.notionAPIKey.isEmpty && !settings.notionDatabaseID.isEmpty
        let n8n = settings.n8nEnabled && !settings.n8nWebhookURL.isEmpty
        if notion {
            Button(meeting.notionPageID == nil ? "Notion" : "Notion (Sent)", systemImage: "doc.text") {
                Task { await sendToNotion() }
            }
            .disabled(inFlight.contains(.notion) || meeting.status != .complete)
        }
        if n8n {
            Button("n8n Webhook", systemImage: "arrow.up.forward.app") {
                Task { await sendToN8n() }
            }
            .disabled(inFlight.contains(.n8n) || meeting.status != .complete)
        }
        if settings.remindersEnabled {
            Button("Apple Reminders", systemImage: "checklist") {
                Task { await sendToReminders() }
            }
            .disabled(meeting.actionItems.isEmpty || inFlight.contains(.reminders))
        }
        if !notion && !n8n && !settings.remindersEnabled {
            Button("Set Up Integrations…", systemImage: "puzzlepiece.extension") {
                SettingsRouter.shared.open(.apps)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Menu {
                    regenerateMenuItems
                } label: {
                    Label("Regenerate Notes", systemImage: "arrow.clockwise")
                }
                .disabled(inFlight.contains(.regenerate) || meeting.status == .processing || meeting.status == .recording)

                Menu {
                    templateMenuItems
                } label: {
                    Label("Template", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(inFlight.contains(.resummarize) || meeting.status == .recording)

                Menu {
                    ForEach(Recipe.Category.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(Recipe.builtIn.filter { $0.category == category }) { recipe in
                                Button("\(recipe.emoji) \(recipe.name)") { runRecipe(recipe) }
                            }
                        }
                    }
                } label: {
                    Label("Recipes", systemImage: "wand.and.stars")
                }
                .disabled(recipeIsRunning)
            }
            Section {
                Button("Generate Title", systemImage: "textformat") { generateTitle() }
                    .disabled(inFlight.contains(.generateTitle))
                Button("Write Notes from Transcript", systemImage: "sparkles") { generateNotes() }
                    .disabled(inFlight.contains(.generateNotes))
            }
            Section {
                Button("Edit AI Notes…", systemImage: "square.and.pencil") { beginEditingSummary() }
                    .disabled(meeting.status == .recording)
                Button("Edit Transcript…", systemImage: "text.cursor") { beginEditingTranscript() }
                    .disabled(meeting.status == .recording)
            }
            Section {
                Button(inspectorBinding.wrappedValue ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") {
                    inspectorBinding.wrappedValue.toggle()
                }
                Button("Ask LidIA About All Meetings…", systemImage: "magnifyingglass") {
                    onAskAll?("")
                }
            }
            if let onDelete {
                Section {
                    Button("Delete Meeting…", systemImage: "trash", role: .destructive) { onDelete(meeting) }
                        .disabled(meeting.status == .recording)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .help("More actions: regenerate, template, recipes, edit, delete")
    }

    @ViewBuilder
    private var regenerateMenuItems: some View {
        Button("With Current Model") { requestRegenerate(MeetingRegenerateRequest()) }
        Button("With Current Model, Replacing My Edits") {
            requestRegenerate(MeetingRegenerateRequest(overwriteUserEdits: true))
        }
        Divider()
        providerMenuItems { provider in
            requestRegenerate(MeetingRegenerateRequest(provider: provider))
        }
    }

    @ViewBuilder
    private var templateMenuItems: some View {
        Button {
            meeting.templateID = nil
            meeting.templateAutoDetected = true
        } label: {
            if meeting.templateAutoDetected || meeting.templateID == nil {
                Label("Automatic", systemImage: "checkmark")
            } else {
                Text("Automatic")
            }
        }
        Divider()
        ForEach(settings.meetingTemplates) { template in
            Button {
                resummarize(with: template)
            } label: {
                let name = "\(template.emoji.isEmpty ? "" : template.emoji + " ")\(template.name)"
                if meeting.templateID == template.id && !meeting.templateAutoDetected {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }
        }
    }

    private var recipeIsRunning: Bool { recipeTask != nil }

    @State private var recipeTask: Task<Void, Never>?

    /// Configured providers as menu buttons. Ones the privacy rules block
    /// (Local-only mode, cloud AI off) show disabled with the reason.
    @ViewBuilder
    private func providerMenuItems(action: @escaping (AppSettings.LLMProvider) -> Void) -> some View {
        ForEach(availableProviders, id: \.self) { provider in
            if let reason = providerMenuDisabledReason(provider, settings: settings) {
                Button("\(provider.rawValue) (\(reason))") {}
                    .disabled(true)
            } else {
                Button(provider.rawValue) { action(provider) }
            }
        }
    }

    /// Not an exhaustive switch on purpose, so new providers don't break this view.
    private var availableProviders: [AppSettings.LLMProvider] {
        var providers: [AppSettings.LLMProvider] = []
        if settings.llmProvider == .ollama || !settings.ollamaURL.isEmpty { providers.append(.ollama) }
        if settings.llmProvider == .lmStudio { providers.append(.lmStudio) }
        providers.append(.mlx)
        if !settings.openaiAPIKey.isEmpty { providers.append(.openai) }
        if !settings.anthropicAPIKey.isEmpty { providers.append(.anthropic) }
        if !settings.cerebrasAPIKey.isEmpty { providers.append(.cerebras) }
        if !settings.deepseekAPIKey.isEmpty { providers.append(.deepseek) }
        if !settings.nvidiaAPIKey.isEmpty { providers.append(.nvidiaNIM) }
        if !settings.openRouterAPIKey.isEmpty { providers.append(.openRouter) }
        if settings.llmProvider != .ollama, !providers.contains(settings.llmProvider) {
            providers.insert(settings.llmProvider, at: 0)
        }
        return providers
    }

    // MARK: - Ask

    /// Opens the transcript at a cited moment and plays from there.
    private func seekTranscript(to time: TimeInterval) {
        inspectorTab = .transcript
        inspectorBinding.wrappedValue = true
        // The player loads with the transcript tab; seek once it's there.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            audioPlayer.seek(to: time, play: true)
        }
    }

    /// The docked field asks in the inspector's Ask tab, scoped to this meeting.
    private func ask(_ question: String) {
        inspectorTab = .ask
        inspectorBinding.wrappedValue = true
        askViewModel.inputText = question
        askViewModel.send()
    }

    private func toggleTranscript() {
        if isTranscriptShown {
            inspectorBinding.wrappedValue = false
        } else {
            inspectorTab = .transcript
            inspectorBinding.wrappedValue = true
        }
    }

    // MARK: - Shortcuts (⌘1–5, zero-frame buttons per CLAUDE.md)

    private var shortcutButtons: some View {
        Group {
            Button { select(tab: "summary") } label: { EmptyView() }
                .keyboardShortcut("1", modifiers: .command)
            Button { select(tab: "transcript") } label: { EmptyView() }
                .keyboardShortcut("2", modifiers: .command)
            Button { select(tab: "notes") } label: { EmptyView() }
                .keyboardShortcut("3", modifiers: .command)
            Button { select(tab: "actions") } label: { EmptyView() }
                .keyboardShortcut("4", modifiers: .command)
            Button { select(tab: "chat") } label: { EmptyView() }
                .keyboardShortcut("5", modifiers: .command)
            Button { inspectorBinding.wrappedValue.toggle() } label: { EmptyView() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func select(tab: String) {
        selectedTab = tab
        apply(tab: tab)
    }

    /// Maps the legacy tab names onto the new layout.
    private func apply(tab: String, scrolls: Bool = true) {
        switch tab {
        case "summary":
            if !isLive, hasAINotes {
                notesMode = .ai
                if scrolls { scrollRequest = MeetingDocumentScrollRequest(section: .summary) }
            }
        case "notes":
            if !isLive { notesMode = .mine }
            if scrolls { notesFocused = true }
        case "actions":
            if !isLive {
                notesMode = .ai
                if scrolls { scrollRequest = MeetingDocumentScrollRequest(section: .actionItems) }
            }
        case "transcript":
            // In live mode the transcript is already beside your notes.
            guard !isLive else { return }
            inspectorTab = .transcript
            inspectorVisible = true
        case "chat":
            inspectorTab = .ask
            inspectorBinding.wrappedValue = true
        default:
            break
        }
    }

    // MARK: - Banners

    private func show(_ banner: MeetingPageBanner) {
        banners.removeAll { $0.operation == banner.operation }
        banners.append(banner)
    }

    private func dismissBanner(_ operation: MeetingPageOperation) {
        banners.removeAll { $0.operation == operation }
    }

    private func retry(_ operation: MeetingPageOperation) {
        dismissBanner(operation)
        switch operation {
        case .generateTitle: generateTitle()
        case .generateNotes: generateNotes()
        case .resummarize: if let lastTemplate { resummarize(with: lastTemplate) }
        case .regenerate: requestRegenerate(MeetingRegenerateRequest())
        case .notion: Task { await sendToNotion() }
        case .n8n: Task { await sendToN8n() }
        case .reminders: Task { await sendToReminders() }
        case .export: exportToFile()
        }
    }

    private func continueInBackground() {
        stepperCollapsed = true
        onBack?()
    }

    // MARK: - Regenerate (confirm + Undo)

    /// Asks first only when the pipeline says the user's own edits would be
    /// overwritten; replacing untouched AI items is covered by Undo.
    private func requestRegenerate(_ request: MeetingRegenerateRequest) {
        let impact = MeetingPipeline.regenerateImpact(for: meeting, overwriteUserEdits: request.overwriteUserEdits)
        regenerateImpact = impact
        if impact.requiresConfirmation {
            pendingRegenerate = request
        } else {
            runRegenerate(request)
        }
    }

    private func regenerateMessage(for request: MeetingRegenerateRequest) -> String {
        let impact = regenerateImpact
            ?? MeetingPipeline.regenerateImpact(for: meeting, overwriteUserEdits: request.overwriteUserEdits)
        var parts: [String] = []
        var first = "LidIA rewrites the summary"
        if let provider = request.provider { first += " with \(provider.rawValue)" }
        parts.append(first + ".")
        if impact.overwritesUserEdits {
            parts.append("Your edited summary and transcript will be replaced.")
        }
        if impact.keptUserItems > 0 {
            parts.append("\(impact.keptUserItems) action item\(impact.keptUserItems == 1 ? "" : "s") you created or changed will be kept.")
        }
        if impact.replacedAIItems > 0 {
            parts.append("\(impact.replacedAIItems) untouched AI item\(impact.replacedAIItems == 1 ? "" : "s") will be replaced.")
        }
        parts.append("You can undo this.")
        return parts.joined(separator: " ")
    }

    private var regenerateResultMessage: String {
        guard let impact = regenerateImpact, impact.keptUserItems > 0 else {
            return "You can undo this."
        }
        return "Kept \(impact.keptUserItems) action item\(impact.keptUserItems == 1 ? "" : "s") you created or changed."
    }

    private func runRegenerate(_ request: MeetingRegenerateRequest) {
        guard !inFlight.contains(.regenerate) else { return }
        dismissBanner(.regenerate)

        guard !meeting.rawTranscript.isEmpty else {
            // Audio was saved but never transcribed (e.g. after a crash): transcribe it, then summarise.
            if !session.retryFromRecordedAudio(meeting, modelContext: modelContext, settings: settings, eventKitManager: eventKitManager, modelManager: modelManager) {
                show(.failure(.regenerate, message: "This meeting has no transcript to summarise."))
            }
            return
        }

        let client: any LLMClient
        let model: String
        if let provider = request.provider {
            // Never send the transcript to a provider the privacy rules block.
            if let blocked = providerBlockedError(provider, settings: settings) {
                show(.failure(.regenerate, message: blocked.localizedDescription))
                return
            }
            guard let providerClient = makeGatedClient(for: provider, settings: settings, modelManager: modelManager) else {
                show(.failure(.regenerate, message: "\(provider.rawValue) isn't available. Check it in Settings › AI."))
                return
            }
            client = providerClient
            model = defaultModelForProvider(provider, settings: settings)
        } else {
            client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .summarization)
            model = effectiveModel(for: .summary, settings: settings, taskType: .summarization)
        }

        showUndoBanner = false
        stepperCollapsed = false
        inFlight.insert(.regenerate)

        let template = settings.resolveTemplate(for: meeting)
        let vocabulary = settings.customVocabulary
        let pipeline = MeetingPipeline(llmClient: client, modelContext: modelContext)
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        let modelBefore = summaryModel

        // The pipeline keeps user-owned action items and edits; this view never
        // deletes items or clears the summary itself.
        Task {
            defer { inFlight.remove(.regenerate) }
            do {
                let snapshot = try await pipeline.regenerate(
                    meeting: meeting,
                    model: model,
                    template: template,
                    vocabulary: vocabulary,
                    overwriteUserEdits: request.overwriteUserEdits
                )
                regenerateSnapshot = snapshot
                previousSummaryModel = modelBefore
                provenance.record(model: model, for: meetingID)
                summaryModel = provenance.summaryModel(for: meetingID)
                showUndoBanner = true
            } catch {
                Self.logger.error("Regenerate failed: \(error.localizedDescription, privacy: .public)")
                // Deleted while the model ran (sync, MCP inbox): nothing to show.
                guard error as? PipelineError != .meetingDeleted,
                      LiveModel.meetingExists(meetingID, in: home) else { return }
                // A previously complete meeting was restored by the pipeline: say so here.
                // Otherwise the meeting is .failed and the stepper shows Retry / another model.
                if meeting.status != .failed {
                    show(.failure(.regenerate, error: error))
                }
            }
        }
    }

    private func undoRegenerate() {
        guard let snapshot = regenerateSnapshot else { return }
        MeetingPipeline.undoRegenerate(snapshot, meeting: meeting, modelContext: modelContext)
        if let previousSummaryModel {
            provenance.record(model: previousSummaryModel, for: meeting.id)
        } else {
            provenance.clear(for: meeting.id)
        }
        summaryModel = previousSummaryModel
        regenerateSnapshot = nil
        showUndoBanner = false
    }

    // MARK: - Re-summarise with template

    private func resummarize(with template: MeetingTemplate) {
        guard !inFlight.contains(.resummarize) else { return }
        let transcript = effectiveTranscript
        guard !transcript.isEmpty else {
            show(.failure(.resummarize, message: "There's no refined transcript to summarise yet."))
            return
        }
        lastTemplate = template
        dismissBanner(.resummarize)
        inFlight.insert(.resummarize)
        meeting.templateID = template.id
        meeting.templateAutoDetected = false
        settings.rememberTemplateChoice(for: meeting, templateID: template.id)

        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .summarization)
        let model = effectiveModel(for: .summary, settings: settings, taskType: .summarization)
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext

        Task {
            defer { inFlight.remove(.resummarize) }
            do {
                let summary = try await client.summarizeMeeting(transcript: transcript, model: model, template: template)
                // The meeting may have been deleted while the model ran.
                guard LiveModel.meetingExists(meetingID, in: home) else { return }
                meeting.summary = summary.flatSummary
                meeting.structuredSummary = summary.toStructured().flatMap { try? JSONEncoder().encode($0) }
                meeting.userEditedSummary = nil
                try modelContext.save()
                provenance.record(model: model, for: meetingID)
                summaryModel = provenance.summaryModel(for: meetingID)
            } catch {
                show(.failure(.resummarize, error: error))
            }
        }
    }

    // MARK: - Proactive notes

    /// A new note offered "Start transcribing" (not in a meeting when created).
    private var showsStartTranscribingChip: Bool {
        NoteTranscriptionState.shared.offered.contains(meeting.id)
            && !session.isRecording && meeting.rawTranscript.isEmpty && meeting.status == .complete
    }

    private func startTranscribingNote() {
        guard !session.isRecording else { return }
        NoteTranscriptionState.shared.offered.remove(meeting.id)
        let live = session.startRecording(
            modelContext: modelContext, settings: settings, modelManager: modelManager, meetingDetector: meetingDetector,
            eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor, into: meeting
        )
        NoteTranscriptionState.shared.startedFromNote.insert(live.id)
    }

    /// After a pause in typing, a note still called "New Note" gets a title
    /// from its content (local model). A title the user typed is never touched.
    private func scheduleAutoTitle(_ notes: String) {
        let store = IntentStore.shared
        guard NoteAutoTitle.shouldTitle(
            currentTitle: meeting.title, contentLength: notes.count,
            aiTitle: store.aiTitle(for: meeting.id), userTitled: store.isUserTitled(meeting.id)
        ) else { return }
        let meetingID = meeting.id
        titleDebouncer.schedule { @MainActor in
            guard !isTitling else { return }
            isTitling = true
            defer { isTitling = false }
            let content = meeting.notes
            guard let title = await NoteAutoTitle.generate(content: content, settings: settings, modelManager: modelManager),
                  let live = LiveModel.meeting(meetingID, in: modelContext),
                  // Re-check: the user may have typed a title while the model ran.
                  NoteAutoTitle.shouldTitle(currentTitle: live.title, contentLength: live.notes.count,
                                            aiTitle: store.aiTitle(for: meetingID), userTitled: store.isUserTitled(meetingID))
            else { return }
            store.setAITitle(title, contentLength: content.count, for: meetingID)
            live.title = title
            try? modelContext.save()
        }
    }

    // MARK: - Generate title / notes

    private func generateTitle() {
        guard !inFlight.contains(.generateTitle) else { return }
        dismissBanner(.generateTitle)
        let content = !meeting.notes.isEmpty ? meeting.notes
            : !effectiveSummary.isEmpty ? effectiveSummary
            : !effectiveTranscript.isEmpty ? effectiveTranscript
            : meeting.rawTranscript.map(\.word).joined(separator: " ")
        guard !content.isEmpty else {
            show(.failure(.generateTitle, message: "Add notes or record something first."))
            return
        }

        inFlight.insert(.generateTitle)
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .summarization)
        let model = effectiveModel(for: .summary, settings: settings, taskType: .summarization)
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext

        Task {
            defer { inFlight.remove(.generateTitle) }
            do {
                let title = try await client.chat(
                    messages: [
                        .init(role: "system", content: "Generate a short, descriptive title (max 8 words) for the following content. Output ONLY the title, nothing else."),
                        .init(role: "user", content: String(content.prefix(2000))),
                    ],
                    model: model,
                    format: nil
                )
                let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard LiveModel.meetingExists(meetingID, in: home) else { return }
                guard !cleaned.isEmpty else {
                    show(.failure(.generateTitle, message: "The model returned an empty title."))
                    return
                }
                meeting.title = cleaned
            } catch {
                show(.failure(.generateTitle, error: error))
            }
        }
    }

    private func generateNotes() {
        guard !inFlight.contains(.generateNotes) else { return }
        dismissBanner(.generateNotes)
        let transcript = !effectiveTranscript.isEmpty
            ? effectiveTranscript
            : meeting.rawTranscript.map(\.word).joined(separator: " ")
        let source = !transcript.isEmpty ? transcript : meeting.notes
        guard !source.isEmpty else {
            show(.failure(.generateNotes, message: "There's no transcript or notes to work from yet."))
            return
        }

        inFlight.insert(.generateNotes)
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .summarization)
        let model = effectiveModel(for: .summary, settings: settings, taskType: .summarization)
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext

        Task {
            defer { inFlight.remove(.generateNotes) }
            do {
                let notes = try await client.chat(
                    messages: [
                        .init(role: "system", content: """
                            Generate clean, well-organized meeting notes from the following content. \
                            Use bullet points, group by topic, highlight key decisions and action items. \
                            Be concise but comprehensive. Output only the notes.
                            """),
                        .init(role: "user", content: source),
                    ],
                    model: model,
                    format: nil
                )
                let generated = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                guard LiveModel.meetingExists(meetingID, in: home) else { return }
                guard !generated.isEmpty else {
                    show(.failure(.generateNotes, message: "The model returned no notes."))
                    return
                }
                // Never overwrite what the user typed: append below it.
                let existing = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                meeting.notes = existing.isEmpty ? generated : existing + "\n\n## AI notes\n" + generated
                select(tab: "notes")
            } catch {
                show(.failure(.generateNotes, error: error))
            }
        }
    }

    // MARK: - Export

    private func exportToFile() {
        dismissBanner(.export)
        do {
            guard let url = try ExportService.exportToFile(meeting) else { return } // cancelled
            show(MeetingPageBanner(operation: .export, kind: .success, title: "Exported \(url.lastPathComponent)", message: nil))
        } catch {
            show(.failure(.export, error: error))
        }
    }

    // MARK: - Integrations

    private func sendToNotion() async {
        guard !settings.notionAPIKey.isEmpty, !settings.notionDatabaseID.isEmpty else { return }
        guard !inFlight.contains(.notion) else { return }
        dismissBanner(.notion)
        inFlight.insert(.notion)
        defer { inFlight.remove(.notion) }
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        do {
            let notion = NotionClient(apiKey: settings.notionAPIKey)
            let body = """
            ## Summary
            \(effectiveSummary)

            ## Action Items
            \(meeting.actionItems.map {
                var line = "- \($0.title)"
                if let deadline = $0.displayDeadline { line += " (due: \(deadline))" }
                return line
            }.joined(separator: "\n"))
            """
            let pageID = try await notion.createMeetingPage(
                databaseID: settings.notionDatabaseID,
                title: meeting.title,
                date: meeting.date,
                duration: meeting.duration,
                bodyMarkdown: body
            )
            guard LiveModel.meetingExists(meetingID, in: home) else { return }
            meeting.notionPageID = pageID
            try modelContext.save()
            show(MeetingPageBanner(operation: .notion, kind: .success, title: "Sent to Notion", message: nil))
        } catch {
            Self.logger.error("Notion send failed: \(error.localizedDescription, privacy: .public)")
            show(.failure(.notion, error: error))
        }
    }

    private func sendToN8n() async {
        guard !inFlight.contains(.n8n) else { return }
        dismissBanner(.n8n)
        inFlight.insert(.n8n)
        defer { inFlight.remove(.n8n) }
        let payload = N8nClient.WebhookPayload(
            meetingTitle: meeting.title,
            date: ISO8601DateFormatter().string(from: meeting.date),
            duration: meeting.duration,
            summary: effectiveSummary,
            actionItems: meeting.actionItems.map {
                N8nClient.ActionItemPayload(title: $0.title, assignee: $0.assignee, deadline: $0.displayDeadline)
            },
            attendees: meeting.calendarAttendees ?? [],
            transcript: effectiveTranscript
        )
        do {
            try await MeetingWebhookSender.send(
                payload,
                to: settings.n8nWebhookURL,
                authHeader: settings.n8nAuthHeader.isEmpty ? nil : settings.n8nAuthHeader
            )
            show(MeetingPageBanner(operation: .n8n, kind: .success, title: "Sent to n8n", message: nil))
        } catch {
            show(.failure(.n8n, error: error))
        }
    }

    private func sendToReminders() async {
        guard !inFlight.contains(.reminders) else { return }
        dismissBanner(.reminders)
        inFlight.insert(.reminders)
        defer { inFlight.remove(.reminders) }
        var failed: [String] = []
        // Copied out: each reminder is an await, and items can be deleted meanwhile.
        let home = meeting.modelContext ?? modelContext
        let openItems = meeting.actionItems.filter { !$0.isCompleted }
            .map { (id: $0.id, title: $0.title, deadline: $0.displayDeadline) }
        for item in openItems {
            if let reminderID = await eventKitManager.createReminder(title: item.title, deadline: item.deadline) {
                LiveModel.actionItem(item.id, in: home)?.reminderID = reminderID
            } else {
                failed.append(item.title)
            }
        }
        try? home.save()
        if failed.isEmpty {
            show(MeetingPageBanner(operation: .reminders, kind: .success, title: "Added to Reminders", message: nil))
        } else {
            show(.failure(
                .reminders,
                message: "\(failed.count) item\(failed.count == 1 ? "" : "s") couldn't be added. Check that LidIA has Reminders access in System Settings › Privacy & Security."
            ))
        }
    }

    // MARK: - Recipes

    private func runRecipe(_ recipe: Recipe) {
        guard recipeTask == nil else { return }
        activeRecipeName = "\(recipe.emoji) \(recipe.name)"

        let context = """
        Meeting: \(meeting.title)
        Date: \(meeting.date.formatted())
        Duration: \(Int(meeting.duration / 60)) minutes
        Attendees: \(meeting.calendarAttendees?.joined(separator: ", ") ?? "Unknown")

        Summary:
        \(effectiveSummary)

        Your notes:
        \(meeting.notes)

        Action Items:
        \(meeting.actionItems.map { "- \($0.title)\($0.assignee.map { " (@\($0))" } ?? "")" }.joined(separator: "\n"))

        Transcript (first 3000 chars):
        \(String(effectiveTranscript.prefix(3000)))
        """

        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .chat)
        let model = effectiveModel(for: .query, settings: settings, taskType: .chat)
        recipeTask = Task {
            defer { recipeTask = nil }
            do {
                recipeResult = try await client.chat(
                    messages: [
                        .init(role: "system", content: recipe.prompt),
                        .init(role: "user", content: context),
                    ],
                    model: model,
                    format: nil
                )
            } catch {
                recipeResult = "Recipe failed: \(error.localizedDescription)"
            }
            showRecipeResult = true
        }
    }

    // MARK: - Sheets

    private func beginEditingSummary() {
        editableSummary = effectiveSummary
        isEditingSummary = true
    }

    private func beginEditingTranscript() {
        editableTranscript = effectiveTranscript
        isEditingTranscript = true
    }

    private var summaryEditorSheet: some View {
        NavigationStack {
            TextEditor(text: $editableSummary)
                .font(.body)
                .padding()
                .navigationTitle("Edit Summary")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isEditingSummary = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trimmed = editableSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                            meeting.userEditedSummary = trimmed.isEmpty ? nil : trimmed
                            if !trimmed.isEmpty { meeting.summary = trimmed }
                            try? modelContext.save()
                            isEditingSummary = false
                        }
                    }
                }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var transcriptEditorSheet: some View {
        NavigationStack {
            TextEditor(text: $editableTranscript)
                .font(.body.monospaced())
                .padding()
                .navigationTitle("Edit Transcript")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isEditingTranscript = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trimmed = editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                            meeting.userEditedTranscript = trimmed.isEmpty ? nil : trimmed
                            if !trimmed.isEmpty { meeting.refinedTranscript = trimmed }
                            try? modelContext.save()
                            isEditingTranscript = false
                        }
                    }
                }
        }
        .frame(minWidth: 700, minHeight: 420)
    }

    private var recipeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(activeRecipeName)
                        .font(.title2.bold())
                    MarkdownBlockView(text: recipeResult)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Recipe Result")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showRecipeResult = false
                        activeRecipeName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recipeResult, forType: .string)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

/// Posts an n8n webhook and reports failures (the shared client only logs them).
enum MeetingWebhookSender {
    struct HTTPStatusError: LocalizedError {
        let statusCode: Int
        var errorDescription: String? { "The webhook responded with HTTP \(statusCode)." }
    }

    static func send(_ payload: N8nClient.WebhookPayload, to urlString: String, authHeader: String?) async throws {
        try PrivacyGate.check(.n8n)
        guard let url = URL(string: urlString), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "The n8n webhook URL in Settings isn't valid."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader, !authHeader.isEmpty {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
    }
}
