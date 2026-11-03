import CloudKit
import CoreData
import Foundation
import SwiftData
import Testing
@testable import LidIAKit

@Suite("iCloud sync support")
@MainActor
struct CloudSyncTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LidIASchema.schema,
            configurations: [ModelConfiguration(schema: LidIASchema.schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "CloudSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Ownership

    @Test("New meetings belong to this device")
    func newMeetingsAreStamped() {
        let meeting = Meeting(title: "Mine")
        #expect(meeting.originDeviceID == LidIADevice.id)
        #expect(meeting.isOwnedByThisDevice)
        #expect(!Meeting(title: "Theirs", originDeviceID: "other-device").isOwnedByThisDevice)
        #expect(!Meeting(title: "Unknown", originDeviceID: nil).isOwnedByThisDevice)
    }

    @Test("Legacy meetings are claimed once, other devices' are left alone")
    func legacyClaim() throws {
        let context = try makeContext()
        let defaults = freshDefaults()
        let legacy = Meeting(title: "Old", originDeviceID: nil)
        let foreign = Meeting(title: "iPhone", originDeviceID: "iphone")
        context.insert(legacy)
        context.insert(foreign)
        try context.save()

        #expect(LegacyMeetingOwnership.claimOnce(in: context, deviceID: "mac", defaults: defaults) == 1)
        #expect(legacy.originDeviceID == "mac")
        #expect(foreign.originDeviceID == "iphone")

        // A second run does nothing, even for meetings that arrive later without an origin.
        let late = Meeting(title: "Synced later", originDeviceID: nil)
        context.insert(late)
        #expect(LegacyMeetingOwnership.claimOnce(in: context, deviceID: "mac", defaults: defaults) == nil)
        #expect(late.originDeviceID == nil)
    }

    @Test("The device identifier is stable per defaults domain")
    func deviceIdentifier() {
        let defaults = freshDefaults()
        let first = LidIADevice.identifier(in: defaults)
        #expect(!first.isEmpty)
        #expect(LidIADevice.identifier(in: defaults) == first)
        #expect(LidIADevice.identifier(in: freshDefaults()) != first)
    }

    // MARK: Optional relationships

    @Test("actionItems reads and writes the optional relationship")
    func actionItemsWrapper() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Sync")
        context.insert(meeting)
        meeting.actionItemsStorage = nil
        #expect(meeting.actionItems.isEmpty)

        let item = ActionItem(title: "Send deck")
        meeting.actionItems.append(item)
        try context.save()
        #expect(meeting.actionItems.map(\.title) == ["Send deck"])
        #expect(item.meeting === meeting)

        let thread = ChatThreadModel(title: "Q")
        context.insert(thread)
        thread.messages = [ChatMessageModel(role: "user", content: "Hi", thread: thread)]
        try context.save()
        #expect(thread.messages.count == 1)
    }

    // MARK: Status

    @Test("A finished import records the last sync and clears the error")
    func monitorRecordsSuccess() {
        let defaults = freshDefaults()
        let monitor = CloudSyncMonitor(isActive: true, defaults: defaults)
        monitor.apply(.init(type: .export, finished: false, succeeded: false, endDate: nil, errorText: nil))
        #expect(monitor.activity == .exporting)

        monitor.apply(.init(type: .export, finished: true, succeeded: false, endDate: Date(), errorText: "No internet connection."))
        #expect(monitor.lastError == "No internet connection.")
        #expect(monitor.lastSyncDate == nil)

        let done = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.apply(.init(type: .import, finished: true, succeeded: true, endDate: done, errorText: nil))
        #expect(monitor.activity == .idle)
        #expect(monitor.lastError == nil)
        #expect(monitor.lastSyncDate == done)
        #expect(CloudSyncMonitor(isActive: true, defaults: defaults).lastSyncDate == done)
    }

    @Test("Setup events don't count as a sync")
    func setupIsNotASync() {
        let monitor = CloudSyncMonitor(isActive: true, defaults: freshDefaults())
        monitor.apply(.init(type: .setup, finished: true, succeeded: true, endDate: Date(), errorText: nil))
        #expect(monitor.lastSyncDate == nil)
    }

    @Test("Errors are explained in plain words")
    func errorWords() {
        #expect(CloudSyncText.describe(CKError(.quotaExceeded))?.contains("iCloud storage is full") == true)
        #expect(CloudSyncText.describe(CKError(.networkUnavailable))?.contains("No internet") == true)
        #expect(CloudSyncText.describe(CKError(.notAuthenticated))?.contains("not signed in") == true)
        #expect(CloudSyncText.describe(CKError(.operationCancelled)) == nil)
        #expect(CloudSyncText.describe(NSError(domain: NSCocoaErrorDomain, code: 134_400))?.contains("not signed in") == true)
        #expect(CloudSyncText.describe(NSError(domain: NSCocoaErrorDomain, code: 134_419)) == nil)
        #expect(CloudSyncAccount.noAccount.problem != nil)
        #expect(CloudSyncAccount.available.problem == nil)
    }

    @Test("The encryption note is factual about Advanced Data Protection")
    func encryptionNote() {
        #expect(CloudSyncText.encryptionNote.contains("Advanced Data Protection"))
        #expect(CloudSyncText.encryptionNote.contains("Audio recordings never sync"))
    }
}
