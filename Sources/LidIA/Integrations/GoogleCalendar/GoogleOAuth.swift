import AppKit
import Security

actor GoogleOAuth {
    private let clientID: String
    private let clientSecret: String
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let scope = "https://www.googleapis.com/auth/calendar.readonly"

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private var tokenExpiry: Date?

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = Self.loadFromKeychain(key: "lidia.google.refreshToken")
        self.accessToken = Self.loadFromKeychain(key: "lidia.google.accessToken")
        if let expiryInterval = UserDefaults.standard.object(forKey: "lidia.google.tokenExpiry") as? TimeInterval {
            self.tokenExpiry = Date(timeIntervalSince1970: expiryInterval)
        }
    }

    init(credentials: GoogleOAuthCredentials) {
        self.init(clientID: credentials.clientID, clientSecret: credentials.clientSecret)
    }

    /// The parsed loopback callback.
    typealias Callback = OAuthLoopbackServer.Callback

    /// Reads the request target of the browser's GET to the loopback server.
    static func parseCallback(requestTarget: String, expectedState: String) -> Callback {
        OAuthLoopbackServer.parseCallback(requestTarget: requestTarget, expectedState: expectedState)
    }

    /// The Google consent URL for one sign-in attempt.
    static func authorizationURL(
        authURL: String,
        clientID: String,
        redirectURI: String,
        scope: String,
        pkce: PKCEPair,
        state: String
    ) -> URL? {
        var components = URLComponents(string: authURL)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCEPair.method),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    /// Start the OAuth2 authorization flow via loopback redirect with PKCE.
    /// Opens the system browser and starts a temporary HTTP server, bound to
    /// 127.0.0.1 only, to capture the callback.
    @MainActor
    func authorize() async throws {
        let capturedClientID = clientID
        let capturedAuthURL = authURL
        let capturedScope = scope
        let pkce = PKCEPair.generate()
        let state = PKCEPair.randomURLSafeString(byteCount: 16)

        let server = OAuthLoopbackServer()
        defer { server.stop() }
        let code: String
        do {
            try await server.start(expectedState: state)
            guard let url = Self.authorizationURL(
                authURL: capturedAuthURL,
                clientID: capturedClientID,
                redirectURI: server.redirectURI,
                scope: capturedScope,
                pkce: pkce,
                state: state
            ) else {
                throw OAuthError.noCallback
            }
            NSWorkspace.shared.open(url)
            // Timeout after 2 minutes so the listener doesn't hang forever.
            code = try await server.waitForCode(timeout: 120)
        } catch let error as OAuthLoopbackServer.ServerError {
            switch error {
            case .timeout: throw OAuthError.timeout
            case .accessDenied, .cancelled: throw OAuthError.accessDenied
            case .stateMismatch: throw OAuthError.stateMismatch
            case .couldNotListen: throw OAuthError.noCallback
            }
        }

        try await exchangeCodeForTokens(code: code, redirectURI: server.redirectURI, codeVerifier: pkce.verifier)
    }

    /// Exchange authorization code for access + refresh tokens
    private func exchangeCodeForTokens(code: String, redirectURI: String, codeVerifier: String) async throws {
        var body = [
            "code": code,
            "client_id": clientID,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        let tokens = try await postTokenRequest(body: body)
        accessToken = tokens.accessToken
        Self.saveToKeychain(key: "lidia.google.accessToken", value: tokens.accessToken)

        let expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60))
        tokenExpiry = expiry
        UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: "lidia.google.tokenExpiry")

        if let refresh = tokens.refreshToken {
            refreshToken = refresh
            Self.saveToKeychain(key: "lidia.google.refreshToken", value: refresh)
        }
    }

    /// Refresh the access token using the stored refresh token
    func refreshAccessToken() async throws {
        guard let refreshToken else { throw OAuthError.noRefreshToken }
        var body = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token",
        ]
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        let tokens = try await postTokenRequest(body: body)
        accessToken = tokens.accessToken
        Self.saveToKeychain(key: "lidia.google.accessToken", value: tokens.accessToken)

        let expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60))
        tokenExpiry = expiry
        UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: "lidia.google.tokenExpiry")
    }

    /// Get a valid access token, refreshing if expired
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
            return token
        }
        try await refreshAccessToken()
        guard let token = accessToken else { throw OAuthError.noAccessToken }
        return token
    }

    /// Sign out — clear all tokens
    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        Self.saveToKeychain(key: "lidia.google.refreshToken", value: "")
        Self.saveToKeychain(key: "lidia.google.accessToken", value: "")
        UserDefaults.standard.removeObject(forKey: "lidia.google.tokenExpiry")
    }

    var isSignedIn: Bool {
        refreshToken != nil && !(refreshToken?.isEmpty ?? true)
    }

    // MARK: - Token Request

    private struct TokenResponse: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let token_type: String

        var accessToken: String { access_token }
        var refreshToken: String? { refresh_token }
        var expiresIn: Int { expires_in }
    }

    private func postTokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Form values must escape "+", "&" and "=", which .urlQueryAllowed leaves alone.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = body
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthError.tokenExchangeFailed(errorBody)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Keychain

    /// Stable service name so tokens survive code-signing changes across rebuilds.
    private static let keychainService = "io.lidia.app"

    nonisolated static func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        if SettingsKeychain.isSnapshotRun { return } // snapshot runs never touch the Keychain
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    nonisolated static func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        if SettingsKeychain.isSnapshotRun { return nil } // snapshot runs never touch the Keychain
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        return (value?.isEmpty ?? true) ? nil : value
    }

    // MARK: - Errors

    enum OAuthError: Error, LocalizedError {
        case noCallback
        case noAuthCode
        case noRefreshToken
        case noAccessToken
        case timeout
        case accessDenied
        case stateMismatch
        case tokenExchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCallback: "OAuth callback not received."
            case .noAuthCode: "No authorization code in callback."
            case .noRefreshToken: "No refresh token available. Please sign in again."
            case .noAccessToken: "No access token available."
            case .timeout: "Sign-in timed out. Please try again."
            case .accessDenied: "Sign-in was cancelled."
            case .stateMismatch: "Sign-in didn't match this request. Please try again."
            case .tokenExchangeFailed(let msg): "Token exchange failed: \(msg)"
            }
        }
    }
}
