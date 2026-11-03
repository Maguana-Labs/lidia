import AVFoundation
import EventKit
import Foundation
import SwiftData
import Testing
@testable import LidIA

/// Regression tests for the crash sweep: models deleted while code awaits, stale
/// caches of models, and numeric traps on malformed audio or calendar data.
@MainActor
@Suite("Crash sweep")
struct CrashSweepTests {
    private func makeQueue() -> DeferredMeetingProcessingQueue {
        DeferredMeetingProcessingQueue(defaults: UserDefaults(suiteName: "lidia.tests.crash-sweep.\(UUID().uuidString)")!)
    }

    /// Deletes the meeting from a second context, as sync or the MCP inbox do.
    private func deleteElsewhere(_ id: UUID, container: ModelContainer) {
        let other = ModelContext(container)
        if let meeting = LiveModel.meeting(id, in: other) {
            other.delete(meeting)
            try? other.save()
        }
    }

    // MARK: Liveness

    @Test func liveModelSeesPendingInsertsAndDeletions() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Unsaved")
        context.insert(meeting)
        let id = meeting.id
        #expect(LiveModel.meetingExists(id, in: context))

        try context.save()
        context.delete(meeting)
        #expect(!LiveModel.meetingExists(id, in: context))
    }

    @Test func liveModelSeesDeletionFromAnotherContext() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Shared")
        context.insert(meeting)
        try context.save()
        let id = meeting.id

        deleteElsewhere(id, container: context.container)

        #expect(!LiveModel.meetingExists(id, in: context))
    }

    // MARK: Processing a meeting that gets deleted

    @Test func pipelineStopsWhenMeetingIsDeletedWhileTheModelRuns() async throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "", rawTranscript: makeWords([(true, "ship the deck"), (false, "agreed")]), status: .processing)
        context.insert(meeting)
        try context.save()
        let id = meeting.id

        let hook = ChatHook()
        hook.on(.summarize) { deleteElsewhere(id, container: context.container) }
        let pipeline = MeetingPipeline(
            llmClient: ScriptedLLMClient(hook: hook),
            modelContext: context,
            progressCenter: ProcessingProgressCenter()
        )

        await #expect(throws: PipelineError.meetingDeleted) {
            try await pipeline.process(meeting: meeting, model: "m")
        }
        #expect(!LiveModel.meetingExists(id, in: context))
    }

    @Test func regenerateOfAMeetingDeletedMidRunDoesNotRestoreIt() async throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Done", rawTranscript: makeWords([(true, "hello there")]), summary: "Old", status: .complete)
        context.insert(meeting)
        try context.save()
        let id = meeting.id

        let hook = ChatHook()
        hook.on(.summarize) {
            let doomed = LiveModel.meeting(id, in: context)!
            context.delete(doomed)
            try? context.save()
        }
        let pipeline = MeetingPipeline(
            llmClient: ScriptedLLMClient(hook: hook),
            modelContext: context,
            progressCenter: ProcessingProgressCenter()
        )

        await #expect(throws: PipelineError.meetingDeleted) {
            try await pipeline.regenerate(meeting: meeting, model: "m")
        }
        #expect(!LiveModel.meetingExists(id, in: context))
    }

    @Test func queueDrainSkipsAMeetingDeletedWhileAnotherIsProcessed() async throws {
        let context = try makeInMemoryContext()
        let first = Meeting(title: "First", rawTranscript: makeWords([(true, "one")]), status: .queued)
        let second = Meeting(title: "Second", rawTranscript: makeWords([(true, "two")]), status: .queued)
        context.insert(first)
        context.insert(second)
        try context.save()
        let ids: Set<UUID> = [first.id, second.id]

        let queue = makeQueue()
        let service = PostProcessingService(queue: queue)
        var processed: [UUID] = []

        await service.drainQueuedMeetings(
            modelContext: context,
            settings: AppSettings(),
            eventKitManager: nil,
            process: { meeting in
                processed.append(meeting.id)
                // While this one is processed, the other is deleted elsewhere.
                for id in ids where id != meeting.id {
                    deleteElsewhere(id, container: context.container)
                }
            }
        )

        #expect(processed.count == 1)
        let deleted = try #require(ids.subtracting(processed).first)
        #expect(await !queue.all().contains(deleted))
    }

    @Test func deletionWaitsForProcessing() {
        #expect(MeetingDeletionPolicy.blockReason(status: .processing, isBeingProcessed: false) != nil)
        #expect(MeetingDeletionPolicy.blockReason(status: .complete, isBeingProcessed: true) != nil)
        #expect(MeetingDeletionPolicy.blockReason(status: .recording, isBeingProcessed: false) != nil)
        // A queued meeting that nothing is processing can go: the drain re-fetches by ID.
        #expect(MeetingDeletionPolicy.blockReason(status: .queued, isBeingProcessed: false) == nil)
        #expect(MeetingDeletionPolicy.blockReason(status: .complete, isBeingProcessed: false) == nil)
        #expect(MeetingDeletionPolicy.blockReason(status: .failed, isBeingProcessed: false) == nil)
    }

    // MARK: Action Items dashboard

    @Test func dashboardRowsDropAnItemDeletedInAnotherContext() throws {
        let context = try makeInMemoryContext()
        let older = Meeting(title: "Older", date: .now.addingTimeInterval(-86_400), status: .complete)
        let newer = Meeting(title: "Newer", date: .now, status: .complete)
        let unfinished = Meeting(title: "Processing", status: .processing)
        for meeting in [older, newer, unfinished] { context.insert(meeting) }
        let kept = ActionItem(title: "Keep me")
        let doomed = ActionItem(title: "Deleted by the MCP inbox")
        let hidden = ActionItem(title: "Not complete yet")
        older.actionItems.append(kept)
        newer.actionItems.append(doomed)
        unfinished.actionItems.append(hidden)
        try context.save()
        let doomedID = doomed.id

        let other = ModelContext(context.container)
        other.delete(try #require(LiveModel.actionItem(doomedID, in: other)))
        try other.save()

        // What the view's @Query hands it after the save.
        let items = try context.fetch(FetchDescriptor<ActionItem>())
        let rows = ActionItemDashboardView.rows(from: items)
        #expect(rows.map(\.0.title) == ["Keep me"])
        #expect(rows.map(\.1.title) == ["Older"])
    }

    @Test func dashboardRowsAreNewestMeetingFirst() throws {
        let context = try makeInMemoryContext()
        let older = Meeting(title: "Older", date: .now.addingTimeInterval(-3_600), status: .complete)
        let newer = Meeting(title: "Newer", date: .now, status: .complete)
        context.insert(older)
        context.insert(newer)
        older.actionItems.append(ActionItem(title: "a"))
        newer.actionItems.append(ActionItem(title: "b"))
        try context.save()

        let rows = ActionItemDashboardView.rows(from: try context.fetch(FetchDescriptor<ActionItem>()))
        #expect(rows.map(\.1.title) == ["Newer", "Older"])
    }

    // MARK: Numeric traps

    @Test func resamplerReturnsNothingForAZeroHertzRate() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        #expect(AudioResampler.resample(samples, from: 0, to: 16_000).isEmpty)
        #expect(AudioResampler.resample(samples, from: 48_000, to: 0).isEmpty)
        #expect(AudioResampler.resample(samples, from: 16_000, to: 16_000) == samples)
        #expect(AudioResampler.resample(samples, from: 48_000, to: 16_000).count == 1)
    }

    @Test func levelPercentToleratesNaNAndInfinity() {
        #expect(RecordingLevelMeter.percent(.nan) == 0)
        #expect(RecordingLevelMeter.percent(.infinity) == 0)
        #expect(RecordingLevelMeter.percent(-.infinity) == 0)
        #expect(RecordingLevelMeter.percent(0.5) == 50)
        #expect(RecordingLevelMeter.percent(3) == 100)
        #expect(RecordingLevelMeter.percent(-1) == 0)
    }

    @Test func rmsOfMalformedSamplesIsZero() {
        #expect(AudioChunk.computeRMS([.nan, 0.5]) == 0)
        #expect(AudioChunk.computeRMS([.infinity]) == 0)
        #expect(AudioChunk.computeRMS([Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude]) == 0)
        #expect(AudioChunk.computeRMS([0.5, -0.5]) == 0.5)
    }

    @Test func inputWithoutADeviceIsRejectedBeforeATapIsInstalled() {
        #expect(throws: AudioCaptureError.self) {
            try AudioCaptureError.checkInputFormat(sampleRate: 0, channelCount: 1)
        }
        #expect(throws: AudioCaptureError.self) {
            try AudioCaptureError.checkInputFormat(sampleRate: 48_000, channelCount: 0)
        }
        #expect(throws: AudioCaptureError.self) {
            try AudioCaptureError.checkInputFormat(sampleRate: .nan, channelCount: 1)
        }
        #expect(throws: Never.self) {
            try AudioCaptureError.checkInputFormat(sampleRate: 48_000, channelCount: 1)
        }
    }

    // MARK: EventKit

    @Test func calendarEventWithoutDatesOrIdentifierIsSkipped() {
        let store = EKEventStore()
        let noDates = EKEvent(eventStore: store)
        noDates.title = "No dates"
        #expect(EventKitManager.calendarEvent(from: noDates) == nil)

        // An unsaved event has no identifier yet.
        let noIdentifier = EKEvent(eventStore: store)
        noIdentifier.title = "No identifier"
        noIdentifier.startDate = .now
        noIdentifier.endDate = .now.addingTimeInterval(1_800)
        #expect(EventKitManager.calendarEvent(from: noIdentifier) == nil)
    }
}
