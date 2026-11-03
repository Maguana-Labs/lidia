import AppKit
import os
import SwiftData
import SwiftUI
import LidIALiveActivity
import UserNotifications

private let appLogger = Logger(subsystem: "io.lidia.app", category: "LidIAApp")

// Ensures the app activates properly when run via `swift run` (bare executable,
// not a .app bundle). Without this, the window may not become "key" and
// TextFields won't receive keyboard input.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by LidIAApp so notification actions can start recording.
    @MainActor static var session: RecordingSession?
    @MainActor static var settings: AppSettings?
    @MainActor static var modelContainer: ModelContainer?
    @MainActor static var meetingDetectorRef: MeetingDetector?
    @MainActor static var eventKitManagerRef: EventKitManager?
    @MainActor static var googleCalendarMonitorRef: GoogleCalendarMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            EventKitManager.registerNotificationCategories()
        }

        // Force macOS to re-read icon from bundle (fixes cached notification icon)
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        if FileManager.default.fileExists(atPath: lsregisterPath) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: lsregisterPath)
            task.arguments = ["-f", Bundle.main.bundlePath]
            try? task.run()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case "JOIN_AND_RECORD":
            // Merged action: open meeting link AND start recording
            let linkString = userInfo["meetingLink"] as? String
            let eventTitle = userInfo["eventTitle"] as? String
            let eventID = userInfo["eventID"] as? String
            await MainActor.run {
                if let linkString, !linkString.isEmpty, let url = URL(string: linkString) {
                    NSWorkspace.shared.open(url)
                }
                Self.startRecording(eventTitle: eventTitle, eventID: eventID)
            }
        case "JOIN_MEETING":
            // Backward compatibility with already-scheduled notifications
            let linkString = userInfo["meetingLink"] as? String
            let eventTitle = userInfo["eventTitle"] as? String
            let eventID = userInfo["eventID"] as? String
            await MainActor.run {
                if let linkString, !linkString.isEmpty, let url = URL(string: linkString) {
                    NSWorkspace.shared.open(url)
                }
                Self.startRecording(eventTitle: eventTitle, eventID: eventID)
            }
        case "RECORD_MEETING":
            let eventTitle = userInfo["eventTitle"] as? String
            let eventID = userInfo["eventID"] as? String
            await MainActor.run {
                NSApp.activate()
                Self.startRecording(eventTitle: eventTitle, eventID: eventID)
            }
        case "SKIP_RECORDING":
            break
        case NotificationDispatcher.viewActionIdentifier, UNNotificationDefaultActionIdentifier:
            let destination = userInfo[NotificationDispatcher.destinationUserInfoKey] as? String
            let eventID = userInfo[NotificationDispatcher.eventIDUserInfoKey] as? String
            if let destination {
                await MainActor.run {
                    NSApp.activate()
                    NotificationDispatcher.postNavigation(destinationRawValue: destination, eventID: eventID)
                }
            }
        default:
            break
        }
    }

    @MainActor
    static func startRecording(eventTitle: String?, eventID: String?) {
        guard let session, let settings, let container = modelContainer else { return }
        guard !session.isRecording else { return }

        // The main context, not a throwaway one: the meeting outlives this call (it is
        // recorded, then processed), and a model whose context is freed traps when used.
        let context = container.mainContext
        let meeting = session.startRecording(modelContext: context, settings: settings, meetingDetector: meetingDetectorRef, eventKitManager: eventKitManagerRef, googleCalendarMonitor: googleCalendarMonitorRef)
        if let eventTitle {
            meeting.title = eventTitle
        }
        if let eventID {
            meeting.calendarEventID = eventID
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let type = notification.request.content.userInfo["notificationType"] as? String,
           type == "recordPrompt",
           await MainActor.run(body: { Self.session?.isRecording == true }) {
            return UNNotificationPresentationOptions()
        }
        return [.banner, .sound]
    }
}

