import CoreData
import Foundation
import ObjectiveC
import SwiftData
import Testing
@testable import LidIAKit

/// The library schema the Mac and the iPhone sync through one iCloud container.
@Suite("Library schema and CloudKit")
struct LidIASchemaTests {
    private var model: NSManagedObjectModel {
        get throws { try #require(LidIASchemaAudit.managedObjectModel(for: LidIASchema.models)) }
    }

    @Test("Every model follows CloudKit's rules")
    func cloudKitRules() throws {
        let problems = LidIASchemaAudit.cloudKitViolations(in: try model)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("The audit catches what CloudKit rejects")
    func auditCatchesViolations() throws {
        let bad = try #require(LidIASchemaAudit.managedObjectModel(for: [BadParent.self, BadChild.self]))
        let problems = LidIASchemaAudit.cloudKitViolations(in: bad)
        #expect(problems.contains { $0.hasPrefix("BadParent: unique constraint") })
        #expect(problems.contains("BadParent.title: non-optional attribute without a default value"))
        #expect(problems.contains("BadParent.children: relationship must be optional"))
    }

    /// Core Data's own check, the one `NSPersistentCloudKitContainer` runs when the
    /// library opens with CloudKit. It's private API, so the test skips itself if the
    /// method ever disappears; the rule walk above still runs.
    @Test("Core Data's CloudKit validator accepts the schema")
    func coreDataValidatorAccepts() throws {
        guard let result = CoreDataCloudKitValidator.validate(try model) else { return }
        #expect(result.valid, "\(result.message)")

        let bad = try #require(LidIASchemaAudit.managedObjectModel(for: [BadParent.self, BadChild.self]))
        let badResult = try #require(CoreDataCloudKitValidator.validate(bad))
        #expect(!badResult.valid)
    }

    /// CloudKit fields are append-only: renaming or removing one strands the data in the
    /// old field and older app versions keep writing it. Changing this list must be a
    /// deliberate, additive schema change (see `LidIASchemaV4`).
    @Test("Fields match the frozen manifest")
    func frozenManifest() throws {
        let actual = LidIASchemaAudit.fieldManifest(of: try model)
        let missing = Self.expectedFields.filter { !actual.contains($0) }
        let added = actual.filter { !Self.expectedFields.contains($0) }
        #expect(missing.isEmpty, "Removed or changed fields: \(missing)")
        #expect(added.isEmpty, "New fields (add them to expectedFields once reviewed): \(added)")
    }

    @Test("Schema has the six library entities")
    func entities() throws {
        let names = Set(try model.entities.compactMap(\.name))
        #expect(names == ["Meeting", "ActionItem", "TalkingPoint", "ChatThreadModel", "ChatMessageModel", "InboxNotification"])
    }

    static let expectedFields: [String] = [
        "ActionItem.aiFingerprint: string",
        "ActionItem.assignee: string",
        "ActionItem.confirmedDestination: string",
        "ActionItem.deadline: string",
        "ActionItem.deadlineDate: date",
        "ActionItem.id: uuid",
        "ActionItem.isCompleted: bool",
        "ActionItem.meeting: to-one Meeting",
        "ActionItem.notionBlockID: string",
        "ActionItem.notionTaskPageID: string",
        "ActionItem.priority: string",
        "ActionItem.reminderID: string",
        "ActionItem.sourceQuote: string",
        "ActionItem.suggestedDestination: string",
        "ActionItem.title: string",
        "ActionItem.workflowStatus: string",
        "ChatMessageModel.attachmentsJSON: string",
        "ChatMessageModel.content: string",
        "ChatMessageModel.groundingConfidenceRawValue: string",
        "ChatMessageModel.id: uuid",
        "ChatMessageModel.role: string",
        "ChatMessageModel.sourceMeetingsJSON: string",
        "ChatMessageModel.thread: to-one ChatThreadModel",
        "ChatMessageModel.timestamp: date",
        "ChatThreadModel.createdAt: date",
        "ChatThreadModel.id: uuid",
        "ChatThreadModel.messagesStorage: to-many ChatMessageModel",
        "ChatThreadModel.scopeRawValue: string",
        "ChatThreadModel.title: string",
        "ChatThreadModel.updatedAt: date",
        "InboxNotification.actionPayload: string",
        "InboxNotification.body: string",
        "InboxNotification.createdAt: date",
        "InboxNotification.id: uuid",
        "InboxNotification.isRead: bool",
        "InboxNotification.meetingID: uuid",
        "InboxNotification.title: string",
        "InboxNotification.type: string",
        "Meeting.actionItemsStorage: to-many ActionItem",
        "Meeting.audioFilePath: string",
        "Meeting.calendarAttendees: transformable",
        "Meeting.calendarEventID: string",
        "Meeting.date: date",
        "Meeting.duration: double",
        "Meeting.externalSourceID: string",
        "Meeting.folder: string",
        "Meeting.id: uuid",
        "Meeting.notes: string",
        "Meeting.notionPageID: string",
        "Meeting.originDeviceID: string",
        "Meeting.processingError: string",
        "Meeting.processingRetryCount: integer",
        "Meeting.rawTranscript: data",
        "Meeting.refinedTranscript: string",
        "Meeting.status: composite",
        "Meeting.structuredSummary: data",
        "Meeting.summary: string",
        "Meeting.templateAutoDetected: bool",
        "Meeting.templateID: uuid",
        "Meeting.title: string",
        "Meeting.userEditedSummary: string",
        "Meeting.userEditedTranscript: string",
        "TalkingPoint.content: string",
        "TalkingPoint.createdDate: date",
        "TalkingPoint.id: uuid",
        "TalkingPoint.isUsed: bool",
        "TalkingPoint.personIdentifier: string",
    ]
}

// MARK: - Models that break the rules

@Model
final class BadParent {
    @Attribute(.unique) var key: String = ""
    var title: String
    @Relationship(deleteRule: .cascade, inverse: \BadChild.parent) var children: [BadChild] = []
    init(title: String) { self.title = title }
}

@Model
final class BadChild {
    var name: String = ""
    var parent: BadParent?
    init() {}
}

// MARK: - Core Data's validator

/// Calls `-[NSCloudKitMirroringDelegate validateManagedObjectModel:forUseWithStoreWithDescription:error:]`,
/// the check that rejects a model when a CloudKit-backed store loads. Returns nil when
/// the private method isn't there.
enum CoreDataCloudKitValidator {
    struct Result {
        let valid: Bool
        let message: String
    }

    static func validate(_ model: NSManagedObjectModel) -> Result? {
        guard let delegateClass = NSClassFromString("NSCloudKitMirroringDelegate") as? NSObject.Type,
              let optionsClass = NSClassFromString("NSCloudKitMirroringDelegateOptions") as? NSObject.Type
        else { return nil }
        let containerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: LidIASchema.cloudKitContainerID)
        // alloc + init by selector: these classes have no public initializers. The objects
        // leak, which is fine in a test.
        let alloc = NSSelectorFromString("alloc")
        let initOptions = NSSelectorFromString("initWithCloudKitContainerOptions:")
        let initDelegate = NSSelectorFromString("initWithOptions:")
        let validateSelector = NSSelectorFromString("validateManagedObjectModel:forUseWithStoreWithDescription:error:")
        guard optionsClass.instancesRespond(to: initOptions),
              delegateClass.instancesRespond(to: initDelegate),
              delegateClass.instancesRespond(to: validateSelector),
              let allocatedOptions = (optionsClass as AnyObject).perform(alloc)?.takeUnretainedValue() as? NSObject,
              let options = allocatedOptions.perform(initOptions, with: containerOptions)?.takeUnretainedValue() as? NSObject,
              let allocatedDelegate = (delegateClass as AnyObject).perform(alloc)?.takeUnretainedValue() as? NSObject,
              let delegate = allocatedDelegate.perform(initDelegate, with: options)?.takeUnretainedValue() as? NSObject,
              let implementation = delegate.method(for: validateSelector)
        else { return nil }

        let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        description.cloudKitContainerOptions = containerOptions
        // SwiftData always turns history tracking on; the validator requires it.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        typealias Validate = @convention(c) (
            AnyObject, Selector, NSManagedObjectModel, NSPersistentStoreDescription, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> Bool
        let validate = unsafeBitCast(implementation, to: Validate.self)
        var error: NSError?
        let valid = validate(delegate, validateSelector, model, description, &error)
        let reason = error?.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        return Result(valid: valid, message: reason ?? error?.localizedDescription ?? "")
    }
}
