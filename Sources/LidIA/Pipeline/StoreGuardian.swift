import Foundation
import Observation
import SQLite3
import SwiftData
import os

/// Shown to the user after the library could not be opened.
struct StoreRecoveryNotice: Codable, Sendable, Equatable {
    /// Why the library couldn't be opened. Nil in notices saved by older builds
    /// (those always mean the library was moved aside).
    enum Kind: String, Codable, Sendable {
        /// The store looked corrupt and was moved to a `recovered-*` folder.
        case movedAside
        /// The store is intact but this build can't open it (made by a newer version,
        /// or a migration failed). The files were not touched.
        case incompatible
        /// The store couldn't be opened for another reason (permissions, locked file…).
        /// The files were not touched.
        case unreadable
    }

    /// Folder holding the previous library files (store, -wal, -shm, external data).
    /// For `.incompatible` / `.unreadable` this is the library's own folder, untouched.
    let backupPath: String
    let date: Date
    /// Underlying open error, for support.
    let reason: String
    /// True when the app is running on a temporary in-memory library (nothing will be
    /// saved this session).
    let isTemporaryLibrary: Bool
    var kind: Kind? = nil

    var backupURL: URL { URL(fileURLWithPath: backupPath, isDirectory: true) }

    /// Ready-to-show message: "Your previous library was backed up to …".
    var message: String {
        switch kind {
        case .incompatible:
            return String(localized: "This version of LidIA couldn't open your library — it may have been created by a newer version. Your library was not changed and is still at \(backupPath). Changes made now won't be saved; update LidIA or contact support.")
        case .unreadable:
            return String(localized: "LidIA couldn't open your library. Your library was not changed and is still at \(backupPath). Changes made now won't be saved — please contact support.")
        case .movedAside, nil:
            break
        }
        if isTemporaryLibrary {
            return String(localized: "LidIA couldn't open your library. It was backed up to \(backupPath). Changes made now won't be saved — please contact support.")
        }
        return String(localized: "Your previous library couldn't be opened, so LidIA started a new one. Your previous library was backed up to \(backupPath).")
    }
}

