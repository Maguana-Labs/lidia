import Foundation
import Observation

/// The user-visible stages of post-meeting processing, in order.
enum ProcessingStage: String, CaseIterable, Sendable, Identifiable {
    case transcribing
    case speakers
    case summarizing
    case actionItems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcribing: String(localized: "Transcribing")
        case .speakers: String(localized: "Identifying speakers")
        case .summarizing: String(localized: "Summarizing")
        case .actionItems: String(localized: "Finding action items")
        }
    }
}

enum ProcessingStageState: String, Sendable, Equatable {
    case pending
    case active
    case done
    /// Stage did not apply (e.g. no batch re-transcription) or was degraded but non-fatal.
    case skipped
    case failed
}

/// Live progress of one meeting's processing. Observe from SwiftUI:
///
/// ```swift
/// if let progress = ProcessingProgressCenter.shared.progress(for: meeting.id) {
///     ForEach(ProcessingStage.allCases) { stage in
///         StageRow(stage.title, state: progress.state(of: stage))
///     }
///     Text(progress.detail)
/// }
/// ```
@MainActor
@Observable
final class MeetingProcessingProgress: Identifiable {
    nonisolated let meetingID: UUID
    nonisolated var id: UUID { meetingID }

    private(set) var states: [ProcessingStage: ProcessingStageState]
    /// Stage currently running, if any.
    private(set) var currentStage: ProcessingStage?
    /// Human-readable detail for the current stage, e.g. "Summarizing part 2 of 5".
    private(set) var detail: String = ""
    /// 0...1 progress within the current stage when known (chunked summaries), else nil.
    private(set) var stageFraction: Double?
    /// Non-fatal problems the user may want to know about (e.g. "Transcript cleanup failed; used raw transcript").
    private(set) var warnings: [String] = []
    private(set) var failureMessage: String?
    private(set) var isFinished = false
    let startedAt: Date

    init(meetingID: UUID, startedAt: Date = Date()) {
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.states = Dictionary(uniqueKeysWithValues: ProcessingStage.allCases.map { ($0, .pending) })
    }

    func state(of stage: ProcessingStage) -> ProcessingStageState {
        states[stage] ?? .pending
    }

    /// Overall 0...1 progress across all stages, for a single progress bar.
    var overallFraction: Double {
        let stages = ProcessingStage.allCases
        var total = 0.0
        for stage in stages {
            switch state(of: stage) {
            case .done, .skipped, .failed: total += 1
            case .active: total += stageFraction ?? 0.0
            case .pending: break
            }
        }
        return total / Double(stages.count)
    }

    func begin(_ stage: ProcessingStage, detail: String? = nil) {
        // Anything still pending before this stage did not run.
        for earlier in ProcessingStage.allCases.prefix(while: { $0 != stage }) where state(of: earlier) == .pending {
            states[earlier] = .skipped
        }
        if let currentStage, currentStage != stage, state(of: currentStage) == .active {
            states[currentStage] = .done
        }
        states[stage] = .active
        currentStage = stage
        stageFraction = nil
        self.detail = detail ?? stage.title
    }

    func update(detail: String? = nil, fraction: Double? = nil) {
        if let detail { self.detail = detail }
        if let fraction { stageFraction = min(1, max(0, fraction)) }
    }

    func complete(_ stage: ProcessingStage) {
        states[stage] = .done
        if currentStage == stage {
            currentStage = nil
            stageFraction = nil
        }
    }

    func skip(_ stage: ProcessingStage) {
        if state(of: stage) != .done { states[stage] = .skipped }
        if currentStage == stage { currentStage = nil }
    }

    func warn(_ message: String) {
        warnings.append(message)
    }

    func fail(_ stage: ProcessingStage?, message: String) {
        if let stage { states[stage] = .failed }
        failureMessage = message
        currentStage = nil
        isFinished = true
    }

    func finish() {
        for stage in ProcessingStage.allCases where state(of: stage) == .pending || state(of: stage) == .active {
            states[stage] = state(of: stage) == .active ? .done : .skipped
        }
        currentStage = nil
        stageFraction = nil
        isFinished = true
    }
}

/// Registry of meetings currently being processed. UI reads it; the pipeline writes it.
@MainActor
@Observable
final class ProcessingProgressCenter {
    static let shared = ProcessingProgressCenter()

    /// In-flight (and just-failed) processing, keyed by meeting ID.
    private(set) var active: [UUID: MeetingProcessingProgress] = [:]

    init() {}

    func progress(for meetingID: UUID) -> MeetingProcessingProgress? {
        active[meetingID]
    }

    /// Returns the existing progress for the meeting or starts a new one.
    @discardableResult
    func start(meetingID: UUID) -> MeetingProcessingProgress {
        if let existing = active[meetingID], !existing.isFinished {
            return existing
        }
        let progress = MeetingProcessingProgress(meetingID: meetingID)
        active[meetingID] = progress
        return progress
    }

    /// Removes the meeting's progress. Called when processing completes; failed
    /// progress is also removed because `Meeting.processingError` carries the message.
    func end(meetingID: UUID) {
        active[meetingID] = nil
        streamingSummary[meetingID] = nil
    }

    // MARK: - Streaming summary

    /// Summary markdown as the model writes it, keyed by meeting ID. The meeting
    /// page shows this while the summary step runs, so text appears word by word
    /// instead of after a long wait. Cleared when the final summary is saved.
    private(set) var streamingSummary: [UUID: String] = [:]

    func appendSummaryText(_ text: String, meetingID: UUID) {
        streamingSummary[meetingID, default: ""] += text
    }

    func resetSummaryText(meetingID: UUID) {
        streamingSummary[meetingID] = nil
    }
}
