import Foundation
import Sparkle
import os

/// Checks that the app ships a real Sparkle EdDSA public key.
///
/// Without one, Sparkle has nothing to verify a download against, so the
/// updater stays off. See docs/release-signing.md for generating the key.
enum SparkleSigning {
    /// What `Info.plist` holds until a real key is generated. Never ship this.
    static let placeholderKey = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    /// The configured public key, or `nil` when it is missing, still the
    /// placeholder, or not a 32-byte base64 Ed25519 key.
    static func publicKey(in info: [String: Any]?) -> String? {
        guard let raw = info?["SUPublicEDKey"] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != placeholderKey,
              let data = Data(base64Encoded: key), data.count == 32 else { return nil }
        return key
    }

    /// Whether Sparkle will check the update's signature before installing.
    static func isVerificationConfigured(in info: [String: Any]?) -> Bool {
        publicKey(in: info) != nil
    }
}

@MainActor
@Observable
final class UpdateController {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "UpdateController")

    private let updaterController: SPUStandardUpdaterController

    /// False until a real EdDSA public key is in Info.plist.
    let isSigningConfigured: Bool
    var canCheckForUpdates: Bool { isSigningConfigured }
    var lastUpdateCheckDate: Date?

    /// Shown instead of "Check for Updates" when updates are off.
    var unavailableReason: String? {
        isSigningConfigured ? nil : "Updates are off in this build because it has no update signing key."
    }

    init(bundleInfo: [String: Any]? = Bundle.main.infoDictionary) {
        isSigningConfigured = SparkleSigning.isVerificationConfigured(in: bundleInfo)
        // Only start Sparkle when downloads can be verified against our key.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isSigningConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if !isSigningConfigured {
            Self.logger.notice("Sparkle updater not started: SUPublicEDKey is missing or a placeholder")
        }
    }

    func checkForUpdates() {
        guard isSigningConfigured else {
            Self.logger.notice("Update check skipped: no update signing key")
            return
        }
        updaterController.checkForUpdates(nil)
        lastUpdateCheckDate = .now
    }

    var automaticallyChecksForUpdates: Bool {
        get { isSigningConfigured && updaterController.updater.automaticallyChecksForUpdates }
        set {
            guard isSigningConfigured else { return }
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }
}
