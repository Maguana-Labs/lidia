import Foundation
import Security

/// Keychain access for API keys and the sync token.
///
/// The iPhone's own items live under service `io.lidia.ios`, this device only.
/// Keys the Mac shares with "Sync keys via iCloud" are synchronizable items
/// under service `io.lidia.app` with the same account names
/// (`lidia.anthropic.apiKey`, …); they're readable here when both apps are
/// signed by the same team and this app lists the Mac's keychain group
/// (see LidIAiOS.entitlements).
enum Keychain {
    static let service = "io.lidia.ios"
    static let macService = "io.lidia.app"

    static func save(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (key, value) in attributes { add[key] = value }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(account: String) -> String? {
        read(service: service, account: account, synchronizable: false)
    }

    /// A key the Mac shared through iCloud Keychain, if any.
    static func loadFromMac(account: String) -> String? {
        read(service: macService, account: account, synchronizable: true)
    }

    private static func read(service: String, account: String, synchronizable: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
