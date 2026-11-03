import LidIAAppIntents
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.backgroundContext) private var backgroundContext
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingSession.self) private var session
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(ModelManager.self) private var modelManager
    @Environment(MeetingQueryService.self) private var queryService
    @Environment(ProactiveScheduler.self) private var proactiveScheduler
    @Environment(VoiceAssistantService.self) private var voiceAssistant

    @State private var nav = NavigationState()
    @State private var chatViewModel = ChatBarViewModel()

    @State private var showStopConfirmation = false
    @State private var showGranolaImport = false
    @State private var meetingPendingDelete: Meeting?
    /// Shown instead of the delete confirmation while a meeting is still being processed.
    @State private var deletionBlockedMessage: String?
    /// Question to ask as soon as the ⌘K palette opens (from search).
    @State private var paletteInitialQuery = ""
    /// Changes on every palette open so it starts fresh.
    @State private var paletteSession = UUID()

    private var showSetupWizard: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedSetup && !SnapshotRun.isActive },
            set: { if !$0 { settings.hasCompletedSetup = true } }
        )
    }

    private var agenda: [AgendaEvent] {
        AgendaSource.events(eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor)
    }

    var body: some View {
        mainContent
            .environment(\.chatOpenMeeting, openMeetingAction)
            .sheet(isPresented: showSetupWizard) {
                SetupWizardView()
                    .interactiveDismissDisabled()
            }
            .overlay(alignment: .top) { askPaletteOverlay }
            .sheet(isPresented: $showGranolaImport) {
                GranolaImportSheet()
            }
            .background { SettingsOpenerRegistrar() }
            .modifier(CloudSyncConsentPrompt(enabled: settings.hasCompletedSetup && !SnapshotRun.isActive))
            .onAppear {
                eventKitManager.startPolling(settings: settings)
                chatViewModel.configure(settings: settings, modelContext: modelContext, modelManager: modelManager, backgroundContext: backgroundContext)
                chatViewModel.eventKitManager = eventKitManager
                chatViewModel.updateSelectedMeeting(nav.selectedMeeting)
                queryService.modelManager = modelManager
                proactiveScheduler.isRecordingProvider = { [session] in session.isRecording }
                MeetingAttendeeContext.currentUserName = settings.displayName
                MainWindowSnapshotDriver.shared = MainWindowSnapshotDriver(
                    nav: nav,
                    openAskPalette: { openAskPalette(query: $0) },
                    closeAskPalette: { closeAskPalette() }
                )
                MainWindowSnapshotDriver.shared?.session = session
                #if DEBUG
                MainWindowSnapshotDriver.shared?.chatViewModel = chatViewModel
                MainWindowSnapshotDriver.shared?.showAskAnswer = { question, answer in
                    chatViewModel.showSnapshotAnswer(question: question, answer: answer)
                    openAskPalette(query: "")
                }
                #endif
                // A snapshot run renders a copy of the library; it never processes it.
                guard !SnapshotRun.isActive else { return }
                session.resumeQueuedProcessing(
                    modelContext: modelContext,
                    settings: settings,
                    eventKitManager: eventKitManager,
                    modelManager: modelManager
                )
            }
            .onChange(of: settings.displayName) { _, name in
                MeetingAttendeeContext.currentUserName = name
            }
            .onDisappear {
                eventKitManager.stopPolling()
            }
            .onChange(of: settings.calendarEnabled) { _, enabled in
                if enabled {
                    eventKitManager.startPolling(settings: settings)
                } else {
                    eventKitManager.stopPolling()
                }
            }
            .onChange(of: session.isRecording) { _, isRecording in
                if isRecording {
                    chatViewModel.recordingState = .recording
                } else if chatViewModel.recordingState == .recording {
                    chatViewModel.recordingState = .justFinished
                }
            }
            .onChange(of: nav.selectedMeeting) { _, meeting in
                chatViewModel.updateSelectedMeeting(meeting)
                guard let meeting else { return }
                SiriDonations.openedMeeting(meeting)
                if nav.detailDestination != .meeting, nav.detailDestination != .calendarEvent {
                    nav.meetingReturnDestination = nav.detailDestination
                }
                nav.detailDestination = .meeting
                switch meeting.status {
                case .recording:
                    nav.selectedTab = "transcript"
                case .complete:
                    nav.selectedTab = (meeting.summary.isEmpty && meeting.rawTranscript.isEmpty) ? "notes" : "summary"
                default:
                    nav.selectedTab = "summary"
                }
            }
            .onChange(of: nav.detailDestination) { _, _ in
                // Clear pushed views (PersonDetail, ChatThread, …) when switching workspaces
                nav.detailPath = NavigationPath()
            }
            .modifier(appNotificationHandlers)
            .modifier(SiriRequestHandler(nav: nav, newNote: { createNote(focusMode: false) }, ask: { openAskPalette(query: $0) }))
            .toolbar { mainToolbar }
            .focusedSceneValue(\.appActions, appActions)
            .confirmationDialog(
                "Stop recording?",
                isPresented: $showStopConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop and Process") { stopRecording() }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("LidIA will stop capturing audio and start writing the summary.")
            }
            .confirmationDialog(
                "Delete “\(meetingPendingDelete.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "")”?",
                isPresented: Binding(
                    get: { meetingPendingDelete != nil },
                    set: { if !$0 { meetingPendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: meetingPendingDelete
            ) { meeting in
                Button("Delete Meeting", role: .destructive) { deleteMeeting(meeting) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The notes, transcript, summary and action items will be removed. This can’t be undone.")
            }
            .alert(
                "Can’t delete this meeting yet",
                isPresented: Binding(
                    get: { deletionBlockedMessage != nil },
                    set: { if !$0 { deletionBlockedMessage = nil } }
                ),
                presenting: deletionBlockedMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        if settings.voiceEnabled {
            ToolbarItem(placement: .automatic) {
                Button {
                    voiceAssistant.toggle()
                } label: {
                    Label("Voice Assistant", systemImage: voiceAssistant.isActive ? "waveform.circle.fill" : "waveform.circle")
                }
                .help("Voice Assistant (\(voiceAssistant.inputController.hotkeyDisplayString))")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                openAskPalette()
            } label: {
                Label("Ask LidIA", systemImage: "sparkles")
            }
            .help("Ask LidIA (⌘K)")
        }
    }

    /// Filters the sidebar to an import's folder and opens its newest meeting.
    private func showImportedFolder(_ folder: String?) {
        guard let folder else { return }
        NSApp.activate()
        nav.searchText = ""
        nav.columnVisibility = .all
        nav.selectedFolder = folder
        // Imported meetings keep their source even after moving into a project.
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.folder == folder || $0.externalSourceID != nil },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let newest = try? modelContext.fetch(descriptor).first {
            nav.show(newest)
        }
    }

    private var appActions: AppActions {
        let selected = nav.detailDestination == .meeting ? nav.selectedMeeting : nil
        return AppActions(
            isRecording: session.isRecording,
            newNote: { createNote(focusMode: false) },
            quickNote: { createNote(focusMode: true) },
            toggleRecording: {
                if session.isRecording { showStopConfirmation = true } else { startRecording() }
            },
            search: {
                nav.columnVisibility = .all
                nav.isSearchPresented = true
            },
            ask: { openAskPalette() },
            showToday: { nav.showToday() },
            exportSelectedMeeting: selected.map { meeting in
                { ExportService.exportToFileShowingErrors(meeting) }
            },
            deleteSelectedMeeting: selected.flatMap { meeting in
                meeting.status == .recording ? nil : { requestDelete(meeting) }
            }
        )
    }

    /// Citations and source cards open the meeting, at the cited moment of
    /// the transcript when the excerpt carries one.
    private var openMeetingAction: ChatOpenMeetingAction {
        let nav = nav
        return ChatOpenMeetingAction { id, time in
            guard let context = AppDelegate.modelContainer?.mainContext,
                  let meeting = try? context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first else { return }
            if nav.isAskPalettePresented { withAnimation(.easeOut(duration: 0.15)) { nav.isAskPalettePresented = false } }
            nav.show(meeting)
            if let time {
                nav.transcriptSeekRequest = time
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            SidebarView(
                nav: nav,
                agenda: agenda,
                onRecordEvent: { event, join in startRecording(from: event, join: join) },
                onRecordNow: { startRecording() },
                onStopRecording: { showStopConfirmation = true },
                onDeleteMeeting: { requestDelete($0) },
                onRetryMeeting: { retryProcessing($0) },
                onAsk: { openAskPalette(query: $0) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        createNote(focusMode: false)
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .help("New Note (⌘N)")
                }
                ToolbarItem(placement: .automatic) {
                    SettingsLink {
                        Label("Settings", systemImage: "gear")
                    }
                    .help("Settings (⌘,)")
                }
            }
        } detail: {
            NavigationStack(path: $nav.detailPath) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationDestination(for: UUID.self) { threadID in
                        ChatThreadView(
                            viewModel: chatViewModel,
                            threadID: threadID,
                            availableModels: settings.availableModels
                        )
                    }
            }
        }
        .searchable(
            text: $nav.searchText,
            isPresented: $nav.isSearchPresented,
            placement: .sidebar,
            prompt: "Search meetings, people, actions"
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch nav.detailDestination {
        case .meeting:
            if let meeting = nav.selectedMeeting {
                MeetingDetailView(
                    meeting: meeting,
                    selectedTab: $nav.selectedTab,
                    nav: nav,
                    backTitle: nav.meetingBackTitle,
                    onBack: { nav.goBackFromMeeting() },
                    onAsk: { openAskPalette(query: $0) },
                    onDelete: { requestDelete($0) }
                )
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "waveform",
                    description: Text("Select a meeting, press ⌘N for a new note, or ⌘R to record.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .home:
            TodayView(
                agenda: agenda,
                onOpenEvent: { nav.show($0) },
                onRecordEvent: { event, join in startRecording(from: event, join: join) },
                onRecordNow: { startRecording() },
                onStopRecording: { showStopConfirmation = true },
                onOpenMeeting: { nav.show($0) },
                onRetryMeeting: { retryProcessing($0) },
                onNewNote: { createNote(focusMode: false) },
                onOpenActionItems: { nav.show(.actionItems) },
                onOpenLibrary: {
                    nav.librarySeriesKey = nil
                    nav.show(.library)
                },
                onOpenProject: { nav.showProject($0) },
                onOpenSeries: { key in
                    nav.librarySeriesKey = key
                    nav.show(.library)
                },
                onAsk: { openAskPalette(query: $0) }
            )

        case .library:
            MeetingsLibraryView(
                nav: nav,
                onRetryMeeting: { retryProcessing($0) },
                onDeleteMeeting: { requestDelete($0) },
                onAsk: { openAskPalette(query: $0) }
            )

        case .calendarEvent:
            if let event = nav.selectedCalendarEvent {
                CalendarEventDetailView(event: event, onRecord: { notes, join in
                    startRecording(from: event, join: join, notes: notes)
                }, onBack: {
                    nav.showToday()
                })
            }

        case .actionItems:
            ActionItemDashboardView(selectedMeeting: $nav.selectedMeeting)

        case .project:
            if let project = nav.selectedProject {
                ProjectDetailView(
                    name: project,
                    nav: nav,
                    onAsk: { openAskPalette(query: $0) }
                )
                .id(project)
            }

        case .people:
            PeopleView(selectedMeeting: $nav.selectedMeeting)

        case .chat:
            ChatHomeView(viewModel: chatViewModel, navigateToThreadID: nil, path: $nav.detailPath)
        }
    }

    // MARK: - Ask palette

    @ViewBuilder
    private var askPaletteOverlay: some View {
        if nav.isAskPalettePresented {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { closeAskPalette() }
                    .accessibilityHidden(true)
                AskPaletteView(
                    viewModel: chatViewModel,
                    initialQuery: paletteInitialQuery,
                    onClose: { closeAskPalette() },
                    onOpenThread: { threadID in
                        closeAskPalette()
                        nav.show(.chat)
                        chatViewModel.openThread(id: threadID)
                    }
                )
                .id(paletteSession)
                .padding(.top, 70)
            }
            .transition(.opacity)
        }
    }

    /// App-wide notifications (menu bar, notifications, menus) that route into this window.
    /// Kept out of `body` so the modifier chain stays small enough to type-check quickly.
    private var appNotificationHandlers: some ViewModifier {
        AppNotificationHandlers(
            openToday: { nav.showToday() },
            openActionItems: { nav.show(.actionItems) },
            openMeeting: { id in
                let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
                if let meeting = try? modelContext.fetch(descriptor).first {
                    nav.show(meeting)
                }
            },
            createNote: { createNote(focusMode: false) },
            openAsk: { openAskPalette() },
            openGranolaImport: {
                NSApp.activate()
                showGranolaImport = true
            },
            showImportedFolder: { showImportedFolder($0) }
        )
    }

    private func openAskPalette(query: String = "") {
        paletteInitialQuery = query
        paletteSession = UUID()
        withAnimation(.easeOut(duration: 0.15)) { nav.isAskPalettePresented = true }
    }

    private func closeAskPalette() {
        withAnimation(.easeIn(duration: 0.12)) { nav.isAskPalettePresented = false }
        paletteInitialQuery = ""
    }

    // MARK: - Actions

    /// Ad-hoc recording (no calendar event).
    private func startRecording() {
        guard !session.isRecording else { return }
        let meeting = session.startRecording(modelContext: modelContext, settings: settings, modelManager: modelManager, meetingDetector: meetingDetector, eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor)
        nav.show(meeting)
        SiriDonations.donate(StartRecordingIntent())
    }

    private func startRecording(from event: AgendaEvent, join: Bool, notes: String = "") {
        guard !session.isRecording else { return }
        let meeting = session.startRecording(
            from: event,
            join: join,
            notes: notes,
            modelContext: modelContext,
            settings: settings,
            modelManager: modelManager,
            meetingDetector: meetingDetector
        )
        nav.show(meeting)
    }

    /// A new note. During a meeting (calendar or a meeting app on the mic) it
    /// starts transcribing, per Settings → Recording; otherwise it offers to.
    private func createNote(focusMode: Bool) {
        var meeting = NoteFactory.makeNote(in: modelContext)
        let decision = NoteTranscriptionPolicy.decide(
            mode: settings.noteTranscription,
            calendarMeetingNow: meetingDetector.calendarMeetingNow() != nil,
            meetingAppOnMic: meetingDetector.detectedApp != nil,
            alreadyRecording: session.isRecording || SnapshotRun.isActive
        )
        switch decision {
        case .start:
            meeting = session.startRecording(
                modelContext: modelContext, settings: settings, modelManager: modelManager, meetingDetector: meetingDetector,
                eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor, into: meeting
            )
            NoteTranscriptionState.shared.startedFromNote.insert(meeting.id)
        case .offer:
            NoteTranscriptionState.shared.offered.insert(meeting.id)
        case .none:
            break
        }
        nav.show(meeting)
        nav.selectedTab = "notes"
        SiriDonations.donate(NewNoteIntent())
        if focusMode {
            withAnimation { nav.columnVisibility = .detailOnly }
        }
    }

    private func stopRecording() {
        session.stopRecording(modelContext: modelContext, settings: settings, eventKitManager: eventKitManager)
        SiriDonations.donate(StopRecordingIntent())
    }

    /// Re-queue a meeting that has a transcript and kick the processing queue.
    private func retryProcessing(_ meeting: Meeting) {
        guard !meeting.rawTranscript.isEmpty else {
            // No transcript: transcribe the saved recording if there is one.
            let queued = session.retryFromRecordedAudio(
                meeting,
                modelContext: modelContext,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: modelManager
            )
            if !queued { nav.show(meeting) }
            return
        }
        meeting.status = .queued
        meeting.processingError = nil
        meeting.processingRetryCount = 0
        try? modelContext.save()
        let id = meeting.id
        Task {
            await DeferredMeetingProcessingQueue.shared.enqueue(id)
            session.resumeQueuedProcessing(
                modelContext: modelContext,
                settings: settings,
                eventKitManager: eventKitManager,
                modelManager: modelManager
            )
        }
    }

    /// Asks to confirm the delete, or says why the meeting can't be deleted yet.
    private func requestDelete(_ meeting: Meeting) {
        if let reason = MeetingDeletionPolicy.blockReason(
            status: meeting.status,
            isBeingProcessed: session.isProcessing(meetingID: meeting.id)
        ) {
            deletionBlockedMessage = reason
        } else {
            meetingPendingDelete = meeting
        }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        // Processing may have started since the dialog opened: the pipeline would go on
        // writing to the deleted meeting.
        if let reason = MeetingDeletionPolicy.blockReason(
            status: meeting.status,
            isBeingProcessed: session.isProcessing(meetingID: meeting.id)
        ) {
            deletionBlockedMessage = reason
            return
        }
        if nav.selectedMeeting?.id == meeting.id {
            nav.showToday()
        }
        let id = meeting.id
        modelContext.delete(meeting)
        try? modelContext.save()
        SpotlightIndexer.removeMeeting(id)
        Task { await DeferredMeetingProcessingQueue.shared.remove(id) }
    }
}

private struct AppNotificationHandlers: ViewModifier {
    let openToday: () -> Void
    let openActionItems: () -> Void
    let openMeeting: (UUID) -> Void
    let createNote: () -> Void
    let openAsk: () -> Void
    let openGranolaImport: () -> Void
    let showImportedFolder: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .lidiaOpenHomeWorkspace)) { _ in openToday() }
            .onReceive(NotificationCenter.default.publisher(for: .lidiaOpenActionItemsWorkspace)) { _ in openActionItems() }
            .onReceive(NotificationCenter.default.publisher(for: .lidiaOpenMeeting)) { note in
                guard let idString = note.userInfo?[NotificationDispatcher.eventIDUserInfoKey] as? String,
                      let id = UUID(uuidString: idString) else { return }
                openMeeting(id)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lidiaCreateNote)) { _ in createNote() }
            .onReceive(NotificationCenter.default.publisher(for: .lidiaOpenAsk)) { _ in openAsk() }
            .onReceive(NotificationCenter.default.publisher(for: .lidiaOpenGranolaImport)) { _ in openGranolaImport() }
            .onReceive(NotificationCenter.default.publisher(for: .lidiaShowImportedFolder)) { note in
                showImportedFolder(note.object as? String)
            }
    }
}
