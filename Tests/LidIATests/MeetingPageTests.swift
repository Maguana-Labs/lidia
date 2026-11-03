import Foundation
import SwiftData
import Testing
@testable import LidIA

// MARK: - Transcript segmenter

@Suite struct TranscriptSegmenterTests {
    private func word(_ text: String, _ start: TimeInterval, speaker: Int? = nil, local: Bool? = nil, name: String? = nil) -> TranscriptWord {
        TranscriptWord(word: text, start: start, end: start + 0.4, confidence: 1, speaker: speaker, speakerName: name, isLocalSpeaker: local)
    }

    @Test func splitsOnDiarizedSpeakerChange() {
        let words = [
            word("hello", 0, speaker: 0), word("there", 0.5, speaker: 0),
            word("hi", 1.0, speaker: 1), word("back", 1.5, speaker: 1),
        ]
        let segments = TranscriptSegmenter.segments(from: words, meetingDuration: 10)
        #expect(segments.count == 2)
        #expect(segments[0].text == "hello there")
        #expect(segments[1].text == "hi back")
        #expect(segments[1].start == 1.0)
        #expect(segments.map(\.id) == [0, 1])
    }

    @Test func absorbsInterleavedMicSystemWordsWithoutAGap() {
        let words = [word("a", 0, local: true), word("b", 0.5, local: false), word("c", 1.0, local: true)]
        #expect(TranscriptSegmenter.segments(from: words, meetingDuration: 10).count == 1)
    }

    @Test func splitsOnMicSystemChangeAfterAGap() {
        let words = [word("a", 0, local: true), word("b", 3.0, local: false)]
        let segments = TranscriptSegmenter.segments(from: words, meetingDuration: 10)
        #expect(segments.count == 2)
        #expect(segments[0].isLocal)
        #expect(!segments[1].isLocal)
    }

    @Test func longPunctuatedTurnsSplitAtASentenceEnd() {
        // 13 s of one speaker; the 12 s limit falls inside the second sentence.
        let first = "Thanks for joining today everyone.".split(separator: " ").enumerated().map { word(String($1), Double($0) * 1.2, local: false) }
        let second = "We have three questions about the help articles.".split(separator: " ").enumerated().map { word(String($1), 6 + Double($0) * 0.9, local: false) }
        let segments = TranscriptSegmenter.segments(from: first + second, meetingDuration: 20)
        #expect(segments.allSatisfy { $0.text.hasSuffix(".") })
        #expect(segments.last?.text.hasSuffix("help articles.") == true)
    }

    @Test func rebasesHostClockTimestamps() {
        let base: TimeInterval = 700_000
        let words = [word("late", base + 5), word("early", base + 1)]
        let segments = TranscriptSegmenter.segments(from: words, meetingDuration: 60)
        #expect(segments.first?.start == 0)
        #expect(segments.first?.text == "early late")
    }

    @Test func speakerLabels() {
        let named = TranscriptSegment(id: 0, start: 0, end: 1, text: "x", speaker: 2, speakerName: "Ana", isLocalSpeaker: nil)
        let local = TranscriptSegment(id: 1, start: 0, end: 1, text: "x", speaker: nil, speakerName: nil, isLocalSpeaker: true)
        let remote = TranscriptSegment(id: 2, start: 0, end: 1, text: "x", speaker: nil, speakerName: nil, isLocalSpeaker: false)
        let diarized = TranscriptSegment(id: 3, start: 0, end: 1, text: "x", speaker: 2, speakerName: nil, isLocalSpeaker: nil)
        let none = TranscriptSegment(id: 4, start: 0, end: 1, text: "x", speaker: nil, speakerName: nil, isLocalSpeaker: nil)
        #expect(named.speakerLabel(localName: "Me") == "Ana")
        #expect(local.speakerLabel(localName: "Alex") == "Alex")
        #expect(remote.speakerLabel(localName: "Me") == "Others")
        #expect(diarized.speakerLabel(localName: "Me") == "Speaker 3")
        // A remote voice diarization told apart on the system track.
        let remoteDiarized = TranscriptSegment(id: 5, start: 0, end: 1, text: "x", speaker: 1, speakerName: nil, isLocalSpeaker: false)
        #expect(remoteDiarized.speakerLabel(localName: "Me") == "Speaker 2")
        #expect(none.speakerLabel(localName: "Me") == nil)
        #expect(TranscriptSegmenter.hasSpeakerInfo([none]) == false)
        #expect(TranscriptSegmenter.hasSpeakerInfo([none, remote]))
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Revisión del presupuesto", speaker: nil, speakerName: nil, isLocalSpeaker: nil),
            TranscriptSegment(id: 1, start: 2, end: 3, text: "Next steps", speaker: nil, speakerName: nil, isLocalSpeaker: nil),
            TranscriptSegment(id: 2, start: 4, end: 5, text: "the REVISION is done", speaker: nil, speakerName: nil, isLocalSpeaker: nil),
        ]
        #expect(TranscriptSegmenter.matchingIndices(in: segments, query: "revision") == [0, 2])
        #expect(TranscriptSegmenter.matchingIndices(in: segments, query: "  ").isEmpty)
    }

    @Test func activeIndexFollowsPlaybackTime() {
        let segments = (0..<5).map {
            TranscriptSegment(id: $0, start: TimeInterval($0 * 10), end: TimeInterval($0 * 10 + 8), text: "s\($0)", speaker: nil, speakerName: nil, isLocalSpeaker: nil)
        }
        #expect(TranscriptSegmenter.activeIndex(in: segments, at: -1) == nil)
        #expect(TranscriptSegmenter.activeIndex(in: segments, at: 0) == 0)
        #expect(TranscriptSegmenter.activeIndex(in: segments, at: 25) == 2)
        #expect(TranscriptSegmenter.activeIndex(in: segments, at: 999) == 4)
        #expect(TranscriptSegmenter.activeIndex(in: [], at: 3) == nil)
    }

    @Test func timestampFormatting() {
        #expect(TranscriptSegmenter.formatTimestamp(65) == "1:05")
        #expect(TranscriptSegmenter.formatTimestamp(3_725) == "1:02:05")
        #expect(TranscriptSegmenter.formatTimestamp(-4) == "0:00")
    }
}