/// Opens the SwiftData store without ever deleting user data.
///
/// - Before opening, makes a rolling daily copy of the store (keeps the newest 3).
/// - If the store fails to open twice and looks corrupt, moves it to a timestamped
///   backup folder, opens a fresh store, and records a `StoreRecoveryNotice` for the UI
///   (`LibraryHealth`).
/// - If it fails for any other reason (e.g. a newer version's library), leaves the files
///   alone and runs on a temporary in-memory library with a notice explaining why.
enum StoreGuardian {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "StoreGuardian")

    static let noticeDefaultsKey = "storeRecoveryNotice.v1"
    static let dailyBackupsToKeep = 3
    static let dailyPrefix = "daily-"
    static let recoveredPrefix = "recovered-"

    /// `<store folder>/LidIA/Library Backups`
    static func backupsRoot(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent("LidIA", isDirectory: true)
            .appendingPathComponent("Library Backups", isDirectory: true)
    }

    /// The store file plus its SQLite sidecars and SwiftData's external-storage folder
    /// (`default.store`, `default.store-wal`, `default.store-shm`, `.default_SUPPORT`).
    static func storeFiles(for storeURL: URL, fileManager: FileManager = .default) -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        let base = storeURL.deletingPathExtension().lastPathComponent
        let supportName = ".\(base)_SUPPORT"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries
            .filter { $0 == name || $0.hasPrefix(name + "-") || $0 == supportName }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Daily backup

    /// Copies the store into `daily-YYYY-MM-DD` unless today's copy exists, then prunes to
    /// the newest `keep`. Returns the new backup folder, or nil if nothing was copied.
    @discardableResult
    static func makeDailyBackup(
        storeURL: URL,
        backupsRoot: URL,
        now: Date = Date(),
        keep: Int = dailyBackupsToKeep,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let files = storeFiles(for: storeURL, fileManager: fileManager)
        guard files.contains(where: { $0.lastPathComponent == storeURL.lastPathComponent }) else { return nil }

        let folder = backupsRoot.appendingPathComponent(dailyPrefix + dayStamp(now), isDirectory: true)
        guard !fileManager.fileExists(atPath: folder.path) else { return nil }

        // Copy into a temp folder first so a half-written backup never counts as today's.
        let staging = backupsRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                try fileManager.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            }
            try fileManager.moveItem(at: staging, to: folder)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        pruneDailyBackups(in: backupsRoot, keep: keep, fileManager: fileManager)
        return folder
    }

    // MARK: - Milestone backups

    static let milestonePrefix = "before-"

    /// Copies the store into `before-<label>-<timestamp>`, a folder the daily pruning never
    /// touches, and checks the copy opens and passes `quick_check`. Taken before a step
    /// that changes the library for good (a schema upgrade, the first iCloud sync).
    /// Returns nil when there is no store yet; throws when the copy fails or is unreadable.
    @discardableResult
    static func makeMilestoneBackup(
        label: String,
        storeURL: URL,
        backupsRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL? {
        let files = storeFiles(for: storeURL, fileManager: fileManager)
        guard files.contains(where: { $0.lastPathComponent == storeURL.lastPathComponent }) else { return nil }

        var folder = backupsRoot.appendingPathComponent(milestonePrefix + label + "-" + timeStamp(now), isDirectory: true)
        var suffix = 1
        while fileManager.fileExists(atPath: folder.path) {
            suffix += 1
            folder = backupsRoot.appendingPathComponent(milestonePrefix + label + "-" + timeStamp(now) + "-\(suffix)", isDirectory: true)
        }
        let staging = backupsRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                try fileManager.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            }
            guard backupIsReadable(staging.appendingPathComponent(storeURL.lastPathComponent)) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: staging.path])
            }
            try fileManager.moveItem(at: staging, to: folder)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return folder
    }

    /// True when the copied store opens, passes `quick_check` and has LidIA's meeting table.
    /// Opens read-write so SQLite can use the copied -wal; it's a copy, never the library.
    static func backupIsReadable(_ copiedStore: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(copiedStore.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        func firstText(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        return firstText("PRAGMA quick_check") == "ok"
            && firstText("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZMEETING'") == "ZMEETING"
    }

    /// Deletes the oldest `daily-*` folders beyond `keep`. Never touches `recovered-*`.
    static func pruneDailyBackups(in backupsRoot: URL, keep: Int, fileManager: FileManager = .default) {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: backupsRoot.path) else { return }
        let daily = entries.filter { $0.hasPrefix(dailyPrefix) }.sorted() // ISO dates sort chronologically
        guard daily.count > keep else { return }
        for name in daily.prefix(daily.count - keep) {
            try? fileManager.removeItem(at: backupsRoot.appendingPathComponent(name))
        }
    }

    // MARK: - Move aside

    /// Moves every store file into `recovered-<timestamp>` and returns that folder.
    /// All or nothing: on failure the files already moved are put back and the empty
    /// folder is removed, so a store never ends up separated from its `-wal`.
    static func moveStoreAside(
        storeURL: URL,
        backupsRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        var folder = backupsRoot.appendingPathComponent(recoveredPrefix + timeStamp(now), isDirectory: true)
        var suffix = 1
        while fileManager.fileExists(atPath: folder.path) {
            suffix += 1
            folder = backupsRoot.appendingPathComponent(recoveredPrefix + timeStamp(now) + "-\(suffix)", isDirectory: true)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let moves = storeFiles(for: storeURL, fileManager: fileManager).map {
            (from: $0, to: folder.appendingPathComponent($0.lastPathComponent))
        }
        do {
            try moveAllOrNothing(moves, fileManager: fileManager)
        } catch {
            // Leave no empty recovered-* folder behind: it would mean "recovery ran".
            if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false {
                try? fileManager.removeItem(at: folder)
            }
            throw error
        }
        return folder
    }

    /// Moves every pair or none. Fails up front, without moving anything, if any
    /// destination already exists; if a move fails partway, moves the files already
    /// moved back to where they were before rethrowing.
    static func moveAllOrNothing(_ moves: [(from: URL, to: URL)], fileManager: FileManager = .default) throws {
        if let clash = moves.first(where: { itemExists(at: $0.to, fileManager: fileManager) }) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: clash.to.path])
        }
        var done: [(from: URL, to: URL)] = []
        do {
            for move in moves {
                try fileManager.moveItem(at: move.from, to: move.to)
                done.append(move)
            }
        } catch {
            for move in done.reversed() {
                do {
                    try fileManager.moveItem(at: move.to, to: move.from)
                } catch let rollbackError {
                    logger.fault("Could not move \(move.to.path, privacy: .public) back to \(move.from.path, privacy: .public): \(rollbackError)")
                }
            }
            throw error
        }
    }

    /// Like `fileExists`, but also true for a dangling symlink.
    private static func itemExists(at url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: - Failure classification

    enum OpenFailure: Equatable {
        /// The file is damaged or isn't a database: moving it aside is the right fix.
        case corrupt
        /// The file is a healthy database this build can't open (newer model, failed
        /// migration). Moving it aside would hide intact data, so leave it alone.
        case incompatible
        /// Anything else (permissions, locks, missing file). Leave the files alone.
        case other
    }

    /// Core Data codes meaning the file itself is damaged.
    private static let corruptCocoaCodes: Set<Int> = [
        259, // NSFileReadCorruptFileError
    ]
    /// SQLITE_CORRUPT, SQLITE_NOTADB.
    private static let corruptSQLiteCodes: Set<Int> = [11, 26]
    /// Core Data codes meaning the store is readable but the model doesn't match:
    /// NSPersistentStoreIncompatibleSchemaError, NSPersistentStoreIncompatibleVersionHashError,
    /// and the NSMigration*/NSEntityMigrationPolicy/NSInferredMappingModel range.
    private static func isIncompatibleCocoaCode(_ code: Int) -> Bool {
        code == 134_020 || code == 134_100 || (134_110...134_190).contains(code)
    }

    /// Decides whether an open failure means the store is corrupt. Checks the error
    /// chain first; SwiftData often hides the underlying error, so when the error says
    /// nothing useful, probes the SQLite file directly: a file that SQLite reads and
    /// that passes `quick_check` is not corrupt.
    static func classify(_ error: Error, storeURL: URL, fileManager: FileManager = .default) -> OpenFailure {
        let chain = errorChain(error)
        // Corruption anywhere in the chain wins (a migration can fail *because* the file is damaged).
        if chain.contains(where: {
            ($0.domain == NSCocoaErrorDomain && corruptCocoaCodes.contains($0.code))
                || ($0.domain == "NSSQLiteErrorDomain" && corruptSQLiteCodes.contains($0.code & 0xFF))
        }) {
            return .corrupt
        }
        if chain.contains(where: { $0.domain == NSCocoaErrorDomain && isIncompatibleCocoaCode($0.code) }) {
            return .incompatible
        }
        guard fileManager.fileExists(atPath: storeURL.path) else { return .other }
        return probeSQLite(at: storeURL)
    }

    /// Opens the store read-only and runs `PRAGMA quick_check`.
    static func probeSQLite(at url: URL) -> OpenFailure {
        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard openCode == SQLITE_OK else {
            return isCorruptSQLiteCode(openCode) ? .corrupt : .other
        }
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareCode == SQLITE_OK else {
            return isCorruptSQLiteCode(prepareCode) ? .corrupt : .other
        }
        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_ROW else {
            return isCorruptSQLiteCode(stepCode) ? .corrupt : .other
        }
        let result = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        return result == "ok" ? .incompatible : .corrupt
    }

    private static func isCorruptSQLiteCode(_ code: Int32) -> Bool {
        corruptSQLiteCodes.contains(Int(code & 0xFF))
    }

    /// The error plus its underlying and detailed errors, breadth first.
    private static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var queue: [NSError] = [error as NSError]
        while !queue.isEmpty, result.count < 32 {
            let current = queue.removeFirst()
            result.append(current)
            // NSUnderlyingErrorKey and NSMultipleUnderlyingErrorsKey.
            queue.append(contentsOf: current.underlyingErrors.map { $0 as NSError })
            // Core Data's NSDetailedErrorsKey (validation and multi-store failures).
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                queue.append(contentsOf: detailed)
            }
        }
        return result
    }

    // MARK: - Open

    struct OpenResult {
        let container: ModelContainer
        let notice: StoreRecoveryNotice?
    }

    /// Opens the container at `storeURL` safely. `open` is injectable for tests.
    static func openContainer(
        storeURL: URL,
        backupsRoot: URL? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default,
        open: (URL) throws -> ModelContainer,
        openInMemory: () throws -> ModelContainer
    ) -> OpenResult {
        let root = backupsRoot ?? Self.backupsRoot(for: storeURL)

        do {
            try makeDailyBackup(storeURL: storeURL, backupsRoot: root, now: now, fileManager: fileManager)
        } catch {
            logger.error("Daily library backup failed (continuing): \(error.localizedDescription)")
        }

        var lastError: Error
        do {
            return OpenResult(container: try open(storeURL), notice: nil)
        } catch {
            logger.error("ModelContainer failed: \(error). Retrying once…")
            lastError = error
        }
        do {
            return OpenResult(container: try open(storeURL), notice: nil)
        } catch {
            logger.error("ModelContainer failed twice: \(error)")
            lastError = error
        }

        // Only a damaged file is moved aside. A healthy store this build can't open (a
        // newer version's library, a migration bug) stays exactly where it is: moving it
        // would leave the user an empty library with their data hidden in a backup.
        let failure = classify(lastError, storeURL: storeURL, fileManager: fileManager)
        guard failure == .corrupt else {
            logger.error("Library is not corrupt (\(String(describing: failure))); leaving it in place and using a temporary in-memory library.")
            let notice = StoreRecoveryNotice(
                backupPath: storeURL.deletingLastPathComponent().path,
                date: now,
                reason: "\(lastError)",
                isTemporaryLibrary: true,
                kind: failure == .incompatible ? .incompatible : .unreadable
            )
            return OpenResult(container: inMemoryOrDie(openInMemory), notice: notice)
        }
        logger.error("Library looks corrupt. Moving it aside.")

        let backupFolder: URL
        do {
            backupFolder = try moveStoreAside(storeURL: storeURL, backupsRoot: root, now: now, fileManager: fileManager)
        } catch {
            // Could not move the files: do not touch them; run on a temporary library.
            logger.error("Could not move library aside: \(error). Using a temporary in-memory library.")
            let notice = StoreRecoveryNotice(
                backupPath: storeURL.deletingLastPathComponent().path,
                date: now,
                reason: "\(lastError)",
                isTemporaryLibrary: true,
                kind: .unreadable
            )
            return OpenResult(container: inMemoryOrDie(openInMemory), notice: notice)
        }

        do {
            let container = try open(storeURL)
            return OpenResult(
                container: container,
                notice: StoreRecoveryNotice(backupPath: backupFolder.path, date: now, reason: "\(lastError)", isTemporaryLibrary: false, kind: .movedAside)
            )
        } catch {
            logger.error("Fresh library failed to open: \(error). Using a temporary in-memory library.")
            return OpenResult(
                container: inMemoryOrDie(openInMemory),
                notice: StoreRecoveryNotice(backupPath: backupFolder.path, date: now, reason: "\(error)", isTemporaryLibrary: true, kind: .movedAside)
            )
        }
    }

    private static func inMemoryOrDie(_ openInMemory: () throws -> ModelContainer) -> ModelContainer {
        do {
            return try openInMemory()
        } catch {
            fatalError("FATAL: even an in-memory ModelContainer failed: \(error)")
        }
    }

    // MARK: - Notice persistence

    static func saveNotice(_ notice: StoreRecoveryNotice, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(notice) {
            defaults.set(data, forKey: noticeDefaultsKey)
        }
    }

    static func loadNotice(defaults: UserDefaults = .standard) -> StoreRecoveryNotice? {
        guard let data = defaults.data(forKey: noticeDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(StoreRecoveryNotice.self, from: data)
    }

    static func clearNotice(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: noticeDefaultsKey)
    }

    // MARK: - Stamps

    private static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func timeStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }
}

/// UI-facing library health. Show a banner when `recoveryNotice` is non-nil:
///
/// ```swift
/// if let notice = LibraryHealth.shared.recoveryNotice {
///     Banner(notice.message) {
///         Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([notice.backupURL]) }
///         Button("Dismiss") { LibraryHealth.shared.dismissRecoveryNotice() }
///     }
/// }
/// ```
@MainActor
@Observable
final class LibraryHealth {
    static let shared = LibraryHealth()

    /// Persisted until dismissed, so it survives relaunches.
    private(set) var recoveryNotice: StoreRecoveryNotice?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recoveryNotice = StoreGuardian.loadNotice(defaults: defaults)
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
        StoreGuardian.clearNotice(defaults: defaults)
    }

    /// Called at launch after `StoreGuardian.openContainer`.
    func record(_ notice: StoreRecoveryNotice) {
        recoveryNotice = notice
        StoreGuardian.saveNotice(notice, defaults: defaults)
    }
}
