import LidIAKit
import SwiftData
import SwiftUI
import os

@main
struct LidIAiOSApp: App {
    @State private var services: AppServices

    init() {
        _services = State(initialValue: AppServices())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.settings)
                .environment(services.router)
                .environment(services.toasts)
                .environment(services.intelligence)
                .environment(services.processor)
                .environment(services.recorder)
                .environment(services.sync)
                .environment(services.calendar)
                .environment(services.cloudSync)
                .onOpenURL { services.router.handle(url: $0) }
                .task { services.launch() }
        }
        .modelContainer(services.container)
    }
}

/// Everything the app shares, built once at launch.
@MainActor
final class AppServices {
    private static let logger = Logger(subsystem: "io.lidia.ios", category: "App")

    let options: LaunchOptions
    let container: ModelContainer
    /// iCloud sync status (account, last sync, errors, why it didn't start) for Settings.
    let cloudSync: CloudSyncMonitor
    /// False when the library couldn't open and the app runs on a temporary one.
    private let libraryIsPersistent: Bool
    let settings: AppSettings
    let router = AppRouter()
    let toasts = ToastCenter()
    let intelligence: Intelligence
    let processor: MeetingProcessor
    let recorder: RecordingController
    let sync: SyncCoordinator
    let calendar = CalendarService()
    private var launched = false

    init() {
        options = LaunchOptions()
        settings = options.demo ? AppSettings(defaults: .standard, persist: false) : AppSettings()
        let library = Self.makeContainer(inMemory: options.demo, iCloud: settings.iCloudSync && !settings.localOnly)
        container = library.container
        cloudSync = CloudSyncMonitor(isActive: library.syncing, startupProblem: library.problem)
        libraryIsPersistent = library.persistent
        intelligence = Intelligence(settings: settings)
        processor = MeetingProcessor(intelligence: intelligence)
        recorder = RecordingController(container: container, settings: settings, processor: processor)
        sync = SyncCoordinator(settings: settings, container: container)
        sync.iCloudActive = library.syncing

        AppRouter.current = router
        RecordingController.current = recorder
        // Siri and Shortcuts: an intent can launch the app before any view exists.
        IOSSiriHost.configure(settings: settings, intelligence: intelligence, container: container, demo: options.demo)
        processor.onFinished = { [weak sync, weak recorder] meeting in
            sync?.push(meeting)
            recorder?.notesFinished(for: meeting.id, succeeded: true)
        }
        processor.onFailed = { [weak recorder] id in
            recorder?.notesFinished(for: id, succeeded: false)
        }
    }

    func launch() {
        guard !launched else { return }
        launched = true
        #if DEBUG
        if options.demo {
            DemoContent.install(services: self)
            return
        }
        #endif
        // Meetings already here were made on this iPhone: claim them before recovery runs
        // and before the Mac's meetings arrive through iCloud.
        if libraryIsPersistent {
            LegacyMeetingOwnership.claimOnce(in: container.mainContext)
        }
        cloudSync.start()
        calendar.refresh()
        sync.configure()
        RecordingController.recoverInterrupted(in: container.mainContext, processor: processor)
    }

    /// The library, in the same schema as the Mac's (`LidIASchema`), synced through the
    /// shared iCloud container unless sync is off or Local-only is on. The store file is
    /// the one earlier builds used (Application Support/LidIA.store), so meetings already
    /// on this iPhone stay and upload on the first sync.
    ///
    /// Never crashes on launch. If CloudKit can't start, the same store opens without
    /// sync and Settings says why (not silently, as before). If even that fails, the app
    /// runs on a temporary in-memory library.
    static func makeContainer(inMemory: Bool, iCloud: Bool) -> (container: ModelContainer, syncing: Bool, persistent: Bool, problem: String?) {
        let schema = LidIASchema.schema
        if inMemory {
            let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            return (container, false, false, nil)
        }
        var problem: String?
        if iCloud {
            do {
                let config = ModelConfiguration("LidIA", schema: schema, cloudKitDatabase: .private(LidIASchema.cloudKitContainerID))
                return (try ModelContainer(for: schema, configurations: [config]), true, true, nil)
            } catch {
                logger.error("iCloud library failed to open, opening it without sync: \(error.localizedDescription, privacy: .public)")
                problem = "iCloud sync couldn't start (\(error.localizedDescription)). Your meetings are on this iPhone only for now."
            }
        }
        do {
            let config = ModelConfiguration("LidIA", schema: schema, cloudKitDatabase: .none)
            return (try ModelContainer(for: schema, configurations: [config]), false, true, problem)
        } catch {
            logger.fault("Local store failed, using memory: \(error.localizedDescription, privacy: .public)")
            let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            return (container, false, false, "LidIA couldn't open your library (\(error.localizedDescription)). Changes made now won't be saved.")
        }
    }
}

/// Launch arguments. `-demo` seeds a sample library in memory (DEBUG only);
/// `-screen <name>` opens a screen directly, for screenshots.
struct LaunchOptions {
    let demo: Bool
    let screen: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        demo = arguments.contains("-demo")
        if let index = arguments.firstIndex(of: "-screen"), arguments.indices.contains(index + 1) {
            screen = arguments[index + 1]
        } else {
            screen = nil
        }
        #else
        demo = false
        screen = nil
        #endif
    }
}
