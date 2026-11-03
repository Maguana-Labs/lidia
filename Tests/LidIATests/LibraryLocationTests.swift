import Foundation
import SQLite3
import Testing
@testable import LidIA

/// Fails `moveItem` whose destination has the given file name; otherwise a normal FileManager.
final class FailingMoveFileManager: FileManager, @unchecked Sendable {
    let failName: String

    init(failWhenMovingTo name: String) {
        failName = name
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == failName {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: dstURL.path])
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@Suite("LibraryLocation")
struct LibraryLocationTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryLocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSQLite(at url: URL, table: String) {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE \(table) (Z_PK INTEGER PRIMARY KEY)", nil, nil, nil)
        sqlite3_close(db)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "lidia.tests.library.\(UUID().uuidString)")!
    }

    /// Never reads the real user's backups folder or defaults.
    private func migrate(
        legacy: URL,
        store: URL,
        backupsRoot: URL? = nil,
        defaults: UserDefaults? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        LibraryLocation.migrateLegacyStoreIfNeeded(
            legacyStoreURL: legacy,
            storeURL: store,
            backupsRoot: backupsRoot ?? store.deletingLastPathComponent().appendingPathComponent("Library Backups"),
            defaults: defaults ?? freshDefaults(),
            fileManager: fileManager
        )
    }

    /// A legacy LidIA library with a WAL and external data, and an empty target folder.
    private func makeLegacyLibrary() throws -> (dir: URL, legacy: URL, target: URL, store: URL) {
        let dir = try tempDir()
        let legacy = dir.appendingPathComponent("default.store")
        makeSQLite(at: legacy, table: "ZMEETING")
        try Data("wal".utf8).write(to: dir.appendingPathComponent("default.store-wal"))
        let support = dir.appendingPathComponent(".default_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: support.appendingPathComponent("x"))

        let target = dir.appendingPathComponent("LidIA", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (dir, legacy, target, target.appendingPathComponent("LidIA.store"))
    }

    @Test("Copies a legacy LidIA library with its sidecars and leaves the original")
    func copiesLidIAStore() throws {
        let (dir, legacy, target, store) = try makeLegacyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(migrate(legacy: legacy, store: store))
        #expect(LibraryLocation.isLidIAStore(at: store))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("LidIA.store-wal").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(".LidIA_SUPPORT/_EXTERNAL_DATA/x").path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        // A second launch finds the new store and copies nothing.
        #expect(!migrate(legacy: legacy, store: store))
    }

    @Test("Ignores a shared default.store that belongs to another app")
    func ignoresForeignStore() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("default.store")
        makeSQLite(at: legacy, table: "ZOTHERTHING")
        let store = dir.appendingPathComponent("LidIA.store")

        #expect(!migrate(legacy: legacy, store: store))
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test("Does not resurrect the legacy library after recovery moved the store aside")
    func skipsAfterRecoveredFolder() throws {
        let (dir, legacy, target, store) = try makeLegacyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = target.appendingPathComponent("Library Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("recovered-2026-11-01T10-00-00"), withIntermediateDirectories: true)

        #expect(!migrate(legacy: legacy, store: store, backupsRoot: root))
        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("LidIA.store-wal").path))
    }

    @Test("Refuses to copy next to an orphan sidecar and leaves nothing behind")
    func refusesWhenTargetNameExists() throws {
        let (dir, legacy, target, store) = try makeLegacyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = target.appendingPathComponent("LidIA.store-wal")
        try Data("orphan".utf8).write(to: orphan)

        #expect(!migrate(legacy: legacy, store: store))
        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(try Data(contentsOf: orphan) == Data("orphan".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(leftovers == ["LidIA.store-wal"])
    }

    @Test("A failed move partway through is rolled back")
    func rollsBackPartialMove() throws {
        let (dir, legacy, target, store) = try makeLegacyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing = FailingMoveFileManager(failWhenMovingTo: "LidIA.store-wal")

        #expect(!migrate(legacy: legacy, store: store, fileManager: failing))
        // The store was moved first, then the -wal failed: the store must not stay alone.
        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Does not resurrect the legacy library while a recovery notice is saved")
    func skipsWithSavedNotice() throws {
        let (dir, legacy, _, store) = try makeLegacyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = freshDefaults()
        StoreGuardian.saveNotice(
            StoreRecoveryNotice(backupPath: "/tmp/x", date: Date(), reason: "corrupt", isTemporaryLibrary: true),
            defaults: defaults
        )

        #expect(!migrate(legacy: legacy, store: store, defaults: defaults))
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }
}
