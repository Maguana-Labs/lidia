import Foundation
import SwiftData
import Testing
@testable import LidIA

@Suite("iCloud sync setup on the Mac")
struct CloudSyncSetupTests {
    private func freshDefaults() -> UserDefaults {
        let name = "lidia.tests.cloudsync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-cloudsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Mode

    @Test("Sync runs only when entitled, not local-only and chosen")
    func modeResolution() {
        #expect(LibrarySyncMode.resolve(isolatedLibrary: false, entitled: true, localOnly: false, preference: .on) == .iCloud)
        #expect(LibrarySyncMode.resolve(isolatedLibrary: false, entitled: true, localOnly: true, preference: .on) == .off(.localOnly))
        #expect(LibrarySyncMode.resolve(isolatedLibrary: false, entitled: false, localOnly: false, preference: .on) == .off(.notAvailableInThisBuild))
        #expect(LibrarySyncMode.resolve(isolatedLibrary: true, entitled: true, localOnly: false, preference: .on) == .off(.isolatedLibrary))
        #expect(LibrarySyncMode.resolve(isolatedLibrary: false, entitled: true, localOnly: false, preference: .off) == .off(.turnedOff))
        #expect(LibrarySyncMode.resolve(isolatedLibrary: false, entitled: true, localOnly: false, preference: .askFirst) == .off(.awaitingConsent))
        #expect(LibrarySyncMode.iCloud.isICloud)
        #expect(!LibrarySyncMode.off(.localOnly).isICloud)
        #expect(LibrarySyncMode.off(.localOnly).explanation?.contains("Local-only") == true)
    }

    @Test("New installs sync by default; an existing library is asked once")
    func defaultChoice() {
        let fresh = freshDefaults()
        #expect(CloudSyncPreference.resolveAtLaunch(libraryExists: false, defaults: fresh) == .on)
        // The stored choice sticks even once a library exists.
        #expect(CloudSyncPreference.resolveAtLaunch(libraryExists: true, defaults: fresh) == .on)

        let existing = freshDefaults()
        #expect(CloudSyncPreference.resolveAtLaunch(libraryExists: true, defaults: existing) == .askFirst)
        CloudSyncPreference.set(.off, defaults: existing)
        #expect(CloudSyncPreference.resolveAtLaunch(libraryExists: true, defaults: existing) == .off)
    }

    // MARK: Backups

    @Test("Milestone backups are verified and never pruned")
    func milestoneBackup() throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = library.appendingPathComponent("LidIA.store")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/LibraryV3/LidIA.store")
        try FileManager.default.copyItem(at: fixture, to: store)
        let backups = root.appendingPathComponent("Library Backups", isDirectory: true)

        let folder = try #require(try StoreGuardian.makeMilestoneBackup(label: "schema-4", storeURL: store, backupsRoot: backups))
        #expect(folder.lastPathComponent.hasPrefix("before-schema-4-"))
        #expect(StoreGuardian.backupIsReadable(folder.appendingPathComponent("LidIA.store")))

        // Daily pruning keeps only daily-* folders in check.
        for day in ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04"] {
            try FileManager.default.createDirectory(at: backups.appendingPathComponent("daily-\(day)"), withIntermediateDirectories: true)
        }
        StoreGuardian.pruneDailyBackups(in: backups, keep: 3)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("An unreadable store isn't accepted as a backup")
    func unreadableBackupFails() throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("LidIA.store")
        try Data("not a database".utf8).write(to: store)
        let backups = root.appendingPathComponent("Library Backups", isDirectory: true)
        #expect(throws: (any Error).self) {
            try StoreGuardian.makeMilestoneBackup(label: "icloud-sync", storeURL: store, backupsRoot: backups)
        }
        // No half-made backup is left behind.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        #expect(left.allSatisfy { !$0.hasPrefix("before-") && !$0.hasPrefix(".staging") })
    }

    @Test("Backups run once before the schema upgrade and once before the first sync")
    func preparedBackups() throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("LidIA.store")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/LibraryV3/LidIA.store")
        try FileManager.default.copyItem(at: fixture, to: store)
        let backups = root.appendingPathComponent("Library Backups", isDirectory: true)
        let defaults = freshDefaults()

        let off = LibraryMilestoneBackups.prepare(mode: .off(.turnedOff), storeURL: store, backupsRoot: backups, defaults: defaults)
        #expect(off.mode == .off(.turnedOff))
        #expect(defaults.bool(forKey: LibraryMilestoneBackups.schema4Key))
        #expect(!defaults.bool(forKey: LibraryMilestoneBackups.firstICloudKey))

        let on = LibraryMilestoneBackups.prepare(mode: .iCloud, storeURL: store, backupsRoot: backups, defaults: defaults)
        #expect(on.mode == .iCloud)
        #expect(on.problem == nil)
        #expect(defaults.bool(forKey: LibraryMilestoneBackups.firstICloudKey))
        _ = LibraryMilestoneBackups.prepare(mode: .iCloud, storeURL: store, backupsRoot: backups, defaults: defaults)

        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        #expect(names.filter { $0.hasPrefix("before-schema-4-") }.count == 1)
        #expect(names.filter { $0.hasPrefix("before-icloud-sync-") }.count == 1)
    }

    @Test("Sync stays off when the backup before the first sync fails")
    func failedBackupKeepsSyncOff() throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("LidIA.store")
        try Data("not a database".utf8).write(to: store)
        let defaults = freshDefaults()
        let result = LibraryMilestoneBackups.prepare(
            mode: .iCloud, storeURL: store, backupsRoot: root.appendingPathComponent("Library Backups"), defaults: defaults
        )
        #expect(result.mode == .off(.turnedOff))
        #expect(result.problem?.contains("sync stays off") == true)
        #expect(!defaults.bool(forKey: LibraryMilestoneBackups.firstICloudKey))
    }

    // MARK: Settings

    @Test("Settings search finds iCloud sync and the self-hosted server")
    func search() {
        #expect(SettingsSearchIndex.search("Sync with iCloud").first?.anchor == .iCloudSync)
        #expect(SettingsSearchIndex.search("icloud").map(\.anchor).contains(.iCloudSync))
        #expect(SettingsSearchIndex.search("iphone").map(\.anchor).contains(.iCloudSync))
        #expect(SettingsSearchIndex.search("sync status").first?.anchor == .iCloudStatus)
        #expect(SettingsSearchIndex.search("self-hosted").first?.anchor == .deviceSync)
        #expect(SettingsSearchIndex.search("sync server").first?.location.pane == .sync)
    }
}
