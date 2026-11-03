import AppKit
import Foundation
import Observation
import Security
import SwiftData
import os

/// Whether the library syncs through iCloud this launch, and why not when it doesn't.
///
/// Decided once, before the library opens: SwiftData can't switch CloudKit on or off
/// for an open container, so a change takes effect at the next launch.
enum LibrarySyncMode: Equatable, Sendable {
    case iCloud
    case off(OffReason)

    enum OffReason: Equatable, Sendable {
        /// The person turned it off (or hasn't turned it on).
        case turnedOff
        /// An existing library waits for the one-time "Turn on iCloud sync?" answer.
        case awaitingConsent
        /// Local-only mode keeps meeting content on this Mac.
        case localOnly
        /// This build isn't signed with the iCloud entitlement (and provisioning profile).
        case notAvailableInThisBuild
        /// Demo mode or a snapshot run on a throwaway library.
        case isolatedLibrary
    }

    var isICloud: Bool { self == .iCloud }

    var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        isICloud ? .private(LidIASchema.cloudKitContainerID) : .none
    }

    /// Why sync is off, in plain words.
    var explanation: String? {
        switch self {
        case .iCloud: nil
        case .off(.turnedOff): "iCloud sync is off. Meetings stay on this Mac."
        case .off(.awaitingConsent): "iCloud sync is off until you turn it on."
        case .off(.localOnly): "Local-only mode is on, so iCloud sync is off: nothing about your meetings leaves this Mac."
        case .off(.notAvailableInThisBuild): "This copy of LidIA isn't signed for iCloud, so it can't sync. Builds from run.sh with a provisioning profile, and releases, can."
        case .off(.isolatedLibrary): "Demo and snapshot runs use a temporary library that never syncs."
        }
    }

    /// Resolves the mode from the stored choice and the environment. Pure, for tests.
    static func resolve(
        isolatedLibrary: Bool,
        entitled: Bool,
        localOnly: Bool,
        preference: CloudSyncPreference.Choice
    ) -> LibrarySyncMode {
        if isolatedLibrary { return .off(.isolatedLibrary) }
        if !entitled { return .off(.notAvailableInThisBuild) }
        if localOnly { return .off(.localOnly) }
        switch preference {
        case .on: return .iCloud
        case .off: return .off(.turnedOff)
        case .askFirst: return .off(.awaitingConsent)
        }
    }
}

/// The stored "Sync with iCloud" choice.
///
/// On for new installs. An existing library (the store already exists the first time
/// this version runs) starts off, and Settings and the main window ask once.
enum CloudSyncPreference {
    enum Choice: String, Equatable, Sendable {
        case on, off, askFirst
    }

    static let choiceKey = "iCloudSync.choice"

    static func choice(defaults: UserDefaults = .standard) -> Choice? {
        defaults.string(forKey: choiceKey).flatMap(Choice.init(rawValue:))
    }

    static func set(_ choice: Choice, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: choiceKey)
    }

    /// The choice for this launch, recording the default the first time.
    static func resolveAtLaunch(libraryExists: Bool, defaults: UserDefaults = .standard) -> Choice {
        if let stored = choice(defaults: defaults) { return stored }
        let initial: Choice = libraryExists ? .askFirst : .on
        set(initial, defaults: defaults)
        return initial
    }
}

/// Reads this process's own entitlements. A build without the iCloud entitlement must
/// never touch CloudKit: `CKContainer` raises an exception and SwiftData can't mirror.
enum CloudKitEntitlement {
    static let isPresent: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
        let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
        return (services ?? []).contains("CloudKit") && (containers ?? []).contains(LidIASchema.cloudKitContainerID)
    }()
}

/// The sync state the app and Settings share. Set once at launch by `LidIAApp`.
@MainActor
@Observable
final class CloudSyncRuntime {
    static let shared = CloudSyncRuntime()

    private static let logger = Logger(subsystem: "io.lidia.app", category: "CloudSync")

