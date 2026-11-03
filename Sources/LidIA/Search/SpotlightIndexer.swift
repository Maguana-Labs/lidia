import CoreSpotlight
import Foundation
import LidIAAppIntents
import LidIAKit
import SwiftData
import os

/// Meetings in Spotlight, each item associated with its `MeetingEntity` so
/// Siri can find a meeting and act on it (`SiriSpotlight`). Summaries go into
/// the index only while `SiriContentPolicy` allows meeting content.
enum SpotlightIndexer {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "SpotlightIndexer")
    static func indexMeeting(_ meeting: Meeting) {
        indexMeetings([meeting])
    }

    /// What Spotlight needs from a meeting, copied out so it can be indexed
    /// after the model's context has saved or moved on. Built on whatever
    /// actor owns the model (imports run on their own), so it reads plain
    /// stored values only; people and projects are worked out at index time.
    struct Entry: Sendable {
        var id: UUID
        var title: String
        var summary: String
        var attendees: [String]?
        var date: Date
        var duration: TimeInterval = 0
        var folder: String?
        var status: MeetingStatus = .complete
        var openItemCount = 0

        init(_ meeting: Meeting) {
            id = meeting.id
            title = meeting.title
            summary = meeting.userEditedSummary ?? meeting.summary
            attendees = meeting.calendarAttendees
            date = meeting.date
            duration = meeting.duration
            folder = meeting.folder
            status = meeting.status
            openItemCount = meeting.actionItems.filter { !$0.isDeleted && !$0.isCompleted }.count
        }

        /// The record the Siri entity is made from. Main actor: people are
        /// parsed with the app's own rules.
        @MainActor
        var record: SiriMeetingRecord {
            SiriMeetingRecord(
                id: id, title: title, date: date, duration: duration,
                people: LidIASiri.parsePeople(attendees ?? [], LidIASiri.userName),
                project: LidIASiri.projectOfFolder(folder),
                state: SiriMeetingState(status),
                openItemCount: openItemCount
            )
        }
    }

    /// Indexes several meetings in one call (imports write hundreds at once).
    static func indexMeetings(_ meetings: [Meeting]) {
        indexEntries(meetings.map(Entry.init))
    }

    static func indexEntries(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        Task { @MainActor in
            let policy = SiriContentPolicy.current()
            let items = entries.map { SiriSpotlight.searchableItem(record: $0.record, summary: $0.summary, policy: policy) }
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    logger.error("Spotlight indexing failed: \(error)")
                }
            }
        }
    }

    /// Re-indexes the whole library, after the Siri content setting or
    /// Local-only mode changed (the summaries go in or come out).
    @MainActor
    static func reindexLibrary() {
        guard Bundle.main.bundleIdentifier != nil, !SnapshotRun.isActive, let context = MacSiriHost.shared?.context else { return }
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        indexEntries(meetings.map(Entry.init))
    }

    static func removeMeeting(_ meetingID: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [meetingID.uuidString]
        )
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [SiriSpotlight.domain]
        )
    }
}
