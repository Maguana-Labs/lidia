// The library's models (Meeting, ActionItem, TalkingPoint, ChatThreadModel,
// ChatMessageModel, InboxNotification, TranscriptWord) live in LidIAKit so the Mac and
// the iPhone open the same schema: they sync through one iCloud container. Re-exported
// here so every file in the app sees them without importing LidIAKit itself.
@_exported import LidIAKit
import SwiftData

// MARK: - Current Schema

/// The Mac's library schema: exactly `LidIASchemaV4`, shared with the iPhone.
///
/// History: 3.3.0 was the last Mac-only schema. 4.0.0 made it CloudKit-compatible
/// (defaults on every attribute, optional to-many relationships, no unique constraints,
/// `Meeting.originDeviceID`). Both changes are lightweight migrations; the migration is
/// tested on a fixture store in `LibraryMigrationTests`.
typealias AppSchema = LidIASchemaV4
