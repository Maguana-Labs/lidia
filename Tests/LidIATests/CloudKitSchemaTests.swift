import CoreData
import Foundation
import SwiftData
import Testing
@testable import LidIA

/// The Mac opens the same schema as the iPhone (both sync through one iCloud container).
@Suite("Mac library schema matches LidIAKit and CloudKit")
struct CloudKitSchemaTests {
    private func model(_ types: [any PersistentModel.Type]) throws -> NSManagedObjectModel {
        try #require(LidIASchemaAudit.managedObjectModel(for: types))
    }

    @Test("The Mac's schema is LidIAKit's, field by field")
    func parityWithLidIAKit() throws {
        let mac = try model(AppSchema.models)
        let kit = try model(LidIASchema.models)
        #expect(LidIASchemaAudit.fieldManifest(of: mac) == LidIASchemaAudit.fieldManifest(of: kit))
        #expect(AppSchema.versionIdentifier == LidIASchemaV4.versionIdentifier)
        // The container the app opens is built from the same list.
        let entityNames = Set(Schema(versionedSchema: AppSchema.self).entities.map(\.name))
        #expect(entityNames == Set(kit.entities.compactMap(\.name)))
    }

    @Test("Every model follows CloudKit's rules")
    func cloudKitRules() throws {
        let problems = LidIASchemaAudit.cloudKitViolations(in: try model(AppSchema.models))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Entity and property names are what the store (and LidiaMCP's read-only SQLite
    /// reader) and CloudKit's record types see. They must not change.
    @Test("Entity and column names the store and LidiaMCP use are unchanged")
    func storedNames() throws {
        let mac = try model(AppSchema.models)
        let meeting = try #require(mac.entitiesByName["Meeting"])
        for key in ["id", "title", "date", "duration", "rawTranscript", "refinedTranscript", "summary", "status",
                    "notes", "userEditedSummary", "userEditedTranscript", "calendarAttendees", "externalSourceID"] {
            #expect(meeting.propertiesByName[key] != nil, "Meeting.\(key)")
        }
        let item = try #require(mac.entitiesByName["ActionItem"])
        for key in ["id", "title", "isCompleted", "aiFingerprint", "workflowStatus", "meeting"] {
            #expect(item.propertiesByName[key] != nil, "ActionItem.\(key)")
        }
        // The renamed to-many sides keep their old names for migration.
        let actionItems = try #require(meeting.relationshipsByName["actionItemsStorage"])
        #expect(actionItems.renamingIdentifier == "actionItems")
        let messages = try #require(mac.entitiesByName["ChatThreadModel"]?.relationshipsByName["messagesStorage"])
        #expect(messages.renamingIdentifier == "messages")
    }

    /// Regenerate keeps what the user completed, edited or added (`aiFingerprint`), and the
    /// notes keep the user's edits (`userEdited*`). These must be synced fields, so the rule
    /// holds for an edit made on the other device.
    @Test("Provenance and user-edit fields are synced attributes")
    func provenanceFieldsSync() throws {
        let mac = try model(AppSchema.models)
        let stored: [(String, String)] = [
            ("ActionItem", "aiFingerprint"), ("ActionItem", "isCompleted"), ("ActionItem", "workflowStatus"),
            ("Meeting", "userEditedSummary"), ("Meeting", "userEditedTranscript"), ("Meeting", "notes"),
            ("Meeting", "structuredSummary"), ("Meeting", "originDeviceID"),
        ]
        for (entity, key) in stored {
            let attribute = try #require(mac.entitiesByName[entity]?.attributesByName[key], "\(entity).\(key)")
            #expect(!attribute.isTransient, "\(entity).\(key) must sync")
        }
    }

    @Test("An edit that arrives from another device makes the item the user's")
    func remoteEditKeepsItem() {
        let item = ActionItem(title: "Send the deck", assignee: "Ana")
        item.markAsAIGenerated()
        #expect(item.isUntouchedAIItem)
        // CloudKit import sets the fields the iPhone changed; the fingerprint came along.
        item.isCompleted = true
        #expect(item.isUserOwned)
    }
}
