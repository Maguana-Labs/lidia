import Foundation
import Security

/// Shared Keychain helpers used by all domain settings classes.
///
/// - Writes update in place (`SecItemUpdate`, adding only when missing)
///   instead of delete-and-re-add.
/// - Items go in the data-protection keychain, readable only while the Mac
///   is unlocked and never synced (`WhenUnlockedThisDeviceOnly`), unless the
///   caller opts in to iCloud Keychain sync. Builds without the entitlement
///   the data-protection keychain needs (unsigned/ad-hoc) fall back to the
///   login keychain transparently.
/// - Items written by earlier builds to the login keychain are still read and
///   are moved to the data-protection keychain on read when possible.
/// - `save` returns the `OSStatus` so callers can show "Couldn't save key".
enum SettingsKeychain {
    /// Stable service name so Keychain items survive code-signing changes across rebuilds.
    private static let keychainService = "io.lidia.app"

    /// DEBUG snapshot runs (Settings, main window, menu bar) never touch the
    /// Keychain: keys typed for a screenshot stay in memory, and a renamed
    /// snapshot copy never stops on a Keychain prompt.
    static var isSnapshotRun: Bool {
        #if DEBUG
        return SnapshotRun.isActive
        #else
        return false
        #endif
    }

    enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Couldn't save to the Keychain: \(message)"
            }
        }
    }

    // MARK: - Save

    /// Saves (or, for an empty value, deletes) a secret. Returns
    /// `errSecSuccess` on success.
    @discardableResult
    static func save(key: String, value: String, synchronizable: Bool = false) -> OSStatus {
        if isSnapshotRun { return errSecSuccess }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(key: key)
        }
        let data = Data(trimmed.utf8)

        let status = upsert(key: key, data: data, synchronizable: synchronizable, dataProtection: true)
        if status == errSecMissingEntitlement || status == errSecNotAvailable {
            // No keychain-access entitlement (unsigned/dev build): use the
            // login keychain. Sync needs the data-protection keychain.
            return upsert(key: key, data: data, synchronizable: false, dataProtection: false)
        }
        if status == errSecSuccess {
            // Remove a stale login-keychain copy from an earlier build.
            SecItemDelete(baseQuery(key: key, dataProtection: false) as CFDictionary)
        }
        return status
    }

    /// Throwing variant of `save`.
    static func saveThrowing(key: String, value: String, synchronizable: Bool = false) throws {
        let status = save(key: key, value: value, synchronizable: synchronizable)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func upsert(key: String, data: Data, synchronizable: Bool, dataProtection: Bool) -> OSStatus {
        var match = baseQuery(key: key, dataProtection: dataProtection)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if dataProtection {
            // Sync and accessibility classes only apply to the data-protection keychain.
            match[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
            attributes[kSecAttrAccessible as String] = synchronizable
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        if dataProtection {
            // Not present with this sync setting: drop any copy with the
            // other setting, then add.
            var any = baseQuery(key: key, dataProtection: true)
            any[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(any as CFDictionary)
        }

        var add = match
        for (name, value) in attributes { add[name] = value }
        return SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - Load

    static func load(key: String) -> String? {
        if isSnapshotRun { return nil }
        if let value = read(key: key, dataProtection: true) {
            return value
        }
        guard let legacy = read(key: key, dataProtection: false) else { return nil }
        // Move a login-keychain item from an earlier build. The legacy copy
        // is deleted only if the data-protection write succeeds; builds
        // without the entitlement keep reading the login keychain.
        if upsert(key: key, data: Data(legacy.utf8), synchronizable: false, dataProtection: true) == errSecSuccess {
            SecItemDelete(baseQuery(key: key, dataProtection: false) as CFDictionary)
        }
        return legacy
    }

    private static func read(key: String, dataProtection: Bool) -> String? {
        var query = baseQuery(key: key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if dataProtection {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Delete

    @discardableResult
    static func delete(key: String) -> OSStatus {
        if isSnapshotRun { return errSecSuccess }
        var modern = baseQuery(key: key, dataProtection: true)
        modern[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let modernStatus = SecItemDelete(modern as CFDictionary)
        let legacyStatus = SecItemDelete(baseQuery(key: key, dataProtection: false) as CFDictionary)
        if modernStatus == errSecSuccess || legacyStatus == errSecSuccess { return errSecSuccess }
        if modernStatus == errSecItemNotFound || legacyStatus == errSecItemNotFound { return errSecSuccess }
        return modernStatus
    }

    // MARK: - Query

    private static func baseQuery(key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