// MARK: - Processing stage adapters

@Suite struct ProcessingProgressTests {
    private func derive(
        _ status: MeetingStatus,
        raw: Bool = true,
        refined: Bool = true,
        summary: Bool = true,
        error: String? = nil
    ) -> MeetingPageProgress {
        StatusDerivedProgressSource.derive(
            status: status,
            hasRawTranscript: raw,
            hasRefinedTranscript: refined,
            hasSummary: summary,
            processingError: error
        )
    }

    @Test func runningStageFollowsContent() {
        #expect(derive(.processing, raw: false, refined: false, summary: false).stage == .transcribing)
        #expect(derive(.processing, refined: false, summary: false).stage == .speakers)
        #expect(derive(.processing, summary: false).stage == .summarizing)
        #expect(derive(.processing).stage == .actionItems)
        #expect(derive(.processing).phase == .running)
    }

    @Test func recordingAndCompleteHideTheStepper() {
        #expect(derive(.recording).isVisible == false)
        #expect(derive(.complete).isVisible == false)
        #expect(derive(.queued).isVisible)
        #expect(derive(.failed).isVisible)
    }

    @Test func failureStageComesFromTheError() {
        let refinement = derive(.failed, summary: false, error: "Transcript refinement failed: timeout")
        #expect(refinement.phase == .failed)
        #expect(refinement.stage == .speakers)
        #expect(refinement.message == "Transcript refinement failed: timeout")
        #expect(derive(.failed, error: "Summary generation failed: 500").stage == .summarizing)
        #expect(derive(.failed, error: "No model selected.").stage == .summarizing)
    }

    @Test func derivedStageStates() {
        let running = derive(.processing, summary: false)
        #expect(running.state(of: .transcribing) == .done)
        #expect(running.state(of: .speakers) == .done)
        #expect(running.state(of: .summarizing) == .active)
        #expect(running.state(of: .actionItems) == .pending)

        let failed = derive(.failed, summary: false, error: "Transcript refinement failed")
        #expect(failed.state(of: .speakers) == .failed)
        #expect(failed.state(of: .summarizing) == .pending)

        #expect(MeetingPageProgress.complete.state(of: .actionItems) == .done)
        #expect(derive(.queued, raw: false, refined: false, summary: false).state(of: .transcribing) == .pending)
    }
}

@MainActor
@Suite struct PipelineProgressSourceTests {
    @Test func usesLiveProgressWhenThePipelineTracksTheMeeting() {
        let center = ProcessingProgressCenter()
        let meeting = Meeting(title: "Live", status: .processing)
        let live = center.start(meetingID: meeting.id)
        live.begin(.speakers)
        live.complete(.speakers)
        live.begin(.summarizing, detail: "Summarizing part 2 of 5")

        let progress = PipelineProgressSource(center: center).progress(for: meeting)

        #expect(progress.phase == .running)
        #expect(progress.stage == .summarizing)
        #expect(progress.state(of: .transcribing) == .skipped)
        #expect(progress.state(of: .speakers) == .done)
        #expect(progress.state(of: .summarizing) == .active)
        #expect(progress.detail == "Summarizing part 2 of 5")
        #expect(progress.fraction == live.overallFraction)
    }

