import ActivityKit
import Foundation
import os

/// Starts, updates and ends the recording Live Activity.
@MainActor
final class LiveActivityController {
    private static let logger = Logger(subsystem: "io.lidia.ios", category: "LiveActivity")

    private var activity: Activity<RecordingActivityAttributes>?
    private var lastState: RecordingActivityAttributes.ContentState?
    private var lastLineUpdate = Date.distantPast

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(title: String, meetingID: UUID, state: RecordingActivityAttributes.ContentState) {
        guard isEnabled, activity == nil else { return }
        // A Live Activity left over from a crash would otherwise stay on the Lock Screen.
        let staleIDs = Activity<RecordingActivityAttributes>.activities.map(\.id)
        Task.detached {
            for id in staleIDs {
                await Self.find(id)?.end(nil, dismissalPolicy: .immediate)
            }
        }
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(title: title, meetingID: meetingID),
                content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100)
            )
            lastState = state
        } catch {
            Self.logger.error("Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Phase changes go out at once; transcript lines at most every 4 seconds.
    func update(_ state: RecordingActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        let phaseChanged = state.phase != lastState?.phase
        if !phaseChanged, Date.now.timeIntervalSince(lastLineUpdate) < 4 { return }
        lastState = state
        lastLineUpdate = .now
        let id = activity.id
        Task.detached {
            await Self.find(id)?.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 100))
        }
    }

    func end(_ state: RecordingActivityAttributes.ContentState, after seconds: TimeInterval = 90) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let id = activity.id
        Task.detached {
            await Self.find(id)?.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(.now.addingTimeInterval(seconds))
            )
        }
    }

    /// Activities aren't Sendable; look them up by ID off the main actor.
    private nonisolated static func find(_ id: String) -> Activity<RecordingActivityAttributes>? {
        Activity<RecordingActivityAttributes>.activities.first { $0.id == id }
    }
}
