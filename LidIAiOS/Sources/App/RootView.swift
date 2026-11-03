import LidIAKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RecordingController.self) private var recorder
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncCoordinator.self) private var sync
    @Environment(CalendarService.self) private var calendar
    @Environment(Intelligence.self) private var intelligence

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView().meetingDestinations()
                }
            }
            Tab("Meetings", systemImage: "rectangle.stack", value: AppTab.meetings) {
                NavigationStack(path: $router.meetingsPath) {
                    MeetingsView().meetingDestinations()
                }
            }
            Tab("Actions", systemImage: "checklist", value: AppTab.actions) {
                NavigationStack(path: $router.actionsPath) {
                    ActionItemsView().meetingDestinations()
                }
            }
            Tab("Ask", systemImage: "sparkles", value: AppTab.ask) {
                NavigationStack(path: $router.askPath) {
                    AskView(scope: nil).meetingDestinations()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(LiveRecordingAccessory())
        .fullScreenCover(isPresented: $router.showRecorder) {
            RecordView()
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
        }
        .sheet(item: $router.askSheet) { scope in
            NavigationStack {
                AskView(scope: scope)
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(item: $router.actionItemDetail) { route in
            ActionItemDetailSheet(itemID: route.id)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            intelligence.refresh()
            calendar.refresh()
            Task { await sync.syncNow() }
        }
    }
}

extension View {
    /// Every tab can open a meeting.
    func meetingDestinations() -> some View {
        navigationDestination(for: MeetingRoute.self) { route in
            MeetingDetailView(meetingID: route.id)
        }
    }
}

/// While recording, a mini player above the tab bar (iOS 26.1+), like Music's.
private struct LiveRecordingAccessory: ViewModifier {
    @Environment(RecordingController.self) private var recorder

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: recorder.isLive) {
                RecordingAccessoryBar()
            }
        } else {
            content
        }
    }
}

private struct RecordingAccessoryBar: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            PulsingDot(active: recorder.phase == .recording)
            VStack(alignment: .leading, spacing: 1) {
                Text(recorder.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(recorder.phase == .paused ? "Paused · \(Format.clock(recorder.elapsed(at: context.date)))" : Format.clock(recorder.elapsed(at: context.date)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                recorder.phase == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(recorder.phase == .paused ? "Resume" : "Pause")
            Button {
                recorder.stop()
                router.showRecorder = true
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.record)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Stop and write notes")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .contentShape(.rect)
        .onTapGesture { router.showRecorder = true }
    }
}

/// The recording dot, breathing while live.
struct PulsingDot: View {
    var active: Bool
    var size: CGFloat = 10
    var color: Color = Brand.record

    var body: some View {
        Circle()
            .fill(active ? color : Color.orange)
            .frame(width: size, height: size)
            .background {
                if active {
                    Circle()
                        .fill(color.opacity(0.35))
                        .phaseAnimator([1.0, 2.2]) { view, scale in
                            view.scaleEffect(scale).opacity(2.4 - scale)
                        } animation: { _ in .easeOut(duration: 1.1) }
                }
            }
            .accessibilityHidden(true)
    }
}
