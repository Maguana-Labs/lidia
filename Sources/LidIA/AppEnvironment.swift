import SwiftData
import SwiftUI

/// Every shared object views read with `@Environment(T.self)`.
///
/// A view whose type isn't injected traps at runtime, not at compile time, and each
/// root (a scene, or an `NSHostingView`/`NSHostingController`) has its own environment.
/// So every root injects the whole set through `injectAppEnvironment(_:)`, and a new
/// shared type is added here once instead of at each root.
@MainActor
struct AppEnvironment {
    let session: RecordingSession
    let queryService: MeetingQueryService
    let eventKitManager: EventKitManager
    let googleCalendarMonitor: GoogleCalendarMonitor
    let settings: AppSettings
    let meetingDetector: MeetingDetector
    let modelManager: ModelManager
    let ttsModelManager: TTSModelManager
    let proactiveScheduler: ProactiveScheduler
    let voiceAssistant: VoiceAssistantService
    let syncManager: SyncManager
    let updateController: UpdateController
    let backgroundContext: ModelContext?
}

extension View {
    /// Injects every shared object. Use it on every root that shows app views.
    func injectAppEnvironment(_ env: AppEnvironment) -> some View {
        self
            .environment(env.session)
            .environment(env.queryService)
            .environment(env.eventKitManager)
            .environment(env.googleCalendarMonitor)
            .environment(env.settings)
            .environment(env.meetingDetector)
            .environment(env.modelManager)
            .environment(env.ttsModelManager)
            .environment(env.proactiveScheduler)
            .environment(env.voiceAssistant)
            .environment(env.syncManager)
            .environment(env.updateController)
            .environment(\.backgroundContext, env.backgroundContext)
    }
}
