import Foundation
import Testing
@testable import LidIA

// MARK: - PKCE

@Test func pkceChallengeMatchesRFC7636Example() {
    // RFC 7636, Appendix B.
    let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(PKCEPair.method == "S256")
}

@Test func pkceGeneratedVerifierIsValidAndUnique() {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let first = PKCEPair.generate()
    let second = PKCEPair.generate()

    // RFC 7636: 43-128 unreserved characters.
    #expect(first.verifier.count == 43)
    #expect(first.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    #expect(first.challenge.count == 43)
    #expect(!first.challenge.contains("="))
    #expect(first.challenge == PKCEPair.challenge(for: first.verifier))
    #expect(first.verifier != second.verifier)
}

@Test func authorizationURLCarriesPKCEAndState() throws {
    let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let url = try #require(GoogleOAuth.authorizationURL(
        authURL: "https://accounts.google.com/o/oauth2/v2/auth",
        clientID: "client-1",
        redirectURI: "http://127.0.0.1:5555",
        scope: "https://www.googleapis.com/auth/calendar.readonly",
        pkce: pkce,
        state: "xyz"
    ))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    #expect(value("code_challenge") == pkce.challenge)
    #expect(value("code_challenge_method") == "S256")
    #expect(value("state") == "xyz")
    #expect(value("client_id") == "client-1")
    #expect(value("redirect_uri") == "http://127.0.0.1:5555")
}

@Test func loopbackCallbackChecksState() {
    #expect(GoogleOAuth.parseCallback(requestTarget: "/?code=4/abc&state=s1", expectedState: "s1") == .code("4/abc"))
    #expect(GoogleOAuth.parseCallback(requestTarget: "/?code=4/abc&state=other", expectedState: "s1") == .stateMismatch)
    #expect(GoogleOAuth.parseCallback(requestTarget: "/?code=4/abc", expectedState: "s1") == .stateMismatch)
    #expect(GoogleOAuth.parseCallback(requestTarget: "/?error=access_denied&state=s1", expectedState: "s1") == .denied("access_denied"))
    #expect(GoogleOAuth.parseCallback(requestTarget: "/favicon.ico", expectedState: "s1") == .ignored)
}

// MARK: - Client precedence

private var bundled: [String: Any] {
    [
        GoogleOAuthCredentials.bundleClientIDKey: "bundled-id.apps.googleusercontent.com",
        GoogleOAuthCredentials.bundleClientSecretKey: "bundled-secret",
    ]
}

@Test func bundledClientIsUsedWhenSettingsAreEmpty() {
    let credentials = GoogleOAuthCredentials.resolve(customClientID: "", customClientSecret: "", bundleInfo: bundled)
    #expect(credentials == GoogleOAuthCredentials(
        clientID: "bundled-id.apps.googleusercontent.com",
        clientSecret: "bundled-secret",
        origin: .bundled
    ))
}

@Test func customClientOverridesBundled() {
    let credentials = GoogleOAuthCredentials.resolve(
        customClientID: "  mine.apps.googleusercontent.com ",
        customClientSecret: "my-secret",
        bundleInfo: bundled
    )
    #expect(credentials?.clientID == "mine.apps.googleusercontent.com")
    #expect(credentials?.clientSecret == "my-secret")
    #expect(credentials?.origin == .custom)
}

@Test func customClientIDNeverBorrowsTheBundledSecret() {
    let credentials = GoogleOAuthCredentials.resolve(
        customClientID: "mine.apps.googleusercontent.com",
        customClientSecret: "",
        bundleInfo: bundled
    )
    #expect(credentials?.origin == .custom)
    #expect(credentials?.clientSecret == "")
}

@Test func customSecretAloneDoesNotOverrideBundled() {
    let credentials = GoogleOAuthCredentials.resolve(customClientID: "", customClientSecret: "stray", bundleInfo: bundled)
    #expect(credentials?.origin == .bundled)
    #expect(credentials?.clientSecret == "bundled-secret")
}

@Test func noClientWhenNothingIsConfigured() {
    #expect(GoogleOAuthCredentials.resolve(customClientID: "", customClientSecret: "", bundleInfo: nil) == nil)
    let emptyPlist: [String: Any] = [
        GoogleOAuthCredentials.bundleClientIDKey: "",
        GoogleOAuthCredentials.bundleClientSecretKey: "",
    ]
    #expect(GoogleOAuthCredentials.resolve(customClientID: " ", customClientSecret: "", bundleInfo: emptyPlist) == nil)
    let unexpanded: [String: Any] = [GoogleOAuthCredentials.bundleClientIDKey: "$(LIDIA_GOOGLE_CLIENT_ID)"]
    #expect(!GoogleOAuthCredentials.hasBundledClient(bundleInfo: unexpanded))
    #expect(GoogleOAuthCredentials.hasBundledClient(bundleInfo: bundled))
}

@Test func shippedInfoPlistHasEmptyGoogleClientKeys() throws {
    // The repo must not ship a real client; the keys exist so builds can fill them.
    let plistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/LidIA/Resources/Info.plist")
    let data = try Data(contentsOf: plistURL)
    let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(info[GoogleOAuthCredentials.bundleClientIDKey] as? String == "")
    #expect(info[GoogleOAuthCredentials.bundleClientSecretKey] as? String == "")
}

// MARK: - Google accounts in Internet Accounts

@Test func detectsGoogleCalDAVSourceByTitle() {
    let source = GoogleAccountDetection.Source(title: "Google", isCalDAV: true, calendarTitles: ["Work", "Holidays"])
    #expect(GoogleAccountDetection.isGoogle(source))
    #expect(GoogleAccountDetection.googleCalendarCount(in: [source]) == 2)
}

@Test func detectsGoogleCalDAVSourceByGmailCalendar() {
    let source = GoogleAccountDetection.Source(
        title: "Personal",
        isCalDAV: true,
        calendarTitles: ["alex@gmail.com", "Birthdays"]
    )
    #expect(GoogleAccountDetection.isGoogle(source))
    #expect(GoogleAccountDetection.googleCalendarCount(in: [source]) == 2)
}

@Test func ignoresICloudExchangeAndLocalSources() {
    let sources = [
        GoogleAccountDetection.Source(title: "iCloud", isCalDAV: true, calendarTitles: ["Home", "Work"]),
        // A non-CalDAV source never counts, even if a calendar name says Google.
        GoogleAccountDetection.Source(title: "Exchange", isCalDAV: false, calendarTitles: ["Google sync"]),
        GoogleAccountDetection.Source(title: "On My Mac", isCalDAV: false, calendarTitles: ["Calendar"]),
    ]
    #expect(GoogleAccountDetection.googleCalendarCount(in: sources) == 0)
}

@Test func countsCalendarsAcrossSeveralGoogleAccounts() {
    let sources = [
        GoogleAccountDetection.Source(title: "Google", isCalDAV: true, calendarTitles: ["a@gmail.com"]),
        GoogleAccountDetection.Source(title: "Work Google", isCalDAV: true, calendarTitles: ["j@acme.com", "Team", "Rooms"]),
        GoogleAccountDetection.Source(title: "iCloud", isCalDAV: true, calendarTitles: ["Home"]),
    ]
    #expect(GoogleAccountDetection.googleCalendarCount(in: sources) == 4)
}

@MainActor
@Test func macOSConnectedCopyUsesSingularAndPlural() {
    #expect(CalendarsPane.macOSConnectedText(calendarCount: 1) == "Google Calendar connected through macOS (1 calendar)")
    #expect(CalendarsPane.macOSConnectedText(calendarCount: 3) == "Google Calendar connected through macOS (3 calendars)")
}