    /// How the library was opened this launch.
    private(set) var mode: LibrarySyncMode = .off(.turnedOff)
    private(set) var monitor = CloudSyncMonitor(isActive: false)
    /// The stored choice (may differ from `mode` until the next launch).
    var choice: CloudSyncPreference.Choice {
        didSet { CloudSyncPreference.set(choice) }
    }
    /// The iCloud sync failed to start and the library opened without it.
    private(set) var startupError: String?

    init(defaults: UserDefaults = .standard) {
        choice = CloudSyncPreference.choice(defaults: defaults) ?? .on
    }

    func configure(mode: LibrarySyncMode, startupError: String? = nil) {
        self.mode = mode
        self.startupError = startupError
        monitor = CloudSyncMonitor(isActive: mode.isICloud)
        choice = CloudSyncPreference.choice() ?? choice
    }

    func start() {
        monitor.start()
    }

    /// Whether the "Turn on iCloud sync?" question should show.
    var shouldAsk: Bool {
        choice == .askFirst && mode == .off(.awaitingConsent)
    }

    /// The stored choice differs from how the library is open: a restart applies it.
    func needsRestart(localOnly: Bool) -> Bool {
        guard mode != .off(.notAvailableInThisBuild), mode != .off(.isolatedLibrary) else { return false }
        let wanted = LibrarySyncMode.resolve(isolatedLibrary: false, entitled: true, localOnly: localOnly, preference: choice)
        return wanted.isICloud != mode.isICloud
    }

    /// Quits and reopens LidIA so a sync change takes effect. Refuses while recording.
    /// Returns false (and does nothing) when a recording is in progress.
    @discardableResult
    func relaunch() -> Bool {
        if AppDelegate.session?.isRecording == true { return false }
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then open the app again.
        task.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", bundlePath]
        do {
            try task.run()
        } catch {
            Self.logger.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}

/// Backups that are never pruned, taken right before the library changes for good.
enum LibraryMilestoneBackups {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "CloudSync")

    /// Before the first open with schema 4 (the CloudKit-compatible schema).
    static let schema4Key = "libraryBackup.beforeSchema4"
    /// Before the first launch that syncs with iCloud.
    static let firstICloudKey = "libraryBackup.beforeFirstICloudSync"

    /// Takes the backups `mode` needs. Returns the mode to open with: when the backup
    /// before the first iCloud sync fails, sync stays off this launch (with a reason).
    static func prepare(
        mode: LibrarySyncMode,
        storeURL: URL,
        backupsRoot: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> (mode: LibrarySyncMode, problem: String?) {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            // A new library has nothing to back up.
            defaults.set(true, forKey: schema4Key)
            if mode.isICloud { defaults.set(true, forKey: firstICloudKey) }
            return (mode, nil)
        }
        if !defaults.bool(forKey: schema4Key) {
            do {
                let folder = try StoreGuardian.makeMilestoneBackup(
                    label: "schema-4", storeURL: storeURL, backupsRoot: backupsRoot, fileManager: fileManager
                )
                defaults.set(true, forKey: schema4Key)
                logger.info("Backed up the library before the schema upgrade: \(folder?.path ?? "-", privacy: .public)")
            } catch {
                // The daily backup still runs; the migration itself is lightweight and tested.
                logger.error("Backup before the schema upgrade failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if mode.isICloud && !defaults.bool(forKey: firstICloudKey) {
            do {
                let folder = try StoreGuardian.makeMilestoneBackup(
                    label: "icloud-sync", storeURL: storeURL, backupsRoot: backupsRoot, fileManager: fileManager
                )
                defaults.set(true, forKey: firstICloudKey)
                logger.info("Backed up the library before the first iCloud sync: \(folder?.path ?? "-", privacy: .public)")
            } catch {
                logger.error("Backup before the first iCloud sync failed: \(error.localizedDescription, privacy: .public)")
                return (.off(.turnedOff), "LidIA couldn't back up your library before its first iCloud sync (\(error.localizedDescription)), so sync stays off this time. It will try again next launch.")
            }
        }
        return (mode, nil)
    }
}
