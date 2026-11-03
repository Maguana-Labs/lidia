import CloudKit
import CoreData
import Foundation
import Observation
import os

/// The iCloud account as CloudKit sees it.
public enum CloudSyncAccount: Equatable, Sendable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }

    /// Plain words for Settings, or nil when the account is fine.
    public var problem: String? {
        switch self {
        case .available, .unknown: nil
        case .noAccount: "You're not signed in to iCloud. Sign in in \(CloudSyncText.settingsApp) to sync."
        case .restricted: "iCloud is restricted on this device (Screen Time or a device profile), so LidIA can't sync."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable. Check \(CloudSyncText.settingsApp) › Apple Account; LidIA will sync when it's back."
        case .couldNotDetermine: "LidIA couldn't check your iCloud account. It will try again."
        }
    }
}

/// Watches SwiftData's CloudKit mirroring (setup, import, export) and the iCloud
/// account, for the Sync settings on the Mac and the iPhone.
///
/// SwiftData syncs with Core Data's `NSPersistentCloudKitContainer` machinery, which
/// posts `eventChangedNotification` for every setup, import and export.
@MainActor
@Observable
public final class CloudSyncMonitor {
    public enum Activity: Equatable, Sendable {
        case idle
        case settingUp
        case importing
        case exporting
    }

    private static let logger = Logger(subsystem: "io.lidia.kit", category: "CloudSync")
    public static let lastSyncKey = "io.lidia.cloudSync.lastSuccess"

    /// True when the library was opened with CloudKit this launch.
    public let isActive: Bool
    public let containerID: String
    public private(set) var account: CloudSyncAccount = .unknown
    public private(set) var activity: Activity = .idle
    /// Last import or export that finished without an error (kept across launches).
    public private(set) var lastSyncDate: Date?
    /// The last failure, in plain words. Cleared by the next success.
    public private(set) var lastError: String?
    /// Why sync didn't start this launch although it was on (the library opened without it).
    public let startupProblem: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    public init(
        isActive: Bool,
        startupProblem: String? = nil,
        containerID: String = LidIASchema.cloudKitContainerID,
        defaults: UserDefaults = .standard
    ) {
        self.isActive = isActive
        self.startupProblem = startupProblem
        self.containerID = containerID
        self.defaults = defaults
        self.lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Starts listening. Call once, after the library opened. Does nothing when sync is off,
    /// so a build without the iCloud entitlement never touches CloudKit (that would crash).
    public func start() {
        guard isActive, !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let update = EventUpdate(event)
            MainActor.assumeIsolated { self?.apply(update) }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshAccount() }
            }
        })
        Task { await refreshAccount() }
    }

    public func refreshAccount() async {
        guard isActive else { return }
        do {
            let status = try await CKContainer(identifier: containerID).accountStatus()
            account = CloudSyncAccount(status)
        } catch {
            account = .couldNotDetermine
            Self.logger.error("accountStatus failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The Sendable parts of an event.
    struct EventUpdate: Sendable {
        let type: NSPersistentCloudKitContainer.EventType
        let finished: Bool
        let succeeded: Bool
        let endDate: Date?
        let errorText: String?

        init(_ event: NSPersistentCloudKitContainer.Event) {
            type = event.type
            finished = event.endDate != nil
            succeeded = event.succeeded
            endDate = event.endDate
            errorText = event.error.flatMap(CloudSyncText.describe)
        }

        init(type: NSPersistentCloudKitContainer.EventType, finished: Bool, succeeded: Bool, endDate: Date?, errorText: String?) {
            self.type = type
            self.finished = finished
            self.succeeded = succeeded
            self.endDate = endDate
            self.errorText = errorText
        }
    }

    func apply(_ update: EventUpdate) {
        guard update.finished else {
            switch update.type {
            case .setup: activity = .settingUp
            case .import: activity = .importing
            case .export: activity = .exporting
            @unknown default: break
            }
            return
        }
        activity = .idle
        if update.succeeded {
            lastError = nil
            if update.type != .setup, let date = update.endDate {
                lastSyncDate = date
                defaults.set(date, forKey: Self.lastSyncKey)
            }
        } else if let text = update.errorText {
            lastError = text
            Self.logger.error("CloudKit \(String(describing: update.type.rawValue)) failed: \(text, privacy: .public)")
        }
    }
}

/// Words for sync problems.
public enum CloudSyncText {
    #if os(macOS)
    public static let settingsApp = "System Settings"
    #else
    public static let settingsApp = "Settings"
    #endif

    /// What a sync error means for the person, or nil for errors that aren't worth
    /// showing (CloudKit retries them on its own).
    public static func describe(_ error: Error) -> String? {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain {
            return describe(CKError.Code(rawValue: nsError.code) ?? .internalError, error: nsError)
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 134_400: // NSCloudKitMirroringDelegate: no iCloud account
                return "You're not signed in to iCloud. Sign in in \(settingsApp) to sync."
            case 134_419: // the system postponed the work; it runs later on its own
                return nil
            case 134_405, 134_407: // the store was closed or the request cancelled
                return nil
            default:
                break
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                return describe(underlying)
            }
        }
        return "iCloud sync hit a problem: \(nsError.localizedDescription)"
    }

    private static func describe(_ code: CKError.Code, error: NSError) -> String? {
        switch code {
        case .notAuthenticated:
            return "You're not signed in to iCloud. Sign in in \(settingsApp) to sync."
        case .quotaExceeded:
            return "Your iCloud storage is full, so new changes aren't uploading. Free up space or upgrade iCloud storage."
        case .networkUnavailable, .networkFailure:
            return "No internet connection. LidIA will sync when you're back online."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is busy right now. LidIA will try again shortly."
        case .accountTemporarilyUnavailable:
            return "Your iCloud account is temporarily unavailable. Check \(settingsApp) › Apple Account."
        case .managedAccountRestricted, .permissionFailure:
            return "This iCloud account doesn't allow LidIA to sync."
        case .incompatibleVersion:
            return "Another device has a newer LidIA. Update LidIA on this device to keep syncing."
        case .userDeletedZone:
            return "LidIA's iCloud data was deleted from iCloud settings. Turn iCloud sync off and on again to upload this library."
        case .partialFailure:
            let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError]
            if let first = partial?.values.first(where: { $0.code != CKError.Code.batchRequestFailed.rawValue }) {
                return describe(first)
            }
            return "Some changes didn't upload. LidIA will try again."
        case .limitExceeded:
            return nil // the mirroring delegate splits the batch and retries
        case .operationCancelled:
            return nil
        default:
            return "iCloud sync hit a problem: \(error.localizedDescription)"
        }
    }

    /// Fixed wording about where the data goes.
    public static let encryptionNote = "Meetings sync through your own iCloud account (the private database; LidIA has no server). Apple encrypts it in transit and on its servers; it's end-to-end encrypted only when Advanced Data Protection is turned on for your Apple Account. Audio recordings never sync."
}
