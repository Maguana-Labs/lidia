import Foundation
import LidIALiveActivity
import Observation

/// Turns the running `RecordingSession` into a `RecordingActivityState` for the menu bar
/// (the status item's timer and the panel's expanded view). Refreshed once a second
/// while recording and on every start, pause and stop. The last transcript line changes
/// at most every `lineInterval` seconds, within a Live Activity's update budget, so the
/// same feed can drive one when ActivityKit reaches macOS.
@MainActor
@Observable
final class RecordingActivityFeed {
    private(set) var state: RecordingActivityState?
    /// How many times `state` changed in this recording (an update a Live Activity would send).
    private(set) var updateCount = 0

    static let lineInterval: TimeInterval = 4

    @ObservationIgnored private var lineThrottle = ActivityUpdateThrottle<RecordingActivityState.Line>(minimumInterval: lineInterval)

    func refresh(from session: RecordingSession, now: Date = .now) {
        guard session.isRecording else {
            if state != nil { state = nil }
            lineThrottle.reset()
            updateCount = 0
            return
        }
        let latest = RecordingPillState.lines(from: session.transcriptWords, limit: 1).last
            .map { RecordingActivityState.Line(text: $0.text, isLocal: $0.isLocal) }
        apply(
            title: session.currentMeeting?.title ?? "",
            elapsed: session.elapsedTime,
            isPaused: session.isPaused,
            latestLine: latest,
            warning: RecordingPillState.warning(
                quality: session.audioQualityState,
                micOnly: session.activeCaptureMode == .micOnly,
                fallbackReason: session.systemAudioFallbackReason
            ) ?? session.systemAudioFallbackReason,
            transcriptNotice: session.liveTranscriptNotice,
            now: now
        )
    }

    /// The mapping itself, separate from the session so it can be tested.
    func apply(
        title: String,
        elapsed: TimeInterval,
        isPaused: Bool,
        latestLine: RecordingActivityState.Line?,
        warning: String?,
        transcriptNotice: String?,
        now: Date
    ) {
        let next = RecordingActivityState.make(
            title: title,
            elapsed: elapsed,
            isPaused: isPaused,
            lastLine: lineThrottle.accept(latestLine, at: now),
            warning: warning,
            transcriptNotice: transcriptNotice,
            now: now,
            previous: state
        )
        if next != state {
            state = next
            updateCount += 1
        }
    }

    func reset() {
        state = nil
        lineThrottle.reset()
        updateCount = 0
    }
}