@main
struct LidIAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Made in `init` so Siri's intents (`MacSiriHost`) share them from launch.
    @State private var session: RecordingSession
    @State private var queryService = MeetingQueryService()
    @State private var eventKitManager: EventKitManager
    @State private var googleCalendarMonitor: GoogleCalendarMonitor
    @State private var settings: AppSettings
    @State private var menuBarController = MenuBarController()
    @State private var meetingDetector: MeetingDetector
    @State private var modelManager: ModelManager
    @State private var ttsModelManager = TTSModelManager()
    @State private var proactiveScheduler = ProactiveScheduler()
    @State private var voiceAssistant = VoiceAssistantService()
    @State private var voiceOrbPanel = VoiceOrbPanelController()
    @State private var syncManager = SyncManager()
    @State private var updateController = UpdateController()
    @State private var proactiveInsights = ProactiveInsightsService()
    @State private var backgroundContext: ModelContext?
    private let joinBannerController = MeetingJoinBannerController()

    init() {
        let session = RecordingSession()
        let settings = AppSettings()
        let eventKitManager = EventKitManager()
        let googleCalendarMonitor = GoogleCalendarMonitor()
        let meetingDetector = MeetingDetector()
        let modelManager = ModelManager()
        _session = State(initialValue: session)
        _settings = State(initialValue: settings)
        _eventKitManager = State(initialValue: eventKitManager)
        _googleCalendarMonitor = State(initialValue: googleCalendarMonitor)
        _meetingDetector = State(initialValue: meetingDetector)
        _modelManager = State(initialValue: modelManager)
        // Siri and Shortcuts: an intent can launch the app before any window
        // exists, so the shared intents get the library and these objects now.
        MacSiriHost.configure(MacSiriHost(
            container: sharedModelContainer,
            settings: settings,
            session: session,
            modelManager: modelManager,
            meetingDetector: meetingDetector,
            eventKitManager: eventKitManager,
            googleCalendarMonitor: googleCalendarMonitor
        ))
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: AppSchema.self)
        // Demo and snapshot libraries never sync; the real library sets its mode below.
        CloudSyncRuntime.shared.configure(mode: .off(.isolatedLibrary))
        // Demo mode: use in-memory store so real data is never touched
        if DemoDataSeeder.isDemoMode {
            let demoConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [demoConfig])
            } catch {
                fatalError("Demo mode ModelContainer failed: \(error)")
            }
        }
        #if DEBUG
        // Snapshot/design runs open a COPY of a library (never the real file).
        // Without one they get an empty in-memory library.
        if SnapshotRun.requiresIsolatedStore && SnapshotRun.storeOverrideURL == nil {
            do {
                return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            } catch {
                fatalError("Snapshot in-memory ModelContainer failed: \(error)")
            }
        }
        if let copyURL = SnapshotRun.storeOverrideURL {
            let config = ModelConfiguration(schema: schema, url: copyURL, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("LIDIA_STORE_URL could not be opened: \(error)")
            }
        }
        #endif
        // LidIA's own folder, not SwiftData's default URL, which other apps share.
        try? FileManager.default.createDirectory(at: LibraryLocation.folder, withIntermediateDirectories: true)
        LibraryLocation.migrateLegacyStoreIfNeeded()

        // iCloud sync (private database, the user's own account). Decided before opening:
        // on for new installs, asked once for an existing library, off in Local-only mode
        // and in builds without the iCloud entitlement.
        let libraryExists = FileManager.default.fileExists(atPath: LibraryLocation.storeURL.path)
        let choice = CloudSyncPreference.resolveAtLaunch(libraryExists: libraryExists)
        let wanted = LibrarySyncMode.resolve(
            isolatedLibrary: false,
            entitled: CloudKitEntitlement.isPresent,
            localOnly: PrivacyGate.isLocalOnly,
            preference: choice
        )
        // Never-pruned backups before the schema upgrade and before the first iCloud sync.
        let prepared = LibraryMilestoneBackups.prepare(
            mode: wanted, storeURL: LibraryLocation.storeURL, backupsRoot: LibraryLocation.backupsRoot
        )
        var mode = prepared.mode
        var syncProblem = prepared.problem

        let localConfig = ModelConfiguration(schema: schema, url: LibraryLocation.storeURL, cloudKitDatabase: .none)
        let syncedConfig = ModelConfiguration(schema: schema, url: LibraryLocation.storeURL, cloudKitDatabase: mode.cloudKitDatabase)
        // Never deletes the store: daily rolling backup, and on repeated open failure the
        // store is moved to a timestamped backup folder and a notice is recorded for the UI
        // (`LibraryHealth.shared.recoveryNotice`).
        let result = StoreGuardian.openContainer(
            storeURL: localConfig.url,
            backupsRoot: LibraryLocation.backupsRoot,
            open: { _ in
                if mode.isICloud {
                    do {
                        return try ModelContainer(for: schema, configurations: [syncedConfig])
                    } catch {
                        // Not a library problem: open it without sync and say why in Settings.
                        appLogger.error("Opening the library with iCloud sync failed: \(error, privacy: .public)")
                        mode = .off(.turnedOff)
                        syncProblem = "iCloud sync couldn't start (\(error.localizedDescription)). Your library opened on this Mac only."
                    }
                }
                return try ModelContainer(for: schema, configurations: [localConfig])
            },
            openInMemory: {
                try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            }
        )
        if let notice = result.notice {
            appLogger.error("Library recovered; previous library backed up to \(notice.backupPath, privacy: .public)")
            StoreGuardian.saveNotice(notice)
            // A temporary in-memory library never syncs. (A fresh library that replaced a
            // corrupt one opened with `mode`, and refills from iCloud when syncing.)
            if notice.isTemporaryLibrary { mode = .off(.isolatedLibrary) }
        }
        // Meetings already in the library were made on this Mac: claim them before launch
        // recovery runs and before other devices' meetings arrive. Not on a temporary
        // library, or the one-time claim would be spent on nothing.
        if result.notice?.isTemporaryLibrary != true {
            LegacyMeetingOwnership.claimOnce(in: result.container.mainContext)
        }
        CloudSyncRuntime.shared.configure(mode: mode, startupError: syncProblem)
        return result.container
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .injectAppEnvironment(appEnvironment)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .onAppear {
                    if backgroundContext == nil {
                        let ctx = ModelContext(sharedModelContainer)
                        ctx.autosaveEnabled = true
                        backgroundContext = ctx
                    }

                    // Recovery: re-queue meetings interrupted mid-processing by a crash
                    // (the drain loop picks them up), fail empty ones with a clear message.
                    ProcessingRecovery.recoverOnceAtLaunch(in: sharedModelContainer.mainContext)

                    // Demo mode: seed with realistic dummy data for screenshots
                 if DemoDataSeeder.isDemoMode {
                        DemoDataSeeder.seed(context: sharedModelContainer.mainContext)
                        // Disable live calendar so real events don't show
                        settings.googleCalendarEnabled = true
                        settings.calendarEnabled = false
                        // Inject fake upcoming events
                        googleCalendarMonitor.isSignedIn = true
                        googleCalendarMonitor.weekEvents = DemoDataSeeder.fakeUpcomingEvents()
                    }

                    AppDelegate.session = session
                    AppDelegate.settings = settings
                    AppDelegate.modelContainer = sharedModelContainer
                    AppDelegate.meetingDetectorRef = meetingDetector
                    AppDelegate.eventKitManagerRef = eventKitManager
                    AppDelegate.googleCalendarMonitorRef = googleCalendarMonitor
                    eventKitManager.backgroundContext = backgroundContext

                    menuBarController.setup(
                        environment: appEnvironment,
                        modelContainer: sharedModelContainer
                    )
                    // A snapshot run only renders the window: no calendar sync,
                    // notifications, AI insights, sync, meeting detection or model loading.
                    guard !SnapshotRun.isActive else {
                        MainWindowSnapshotter.installIfRequested(settings: settings, calendar: googleCalendarMonitor)
                        #if DEBUG
                        MenuBarSnapshotter.installIfRequested(menuBar: menuBarController, session: session)
                        #endif
                        return
                    }
                    if !DemoDataSeeder.isDemoMode {
                        googleCalendarMonitor.configure(settings: settings)
                    }
                    // iCloud sync status (account, last sync, errors) for Settings.
                    CloudSyncRuntime.shared.start()

                    proactiveScheduler.configure(
                        settings: settings,
                        calendarMonitor: googleCalendarMonitor,
                        eventKitManager: eventKitManager,
                        modelContext: backgroundContext!
                    )

                    proactiveInsights.startScheduler(
                        settings: settings,
                        modelContext: backgroundContext!,
                        modelManager: modelManager,
                        googleCalendarMonitor: googleCalendarMonitor,
                        eventKitManager: eventKitManager
                    )

                    appLogger.info("Configuring voiceAssistant with backgroundContext=\(backgroundContext != nil)")
                    voiceAssistant.configure(
                        settings: settings,
                        modelManager: modelManager,
                        ttsModelManager: ttsModelManager,
                        queryService: queryService,
                        backgroundContext: backgroundContext!
                    )
                    appLogger.info("VoiceAssistant configured — voiceEnabled=\(settings.voiceEnabled)")
                    voiceAssistant.inputController.onSilenceDetected = { [weak voiceAssistant] in
                        voiceAssistant?.onUserFinishedSpeaking()
                    }

                    // Dictation everywhere (off until turned on in Settings › Dictation).
                    if !DemoDataSeeder.isDemoMode {
                        DictationController.shared.configure(settings: settings, modelManager: modelManager)
                    }

                    syncManager.configure(settings: settings, modelContext: backgroundContext!)

                    // Warm keepalive: auto-load last-used MLX model on launch
                    if settings.llmProvider == .mlx {
                        modelManager.warmKeepalive()
                    }
                    modelManager.startMemoryPressureMonitoring()

                    meetingDetector.calendarMeetingNow = { [googleCalendarMonitor, eventKitManager, settings] in
                        currentCalendarMeetingTitle(googleCalendarMonitor: googleCalendarMonitor, eventKitManager: eventKitManager, userName: settings.displayName)
                    }
                    if settings.autoDetectMeetings {
                        meetingDetector.startMonitoring()
                    }
                }
                .onChange(of: settings.autoDetectMeetings) { _, enabled in
                    if enabled {
                        meetingDetector.startMonitoring()
                    } else {
                        meetingDetector.stopMonitoring()
                        menuBarController.closeMeetingDetected()
                    }
                }
                .onChange(of: meetingDetector.detectedApp?.bundleID) { _, _ in
                    handleMeetingDetection()
                }
                .onChange(of: proactiveScheduler.pendingBannerMeeting) { _, pending in
                    handlePendingBanner(pending)
                }
                .onChange(of: voiceAssistant.isActive) { _, active in
                    if active {
                        voiceOrbPanel.show(service: voiceAssistant)
                    } else {
                        voiceOrbPanel.close()
                    }
                }
                .onChange(of: voiceAssistant.inputController.state) { _, newState in
                    if newState == .thinking {
                        voiceOrbPanel.playThinkingSound()
                    } else {
                        voiceOrbPanel.stopThinkingSound()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .voiceToggleRequested)) { _ in
                    voiceAssistant.toggle()
                }
                .onChange(of: settings.syncEnabled) { _, _ in
                    syncManager.configure(settings: settings, modelContext: backgroundContext!)
                }
                .onChange(of: settings.syncServerURL) { _, _ in
                    syncManager.configure(settings: settings, modelContext: backgroundContext!)
                }
                .onChange(of: settings.syncAuthToken) { _, _ in
                    syncManager.configure(settings: settings, modelContext: backgroundContext!)
                }
                .onChange(of: settings.localOnlyMode) { _, _ in
                    // On: stop sync now. Off: resume it without a relaunch.
                    syncManager.configure(settings: settings, modelContext: backgroundContext!)
                }
                .onReceive(NotificationCenter.default.publisher(for: .meetingDidFinishProcessing)) { notification in
                    if let meeting = notification.object as? Meeting {
                        syncManager.pushMeeting(meeting)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.automatic)
        .commands { AppCommands() }

        #if DEBUG
        let _ = SettingsSnapshotter.installIfRequested(settings: settings)
        #endif

        Settings {
            SettingsView(settings: settings)
                .injectAppEnvironment(appEnvironment)
                .modelContainer(sharedModelContainer)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
    }

    /// The shared objects every root injects (`injectAppEnvironment`).
    private var appEnvironment: AppEnvironment {
        AppEnvironment(
            session: session,
            queryService: queryService,
            eventKitManager: eventKitManager,
            googleCalendarMonitor: googleCalendarMonitor,
            settings: settings,
            meetingDetector: meetingDetector,
            modelManager: modelManager,
            ttsModelManager: ttsModelManager,
            proactiveScheduler: proactiveScheduler,
            voiceAssistant: voiceAssistant,
            syncManager: syncManager,
            updateController: updateController,
            backgroundContext: backgroundContext
        )
    }

    private func handlePendingBanner(_ pending: PendingMeetingBanner?) {
        guard let pending, !session.isRecording else {
            joinBannerController.close()
            return
        }

        joinBannerController.show(
            meeting: pending,
            onJoin: { [session, settings, backgroundContext, proactiveScheduler, eventKitManager, googleCalendarMonitor] in
                guard !session.isRecording, let bgCtx = backgroundContext else { return }

                // Open the meeting link if available
                if let link = pending.meetingLink {
                    NSWorkspace.shared.open(link)
                }

                // Start recording with event metadata
                let meeting = session.startRecording(modelContext: bgCtx, settings: settings, meetingDetector: meetingDetector, eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor)
                meeting.title = pending.title
                meeting.calendarEventID = pending.eventID
                meeting.calendarAttendees = pending.attendees
                session.enableAutoFinish(calendarEndTime: pending.end, meetingDetector: meetingDetector)

                proactiveScheduler.dismissBanner(eventID: pending.eventID)
            },
            onDismiss: { [proactiveScheduler] in
                proactiveScheduler.dismissBanner(eventID: pending.eventID)
            }
        )
    }

    /// "Zoom call started" under the menu bar icon (the top-right banner when the icon
    /// can't be seen). It goes away when the app releases the mic: the detector clears
    /// `detectedApp`, which runs this again.
    private func handleMeetingDetection() {
        guard settings.autoDetectMeetings,
              !session.isRecording,
              !meetingDetector.isDismissed,
              let detected = meetingDetector.detectedApp else {
            menuBarController.closeMeetingDetected()
            return
        }

        let state = MeetingDetectedActivityState(
            meetingName: detected.name,
            appName: MeetingDetectionBannerView.appName(bundleID: detected.bundleID),
            bundleID: detected.bundleID,
            calendarTitle: meetingDetector.calendarMeetingNow(),
            detectedAt: .now
        )
        menuBarController.showMeetingDetected(state, actions: MeetingDetectedActions(
            record: { [session, settings, backgroundContext, meetingDetector, googleCalendarMonitor, eventKitManager] in
                guard !session.isRecording, let bgCtx = backgroundContext else { return }
                // Matches the calendar meeting on now, if any; otherwise the title comes
                // from the AI notes (not "Meeting — Zoom").
                _ = session.startRecording(modelContext: bgCtx, settings: settings, meetingDetector: meetingDetector, eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor)
                meetingDetector.dismiss()
            },
            notNow: { [meetingDetector] in
                meetingDetector.dismiss()
            },
            never: { [meetingDetector] in
                meetingDetector.neverDetect(bundleID: detected.bundleID)
            }
        ))
    }

}

/// Title of a calendar meeting (others invited or a call link) on now or about to start,
/// for meeting detection.
@MainActor
func currentCalendarMeetingTitle(
    googleCalendarMonitor: GoogleCalendarMonitor,
    eventKitManager: EventKitManager,
    userName: String
) -> String? {
    var candidates: [RecordingCalendarMatch.Candidate] = []
    if googleCalendarMonitor.isSignedIn {
        candidates += googleCalendarMonitor.weekEvents.map {
            .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, attendees: $0.attendees, hasMeetingLink: $0.meetingLink != nil)
        }
    }
    candidates += eventKitManager.upcomingEvents.map {
        .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, attendees: $0.attendees, hasMeetingLink: $0.meetingLink != nil)
    }
    // On now, or starting in the next 5 minutes.
    let now = Date()
    return RecordingCalendarMatch.pick(candidates.filter { $0.start <= now.addingTimeInterval(5 * 60) }, now: now, currentUserName: userName)?.title
}
