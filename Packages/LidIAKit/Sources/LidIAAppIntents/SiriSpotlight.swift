import AppIntents
import CoreSpotlight
import Foundation

/// Spotlight items for meetings, each associated with its `MeetingEntity` so
/// Siri can find the meeting and act on it. Built from value copies.
///
/// The summary goes into the item only when `SiriContentPolicy` allows meeting
/// content: Siri reads what Spotlight holds, and may process it off device.
/// With Local-only mode on (or "Let Siri read meeting content" off), Spotlight
/// still finds meetings by title, people and project.
public enum SiriSpotlight {
    public static let domain = "com.lidia.meetings"

    public static func searchableItem(record: SiriMeetingRecord, summary: String, policy: SiriContentPolicy) -> CSSearchableItem {
        let entity = MeetingEntity(record: record)
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = record.displayTitle
        attributes.displayName = record.displayTitle
        attributes.contentCreationDate = record.date
        attributes.keywords = entity.attendees + (record.project.map { [$0] } ?? [])
        if policy.allowsMeetingContent {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { attributes.contentDescription = trimmed }
        }
        let item = CSSearchableItem(uniqueIdentifier: record.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
        item.associateAppEntity(entity, priority: 1)
        return item
    }
}
