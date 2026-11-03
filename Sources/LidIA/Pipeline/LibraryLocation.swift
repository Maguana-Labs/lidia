import Foundation
import SQLite3
import os

private let libraryLocationLogger = Logger(subsystem: "io.lidia.app", category: "LibraryLocation")

/// Where LidIA keeps its SwiftData library.
///
/// Earlier builds used SwiftData's default URL, `~/Library/Application Support/default.store`,
/// which every unsandboxed SwiftData app on the Mac shares. The library now lives in its own
/// folder; an existing LidIA library at the old path is copied over once and left in place.
enum LibraryLocation {
    static let storeFileName = "LidIA.store"

    static var folder: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LidIA", isDirectory: true)
    }

    static var storeURL: URL { folder.appendingPathComponent(storeFileName) }

    static var backupsRoot: URL { folder.appendingPathComponent("Library Backups", isDirectory: true) }

    static var legacyStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store")
    }

    /// Copies the legacy shared store to `storeURL` when the new store does not exist yet and
    /// the legacy file is a LidIA library. Never modifies or deletes the legacy files.
    ///
    /// Skipped once library recovery has run (a saved `StoreRecoveryNotice`, or any
    /// `recovered-*` folder in `backupsRoot`): a missing store then means recovery moved
    /// it aside, and copying the old `default.store` back in would silently resurrect
    /// stale data in its place.
    @discardableResult
    static func migrateLegacyStoreIfNeeded(
        legacyStoreURL: URL = legacyStoreURL,
        storeURL: URL = storeURL,
        backupsRoot: URL = backupsRoot,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !fileManager.fileExists(atPath: storeURL.path),
              fileManager.fileExists(atPath: legacyStoreURL.path) else { return false }
        if recoveryHasRun(backupsRoot: backupsRoot, defaults: defaults, fileManager: fileManager) {
            libraryLocationLogger.info("Skipping legacy library copy: library recovery has run before")
            return false
        }
        guard isLidIAStore(at: legacyStoreURL) else { return false }

        let sourceDir = legacyStoreURL.deletingLastPathComponent()
        let targetDir = storeURL.deletingLastPathComponent()
        let sourceBase = legacyStoreURL.deletingPathExtension().lastPathComponent
        let targetBase = storeURL.deletingPathExtension().lastPathComponent
        let staging = targetDir.appendingPathComponent(".migrating-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            // The WAL and SHM sidecars must travel with the store, and external-storage
            // attributes live in the hidden `.<name>_SUPPORT` folder.
            let pairs: [(String, String)] = [
                (legacyStoreURL.lastPathComponent, storeURL.lastPathComponent),
                (legacyStoreURL.lastPathComponent + "-wal", storeURL.lastPathComponent + "-wal"),
                (legacyStoreURL.lastPathComponent + "-shm", storeURL.lastPathComponent + "-shm"),
                (".\(sourceBase)_SUPPORT", ".\(targetBase)_SUPPORT"),
            ]
            var copied: [String] = []
            for (from, to) in pairs {
                let source = sourceDir.appendingPathComponent(from)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: staging.appendingPathComponent(to))
                copied.append(to)
            }
            // All or nothing: refuses if any target name exists (e.g. an orphan -wal that
            // SQLite would replay into the copied store) and rolls back a partial move,
            // so the store never lands without its -wal.
            try StoreGuardian.moveAllOrNothing(
                copied.map { (from: staging.appendingPathComponent($0), to: targetDir.appendingPathComponent($0)) },
                fileManager: fileManager
            )
            try? fileManager.removeItem(at: staging)
            libraryLocationLogger.info("Copied legacy library to \(storeURL.path, privacy: .public)")
            return true
        } catch {
            try? fileManager.removeItem(at: staging)
            libraryLocationLogger.error("Legacy library copy failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// True when a recovery notice is saved or `backupsRoot` holds a `recovered-*` folder.
    static func recoveryHasRun(backupsRoot: URL, defaults: UserDefaults, fileManager: FileManager = .default) -> Bool {
        if StoreGuardian.loadNotice(defaults: defaults) != nil { return true }
        let entries = (try? fileManager.contentsOfDirectory(atPath: backupsRoot.path)) ?? []
        return entries.contains { $0.hasPrefix(StoreGuardian.recoveredPrefix) }
    }

    /// True when the SQLite file has LidIA's meeting table.
    static func isLidIAStore(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZMEETING'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
