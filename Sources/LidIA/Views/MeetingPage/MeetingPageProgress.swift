import Foundation
import SwiftUI

/// What the meeting page's stage stepper shows. Built from the pipeline's live
/// `MeetingProcessingProgress` when there is one, otherwise derived from the meeting.
struct MeetingPageProgress: Equatable {
    enum Phase: Equatable, Sendable {
        /// Nothing to show (recording, or a meeting that never needed processing).
        case idle
        /// Waiting for a model provider; LidIA retries automatically.
        case queued
        case running
        case failed
        case complete
    }

    var phase: Phase
    /// The stage running now, or the one that failed.
    var stage: ProcessingStage?
    var states: [ProcessingStage: ProcessingStageState]
    /// Failure or queue message.
    var message: String?
    /// Live detail from the pipeline, e.g. "Summarizing part 2 of 5".
    var detail: String?
    /// Overall 0…1 progress when the pipeline reports it.
    var fraction: Double?

    static let idle = MeetingPageProgress(phase: .idle, stage: nil, states: [:])
    static let complete = MeetingPageProgress(
        phase: .complete,
        stage: nil,
        states: Dictionary(uniqueKeysWithValues: ProcessingStage.allCases.map { ($0, .done) })
    )

    func state(of stage: ProcessingStage) -> ProcessingStageState {
        states[stage] ?? .pending
    }

    /// Whether the stepper should be on screen.
    var isVisible: Bool {
        switch phase {
        case .queued, .running, .failed: true
        case .idle, .complete: false
        }
    }
}

// MARK: - Source protocol

/// Supplies stepper progress for a meeting. Injected through the environment so
/// previews and tests can substitute their own.
protocol MeetingProcessingProgressSource: Sendable {
    @MainActor func progress(for meeting: Meeting) -> MeetingPageProgress
}

/// Default source: the pipeline's live progress (`ProcessingProgressCenter`),
/// falling back to `StatusDerivedProgressSource` when the pipeline isn't tracking
/// the meeting (queued, failed after the run ended, or processed before launch).
struct PipelineProgressSource: MeetingProcessingProgressSource {
    /// Nil means `ProcessingProgressCenter.shared`.
    var center: ProcessingProgressCenter?
    var fallback = StatusDerivedProgressSource()

    @MainActor
    func progress(for meeting: Meeting) -> MeetingPageProgress {
        let center = center ?? .shared
        guard let live = center.progress(for: meeting.id) else {
            return fallback.progress(for: meeting)
        }
        return Self.map(live)
    }

    @MainActor
    static func map(_ live: MeetingProcessingProgress) -> MeetingPageProgress {
        let states = Dictionary(uniqueKeysWithValues: ProcessingStage.allCases.map { ($0, live.state(of: $0)) })
        let failedStage = ProcessingStage.allCases.first { live.state(of: $0) == .failed }
        let phase: MeetingPageProgress.Phase
        if live.failureMessage != nil || failedStage != nil {
            phase = .failed
        } else if live.isFinished {
            phase = .complete
        } else {
            phase = .running
        }
        let detail = live.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingPageProgress(
            phase: phase,
            stage: live.currentStage ?? failedStage,
            states: states,
            message: live.failureMessage,
            detail: detail.isEmpty ? nil : detail,
            fraction: live.overallFraction
        )
    }
}

/// Fallback: infers the stage from `meeting.status` and which fields are filled in.
struct StatusDerivedProgressSource: MeetingProcessingProgressSource {
    @MainActor
    func progress(for meeting: Meeting) -> MeetingPageProgress {
        Self.derive(
            status: meeting.status,
            hasRawTranscript: !meeting.rawTranscript.isEmpty,
            hasRefinedTranscript: !meeting.refinedTranscript.isEmpty,
            hasSummary: !meeting.summary.isEmpty,
            processingError: meeting.processingError
        )
    }

    /// Pure derivation so it can be unit tested without SwiftData.
    static func derive(
        status: MeetingStatus,
        hasRawTranscript: Bool,
        hasRefinedTranscript: Bool,
        hasSummary: Bool,
        processingError: String?
    ) -> MeetingPageProgress {
        let contentStage: ProcessingStage = {
            if !hasRawTranscript { return .transcribing }
            if !hasRefinedTranscript { return .speakers }
            if !hasSummary { return .summarizing }
            return .actionItems
        }()

        switch status {
        case .recording:
            return .idle
        case .complete:
            return .complete
        case .processing:
            return make(.running, stage: contentStage, message: nil)
        case .queued:
            return make(.queued, stage: contentStage, message: processingError)
        case .failed:
            let stage: ProcessingStage = {
                let error = processingError?.lowercased() ?? ""
                if error.contains("refinement") { return .speakers }
                if error.contains("summary") || error.contains("model") { return .summarizing }
                if error.contains("transcri") && !hasRawTranscript { return .transcribing }
                return contentStage
            }()
            return make(.failed, stage: stage, message: processingError)
        }
    }

    private static func make(_ phase: MeetingPageProgress.Phase, stage: ProcessingStage, message: String?) -> MeetingPageProgress {
        let order = ProcessingStage.allCases
        let current = order.firstIndex(of: stage) ?? 0
        var states: [ProcessingStage: ProcessingStageState] = [:]
        for (index, candidate) in order.enumerated() {
            if index < current {
                states[candidate] = .done
            } else if index == current {
                switch phase {
                case .running: states[candidate] = .active
                case .failed: states[candidate] = .failed
                default: states[candidate] = .pending
                }
            } else {
                states[candidate] = .pending
            }
        }
        return MeetingPageProgress(phase: phase, stage: stage, states: states, message: message)
    }
}

extension EnvironmentValues {
    /// Where the meeting page reads processing progress from.
    @Entry var meetingProcessingProgressSource: any MeetingProcessingProgressSource = PipelineProgressSource()
}