    @Test func mapsPipelineFailure() {
        let center = ProcessingProgressCenter()
        let meeting = Meeting(title: "Broken", status: .processing)
        let live = center.start(meetingID: meeting.id)
        live.begin(.summarizing)
        live.fail(.summarizing, message: "Model timed out")

        let progress = PipelineProgressSource(center: center).progress(for: meeting)
        #expect(progress.phase == .failed)
        #expect(progress.stage == .summarizing)
        #expect(progress.state(of: .summarizing) == .failed)
        #expect(progress.message == "Model timed out")
    }

    @Test func fallsBackToStatusWhenNotTracked() {
        let center = ProcessingProgressCenter()
        let meeting = Meeting(title: "Queued", status: .queued, processingError: "Ollama is offline")
        let progress = PipelineProgressSource(center: center).progress(for: meeting)
        #expect(progress.phase == .queued)
        #expect(progress.message == "Ollama is offline")
    }
}

// MARK: - Model field, adapters, helpers

@Suite struct MeetingPageAdapterTests {
    @Test func summaryBulletDecodesFromUserNotes() throws {
        let json = #"{"text":"Mine","from_user_notes":true}"#
        let mine = try JSONDecoder().decode(StructuredSummary.SummaryBullet.self, from: Data(json.utf8))
        #expect(mine.fromUserNotes)

        let legacy = try JSONDecoder().decode(StructuredSummary.SummaryBullet.self, from: Data(#"{"text":"AI"}"#.utf8))
        #expect(legacy.fromUserNotes == false)

        let roundTrip = try JSONDecoder().decode(
            StructuredSummary.SummaryBullet.self,
            from: JSONEncoder().encode(StructuredSummary.SummaryBullet(text: "x", fromUserNotes: true))
        )
        #expect(roundTrip.fromUserNotes)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "lidia.tests.meetingPage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func askThreadIndexRoundTrips() {
        let index = MeetingAskThreadIndex(defaults: isolatedDefaults())
        let meetingID = UUID()
        let threadID = UUID()
        #expect(index.threadID(for: meetingID) == nil)
        index.setThreadID(threadID, for: meetingID)
        #expect(index.threadID(for: meetingID) == threadID)
        index.setThreadID(nil, for: meetingID)
        #expect(index.threadID(for: meetingID) == nil)
    }

    @Test func provenanceStoreRecordsModel() {
        let store = MeetingProvenanceStore(defaults: isolatedDefaults())
        let id = UUID()
        store.record(model: "  ", for: id)
        #expect(store.summaryModel(for: id) == nil)
        store.record(model: "qwen3:8b", for: id)
        #expect(store.summaryModel(for: id) == "qwen3:8b")
        store.clear(for: id)
        #expect(store.summaryModel(for: id) == nil)
    }

    @Test func audioLocatorResolvesExistingFilesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("meeting.m4a")
        try Data([0]).write(to: file)

        #expect(MeetingAudioLocator.url(for: file.path)?.standardizedFileURL == file.standardizedFileURL)
        #expect(MeetingAudioLocator.url(for: file.absoluteString)?.standardizedFileURL == file.standardizedFileURL)
        #expect(MeetingAudioLocator.url(for: dir.appendingPathComponent("missing.m4a").path) == nil)
        #expect(MeetingAudioLocator.url(for: nil) == nil)
        #expect(MeetingAudioLocator.url(for: "   ") == nil)
    }

    @Test func attendeeDisplayNames() {
        #expect(AttendeeParser.parseEntry("jane.doe@acme.com").map(\.name) == ["Jane Doe"])
        #expect(AttendeeParser.parseEntry("Ana María").map(\.name) == ["Ana María"])
        #expect(MeetingAttendee(name: "Jane Doe").initials == "JD")
        #expect(MeetingAttendee(name: "").initials == "?")
    }

    @Test func levelNormalisation() {
        #expect(LiveAudioLevels.normalized(0) == 0)
        #expect(LiveAudioLevels.normalized(-1) == 0)
        #expect(LiveAudioLevels.normalized(0.1) > 0.29 && LiveAudioLevels.normalized(0.1) < 0.31)
        #expect(LiveAudioLevels.normalized(5) == 1)
    }

    @Test func bannerFailureUsesOperationTitle() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let banner = MeetingPageBanner.failure(.notion, error: Boom())
        #expect(banner.kind == .error)
        #expect(banner.title == "Couldn't send to Notion")
        #expect(banner.message == "boom")
        #expect(banner.id == .notion)
    }
}
