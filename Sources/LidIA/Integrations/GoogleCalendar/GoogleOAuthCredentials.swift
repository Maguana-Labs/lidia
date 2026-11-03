import CryptoKit
import Foundation
import Security

/// The OAuth client LidIA signs in to Google with.
///
/// A build can ship its own Desktop OAuth client in Info.plist
/// (`LidIAGoogleClientID` / `LidIAGoogleClientSecret`). Google treats desktop
/// clients as public clients, so the "secret" is not confidential; PKCE is what
/// protects the code exchange. A client ID the user typed in Settings always
/// wins over the bundled one, so people who set up their own client keep using it.
struct GoogleOAuthCredentials: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// From Settings → Calendar → Advanced.
        case custom
        /// Shipped in the app's Info.plist.
        case bundled
    }

    static let bundleClientIDKey = "LidIAGoogleClientID"
    static let bundleClientSecretKey = "LidIAGoogleClientSecret"

    let clientID: String
    /// May be empty. Sent only when present.
    let clientSecret: String
    let origin: Origin

    /// Picks the client to use. Custom settings win when they have a client ID;
    /// otherwise the bundled client, if the build has one; otherwise nil.
    /// A custom ID is never paired with the bundled secret, or the other way round.
    static func resolve(
        customClientID: String,
        customClientSecret: String,
        bundleInfo: [String: Any]?
    ) -> GoogleOAuthCredentials? {
        let customID = customClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customID.isEmpty {
            return GoogleOAuthCredentials(
                clientID: customID,
                clientSecret: customClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                origin: .custom
            )
        }
        let bundledID = bundleValue(bundleClientIDKey, in: bundleInfo)
        guard !bundledID.isEmpty else { return nil }
        return GoogleOAuthCredentials(
            clientID: bundledID,
            clientSecret: bundleValue(bundleClientSecretKey, in: bundleInfo),
            origin: .bundled
        )
    }

    /// Whether this build ships its own Google client.
    static func hasBundledClient(bundleInfo: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        !bundleValue(bundleClientIDKey, in: bundleInfo).isEmpty
    }

    @MainActor
    static func resolve(
        settings: AppSettings,
        bundleInfo: [String: Any]? = Bundle.main.infoDictionary
    ) -> GoogleOAuthCredentials? {
        resolve(
            customClientID: settings.googleClientID,
            customClientSecret: settings.googleClientSecret,
            bundleInfo: bundleInfo
        )
    }

    private static func bundleValue(_ key: String, in info: [String: Any]?) -> String {
        let raw = (info?[key] as? String) ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build variable such as "$(LIDIA_GOOGLE_CLIENT_ID)" is not a client ID.
        if value.hasPrefix("$(") { return "" }
        return value
    }
}

/// PKCE (RFC 7636) verifier and S256 challenge for one sign-in attempt.
struct PKCEPair: Equatable, Sendable {
    static let method = "S256"

    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// A fresh pair: 32 random bytes, base64url-encoded into a 43-character verifier.
    static func generate() -> PKCEPair {
        PKCEPair(verifier: randomURLSafeString(byteCount: 32))
    }

    /// BASE64URL(SHA256(ASCII(verifier))), no padding.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Random base64url string, used for the verifier and the OAuth `state`.
    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes does not fail in practice; fall back to the system RNG.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Finds Google accounts that already feed Apple Calendar through
/// System Settings → Internet Accounts. Pure, so it can be tested without EventKit.
enum GoogleAccountDetection {
    /// The bits of an `EKSource` the detection needs.
    struct Source: Equatable, Sendable {
        var title: String
        var isCalDAV: Bool
        var calendarTitles: [String]
    }

    /// A CalDAV source whose title or calendar titles mention Google or Gmail.
    static func isGoogle(_ source: Source) -> Bool {
        guard source.isCalDAV else { return false }
        return ([source.title] + source.calendarTitles).contains(where: mentionsGoogle)
    }

    /// How many event calendars come from Google accounts.
    static func googleCalendarCount(in sources: [Source]) -> Int {
        sources.filter(isGoogle).reduce(0) { $0 + $1.calendarTitles.count }
    }

    static func mentionsGoogle(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("google") || lowered.contains("gmail.com") || lowered.contains("googlemail.com")
    }
}
