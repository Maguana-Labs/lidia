import Foundation
import SwiftData
import os

extension Notification.Name {
    /// Posted on the main actor with the `Meeting` as `object` when processing fails
    /// permanently (not when it is queued for retry).
    static let meetingProcessingDidFail = Notification.Name("meetingProcessingDidFail")
}

/// Puts meetings interrupted by a crash or force-quit back on the retry queue.
///
/// Handles `.processing` and `.queued`. Meetings left in `.recording` belong to the
/// capture workstream, which finalises them and calls `DeferredMeetingProcessingQueue.enqueue`.
/// Only touches meetings this device made (`Meeting.isOwnedByThisDevice`): with iCloud
/// sync, a meeting another device is still processing arrives here as `.processing`.
@MainActor
enum ProcessingRecovery {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "ProcessingRecovery")
    private static var hasRunThisLaunch = false

    struct Report: Equatable, Sendable {
        var requeued: [UUID] = []
        var failed: [UUID] = []
    }

    static let interruptedNoTranscriptMessage = String(localized: "Processing was interrupted before a transcript was saved, so there is nothing to summarize. Type notes and use Regenerate, or record again.")

    /// Runs `recover` once per app launch (WindowGroup `onAppear` fires per window).
    /// Statuses are fixed synchronously, before any drain task can run; queue writes follow.
    static func recoverOnceAtLaunch(in context: ModelContext, queue: DeferredMeetingProcessingQueue = .shared) {
        guard !hasRunThisLaunch else { return }
        hasRunThisLaunch = true
        let report = markInterrupted(in: context)
        if !report.requeued.isEmpty || !report.failed.isEmpty {
            logger.warning("Recovered interrupted meetings: requeued=\(report.requeued.count) failed=\(report.failed.count)")
        }
        Task { await apply(report, to: queue) }
    }

    /// Re-queues every `.processing` / `.queued` meeting that has something to summarise
    /// (or recorded audio to transcribe first) and fails the rest with a clear message.
    /// Never leaves a meeting in `.processing`.
    @discardableResult
    static func recover(
        in context: ModelContext,
        queue: DeferredMeetingProcessingQueue = .shared,
        progressCenter: ProcessingProgressCenter? = nil,
        recordingsRoot: URL = RecordingAudioStore.defaultRoot
    ) async -> Report {
        let report = markInterrupted(in: context, progressCenter: progressCenter, recordingsRoot: recordingsRoot)
        await apply(report, to: queue)
        return report
    }

    private static func apply(_ report: Report, to queue: DeferredMeetingProcessingQueue) async {
        for id in report.requeued {
            await queue.enqueue(id)
        }
        for id in report.failed {
            await queue.remove(id)
        }
    }

    /// Synchronous status pass. Skips meetings that are being processed right now in this
    /// launch (they have live progress in `ProcessingProgressCenter`).
    ///
    /// A meeting whose audio was saved but whose transcript wasn't (a batch-only engine, or
    /// a live engine that produced nothing, interrupted while encoding or transcribing) is
    /// requeued: the drain transcribes it from the recording before summarising.
    static func markInterrupted(
        in context: ModelContext,
        progressCenter: ProcessingProgressCenter? = nil,
        recordingsRoot: URL = RecordingAudioStore.defaultRoot
    ) -> Report {
        let center = progressCenter ?? .shared
        var report = Report()
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        for meeting in meetings where meeting.status == .processing || meeting.status == .queued {
            // Another device's meeting (synced through iCloud) is that device's to finish.
            guard meeting.isOwnedByThisDevice else { continue }
            if center.progress(for: meeting.id) != nil { continue }
            if hasProcessableContent(meeting, recordingsRoot: recordingsRoot) {
                if meeting.status == .processing {
                    meeting.status = .queued
                    meeting.processingError = String(localized: "Processing was interrupted; it will resume automatically.")
                }
                report.requeued.append(meeting.id)
            } else {
                meeting.status = .failed
                meeting.processingError = interruptedNoTranscriptMessage
                report.failed.append(meeting.id)
            }
        }
        try? context.save()
        return report
    }

    /// Text to summarise, or recorded audio (raw or finished) that a transcript can still be
    /// built from.
    static func hasProcessableContent(_ meeting: Meeting, recordingsRoot: URL = RecordingAudioStore.defaultRoot) -> Bool {
        hasTextContent(meeting) || RecordingRecovery.hasRecordedAudio(meeting, recordingsRoot: recordingsRoot)
    }

    /// A transcript, an edited transcript or notes: something the pipeline can summarise now.
    static func hasTextContent(_ meeting: Meeting) -> Bool {
        if !meeting.rawTranscript.isEmpty { return true }
        if !(meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        return !NoteOutlineParser.parse(meeting.notes).isEmpty
    }
}
