import Foundation
import SwiftData

/// The library schema every LidIA app opens: the Mac, the iPhone and the Watch.
///
/// One definition on purpose. The Mac and the iPhone sync through one iCloud
/// container (`LidIASchema.cloudKitContainerID`), and CloudKit maps each entity to a
/// record type (`CD_Meeting`, …) and each attribute to a field (`CD_title`, …): two
/// apps with different schemas would overwrite each other's fields.
///
/// Rules for changing it (enforced by `LidIASchemaTests` in LidIAKit and
/// `CloudKitSchemaTests` on the Mac):
/// - only add things: new attributes need a default or must be optional, new
///   relationships must be optional with an inverse; never rename or remove (a renamed
///   field is a new, empty CloudKit field and older apps keep writing the old one);
/// - no `@Attribute(.unique)`;
/// - bump `LidIASchemaV4.versionIdentifier`, and deploy the CloudKit schema to
///   Production before shipping a release (see docs/icloud-sync.md).
public enum LidIASchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            Meeting.self,
            ActionItem.self,
            TalkingPoint.self,
            ChatThreadModel.self,
            ChatMessageModel.self,
            InboxNotification.self,
        ]
    }
}

public enum LidIASchema {
    /// The iCloud container both apps sync through (private database, the user's own
    /// iCloud account).
    public static let cloudKitContainerID = "iCloud.io.lidia.app"

    public static var models: [any PersistentModel.Type] { LidIASchemaV4.models }

    public static var schema: Schema { Schema(versionedSchema: LidIASchemaV4.self) }
}

/// A random identifier for this install, kept in UserDefaults. Stamped on meetings this
/// device creates (`Meeting.originDeviceID`) so only that device recovers or processes
/// an unfinished one. A reinstall gets a new identifier.
public enum LidIADevice {
    public static let defaultsKey = "io.lidia.deviceID"

    public static let id: String = identifier(in: .standard)

    /// Reads or creates the identifier in `defaults`.
    public static func identifier(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: defaultsKey)
        return created
    }
}

/// Gives meetings that predate sync to the device that has them.
///
/// Runs once per install, right after the library opens and before launch recovery.
/// Meetings already in the library at that point were made here (or arrived through
/// the self-hosted sync server); stamping them lets this device keep recovering its
/// own unfinished recordings once other devices' meetings start arriving.
public enum LegacyMeetingOwnership {
    public static let defaultsKey = "io.lidia.legacyMeetingsClaimed.v1"

    /// Stamps every meeting without an origin with `deviceID`. Returns how many changed,
    /// or nil when it already ran.
    @discardableResult
    public static func claimOnce(
        in context: ModelContext,
        deviceID: String = LidIADevice.id,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard !defaults.bool(forKey: defaultsKey) else { return nil }
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.originDeviceID == nil })
        let meetings = (try? context.fetch(descriptor)) ?? []
        for meeting in meetings {
            meeting.originDeviceID = deviceID
        }
        do {
            if context.hasChanges { try context.save() }
            defaults.set(true, forKey: defaultsKey)
            return meetings.count
        } catch {
            return 0
        }
    }
}
