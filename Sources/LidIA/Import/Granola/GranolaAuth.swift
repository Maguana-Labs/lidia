import Foundation
import os

// MARK: - HTTP seam

/// The one network call the Granola client and sign-in make, so tests can stub it.
protocol GranolaHTTPLoading: Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport. Doesn't follow redirects when `followRedirects` is false,
/// which the authorize preflight needs to read the `Location` header.
struct URLSessionGranolaHTTP: GranolaHTTPLoading {
    var followRedirects = true

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = followRedirects
            ? try await URLSession.shared.data(for: request)
            : try await URLSession.shared.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirects()
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}

// MARK: - Metadata

/// OAuth endpoints for Granola's MCP server (RFC 9728 + RFC 8414), discovered at runtime.
struct GranolaAuthMetadata: Equatable, Sendable {
    var resource: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var deviceAuthorizationEndpoint: URL?

    static let mcpEndpoint = URL(string: "https://mcp.granola.ai/mcp")!
    static let protectedResourceMetadataURL = URL(string: "https://mcp.granola.ai/.well-known/oauth-protected-resource")!

    /// Values verified on 2026-11-03, used when discovery fails.
    static let fallback = GranolaAuthMetadata(
        resource: "https://mcp.granola.ai/mcp",
        authorizationEndpoint: URL(string: "https://mcp-auth.granola.ai/oauth2/authorize")!,
        tokenEndpoint: URL(string: "https://mcp-auth.granola.ai/oauth2/token")!,
        registrationEndpoint: URL(string: "https://mcp-auth.granola.ai/oauth2/register")!,
        deviceAuthorizationEndpoint: URL(string: "https://mcp-auth.granola.ai/oauth2/device_authorization")!
    )

    /// Scope LidIA asks for: the MCP scope the resource advertises, plus a refresh token.
    static let scope = "mcp offline_access"

    /// Builds metadata from the two discovery documents, keeping fallback values for anything missing.
    static func from(protectedResource: [String: Any]?, authorizationServer: [String: Any]?) -> GranolaAuthMetadata {
        var result = fallback
        if let resource = protectedResource?["resource"] as? String, !resource.isEmpty {
            result.resource = resource
        }
        func url(_ key: String) -> URL? {
            (authorizationServer?[key] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        }
        if let value = url("authorization_endpoint") { result.authorizationEndpoint = value }
        if let value = url("token_endpoint") { result.tokenEndpoint = value }
        if let value = url("registration_endpoint") { result.registrationEndpoint = value }
        if let value = url("device_authorization_endpoint") { result.deviceAuthorizationEndpoint = value }
        return result
    }
}

// MARK: - Stored credentials

/// What LidIA keeps in the Keychain for Granola: the dynamically registered
/// client and the tokens. Stored as one JSON item.
struct GranolaCredentials: Codable, Equatable, Sendable {
    var clientID: String
    /// The loopback redirect URI the client was registered with, if any.
    var redirectURI: String?
    var refreshToken: String?
    var accessToken: String?
    var accessTokenExpiry: Date?

    /// The port in `redirectURI`, so the next sign-in can listen on the same one.
    var redirectPort: UInt16? {
        redirectURI.flatMap { URLComponents(string: $0)?.port }.flatMap { UInt16(exactly: $0) }
    }
}

protocol GranolaCredentialStore: Sendable {
    func load() -> GranolaCredentials?
    func save(_ credentials: GranolaCredentials?)
}

struct KeychainGranolaCredentialStore: GranolaCredentialStore {
    static let key = "lidia.granola.credentials"

    func load() -> GranolaCredentials? {
        guard let json = SettingsKeychain.load(key: Self.key), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GranolaCredentials.self, from: data)
    }

    func save(_ credentials: GranolaCredentials?) {
        guard let credentials,
              let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            SettingsKeychain.delete(key: Self.key)
            return
        }
        SettingsKeychain.save(key: Self.key, value: json)
    }
}

/// In-memory store for tests.
final class InMemoryGranolaCredentialStore: GranolaCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GranolaCredentials?
    init(_ value: GranolaCredentials? = nil) { self.value = value }
    func load() -> GranolaCredentials? { lock.withLock { value } }
    func save(_ credentials: GranolaCredentials?) { lock.withLock { value = credentials } }
}

// MARK: - Errors

enum GranolaAuthError: Error, LocalizedError, Equatable {
    case notSignedIn
    case sessionExpired
    case registrationFailed(String)
    case tokenRequestFailed(String)
    case deviceCodeExpired
    case accessDenied
    case redirectRejected

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "You're not signed in to Granola."
        case .sessionExpired:
            "Your Granola sign-in has expired. Sign in again."
        case .registrationFailed(let detail):
            "Granola didn't accept LidIA's sign-in request (\(detail))."
        case .tokenRequestFailed(let detail):
            "Granola didn't finish the sign-in (\(detail))."
        case .deviceCodeExpired:
            "The sign-in code expired before it was confirmed. Try again."
        case .accessDenied:
            "Sign-in was cancelled in the browser."
        case .redirectRejected:
            "Granola rejected LidIA's sign-in address. Try again, or sign in with a code."
        }
    }
}

/// Shown to the user when sign-in falls back to the device flow.
struct GranolaDeviceCode: Equatable, Sendable {
    var userCode: String
    var verificationURL: URL
}

/// Supplies bearer tokens to the MCP client.
protocol GranolaTokenProviding: Sendable {
    func accessToken() async throws -> String
    /// Called after a 401. Refreshes unless another caller already replaced `failedToken`.
    func refreshedAccessToken(after failedToken: String) async throws -> String
}

// MARK: - Sign-in

/// Signs in to Granola's MCP server and keeps its tokens fresh.
///
/// Dynamic client registration (RFC 7591) as a public native client, then
/// authorization code + PKCE with a 127.0.0.1 loopback redirect (RFC 8252),
/// with the RFC 8707 `resource` parameter. Falls back to the device flow
/// (RFC 8628) when the server won't register a loopback redirect.
/// The client ID and tokens live in the Keychain.
actor GranolaAuth: GranolaTokenProviding {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "GranolaAuth")
    static let clientName = "LidIA"
    static let callbackPath = "/callback"

    private let http: any GranolaHTTPLoading
    private let preflightHTTP: any GranolaHTTPLoading
    private let store: any GranolaCredentialStore
    private var cachedMetadata: GranolaAuthMetadata?
    private var credentials: GranolaCredentials?
    private var refreshTask: Task<String, Error>?

    init(
        http: any GranolaHTTPLoading = URLSessionGranolaHTTP(),
        preflightHTTP: any GranolaHTTPLoading = URLSessionGranolaHTTP(followRedirects: false),
        store: any GranolaCredentialStore = KeychainGranolaCredentialStore()
    ) {
        self.http = http
        self.preflightHTTP = preflightHTTP
        self.store = store
        self.credentials = store.load()
    }

    var isSignedIn: Bool {
        credentials?.refreshToken?.isEmpty == false || credentials?.accessToken?.isEmpty == false
    }

    func signOut() {
        // Keep the client registration; forget the tokens.
        if var kept = credentials {
            kept.refreshToken = nil
            kept.accessToken = nil
            kept.accessTokenExpiry = nil
            credentials = kept
            store.save(kept)
        }
    }

    // MARK: Discovery

    func metadata() async -> GranolaAuthMetadata {
        if let cachedMetadata { return cachedMetadata }
        let protected = await fetchJSON(GranolaAuthMetadata.protectedResourceMetadataURL)
        var server: [String: Any]?
        if let issuer = (protected?["authorization_servers"] as? [String])?.first,
           let issuerURL = URL(string: issuer), issuerURL.scheme == "https" {
            server = await fetchJSON(issuerURL.appending(path: ".well-known/oauth-authorization-server"))
        }
        if server == nil {
            server = await fetchJSON(URL(string: "https://mcp.granola.ai/.well-known/oauth-authorization-server")!)
        }
        let result = GranolaAuthMetadata.from(protectedResource: protected, authorizationServer: server)
        if protected == nil || server == nil {
            Self.logger.notice("Granola discovery incomplete; using built-in endpoints where missing")
        }
        cachedMetadata = result
        return result
    }

    private func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await http.load(request), (200...299).contains(response.statusCode) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Registration

    /// Registers LidIA as a public native client. `redirectURI` nil registers for the device flow only.
    func registerClient(redirectURI: String?) async throws -> GranolaCredentials {
        let metadata = await metadata()
        guard let endpoint = metadata.registrationEndpoint else {
            throw GranolaAuthError.registrationFailed("no registration endpoint")
        }
        var body: [String: Any] = [
            "client_name": Self.clientName,
            "token_endpoint_auth_method": "none",
            "application_type": "native",
            "response_types": ["code"],
            "grant_types": ["authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"],
        ]
        if let redirectURI { body["redirect_uris"] = [redirectURI] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.load(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(response.statusCode), let clientID = json?["client_id"] as? String, !clientID.isEmpty else {
            throw GranolaAuthError.registrationFailed(Self.describe(json: json, status: response.statusCode))
        }
        let registered = GranolaCredentials(
            clientID: clientID,
            redirectURI: (json?["redirect_uris"] as? [String])?.first ?? redirectURI
        )
        credentials = registered
        store.save(registered)
        return registered
    }

    // MARK: Authorization code + PKCE

    static func authorizationURL(
        metadata: GranolaAuthMetadata,
        clientID: String,
        redirectURI: String,
        pkce: PKCEPair,
        state: String
    ) -> URL? {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: GranolaAuthMetadata.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCEPair.method),
            URLQueryItem(name: "resource", value: metadata.resource),
        ]
        return components?.url
    }

    /// Whether the authorization server accepts this client and redirect,
    /// checked without a browser: a rejected request redirects to its error page.
    func preflight(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (_, response) = try? await preflightHTTP.load(request) else { return true }
        if (300...399).contains(response.statusCode) {
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            return !Self.isErrorRedirect(location)
        }
        // 4xx straight away means the server rejected the parameters.
        return !(400...499).contains(response.statusCode)
    }

    static func isErrorRedirect(_ location: String) -> Bool {
        location.contains("/oauth2/error") || location.contains("error=invalid_redirect_uri") || location.contains("error=invalid_client")
    }

    /// Full browser sign-in. `openURL` opens the system browser; `onDeviceCode`
    /// shows a code when sign-in has to fall back to the device flow.
    func signIn(
        openURL: @escaping @Sendable (URL) async -> Void,
        onDeviceCode: @escaping @Sendable (GranolaDeviceCode) async -> Void
    ) async throws {
        let metadata = await metadata()
        let pkce = PKCEPair.generate()
        let state = PKCEPair.randomURLSafeString(byteCount: 16)

        let server = await OAuthLoopbackServer(callbackPath: Self.callbackPath)
        do {
            try await server.start(expectedState: state, preferredPort: credentials?.redirectPort)
        } catch {
            Self.logger.notice("Loopback listener failed; using the device flow")
            try await signInWithDeviceCode(openURL: openURL, onDeviceCode: onDeviceCode)
            return
        }
        let redirectURI = await server.redirectURI

        var client: GranolaCredentials
        do {
            if let existing = credentials, existing.redirectURI != nil {
                client = existing
            } else {
                client = try await registerClient(redirectURI: redirectURI)
            }
        } catch {
            await server.stop()
            Self.logger.notice("Loopback registration failed (\(error.localizedDescription, privacy: .public)); using the device flow")
            try await signInWithDeviceCode(openURL: openURL, onDeviceCode: onDeviceCode)
            return
        }

        guard var url = Self.authorizationURL(metadata: metadata, clientID: client.clientID, redirectURI: redirectURI, pkce: pkce, state: state) else {
            await server.stop()
            throw GranolaAuthError.registrationFailed("bad authorization URL")
        }
        if !(await preflight(url)) {
            // The stored client is gone or doesn't allow this port: register again for this exact redirect.
            do {
                client = try await registerClient(redirectURI: redirectURI)
            } catch {
                await server.stop()
                try await signInWithDeviceCode(openURL: openURL, onDeviceCode: onDeviceCode)
                return
            }
            url = Self.authorizationURL(metadata: metadata, clientID: client.clientID, redirectURI: redirectURI, pkce: pkce, state: state) ?? url
            if !(await preflight(url)) {
                await server.stop()
                try await signInWithDeviceCode(openURL: openURL, onDeviceCode: onDeviceCode)
                return
            }
        }

        await openURL(url)
        let code: String
        do {
            code = try await server.waitForCode(timeout: 300)
        } catch OAuthLoopbackServer.ServerError.accessDenied {
            throw GranolaAuthError.accessDenied
        }
        try await exchange(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": client.clientID,
            "code_verifier": pkce.verifier,
            "resource": metadata.resource,
        ], clientID: client.clientID, redirectURI: redirectURI)
    }

    // MARK: Device flow

    func signInWithDeviceCode(
        openURL: @escaping @Sendable (URL) async -> Void,
        onDeviceCode: @escaping @Sendable (GranolaDeviceCode) async -> Void
    ) async throws {
        let metadata = await metadata()
        guard let endpoint = metadata.deviceAuthorizationEndpoint else {
            throw GranolaAuthError.registrationFailed("no device sign-in endpoint")
        }
        let client: GranolaCredentials
        if let existing = credentials { client = existing } else { client = try await registerClient(redirectURI: nil) }

        let (data, response) = try await postForm(endpoint, [
            "client_id": client.clientID,
            "scope": GranolaAuthMetadata.scope,
            "resource": metadata.resource,
        ])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(response.statusCode),
              let deviceCode = json?["device_code"] as? String,
              let userCode = json?["user_code"] as? String,
              let verification = ((json?["verification_uri_complete"] ?? json?["verification_uri"]) as? String).flatMap(URL.init(string:)) else {
            throw GranolaAuthError.registrationFailed(Self.describe(json: json, status: response.statusCode))
        }
        var interval = max(1, (json?["interval"] as? NSNumber)?.doubleValue ?? 5)
        let expiresIn = (json?["expires_in"] as? NSNumber)?.doubleValue ?? 300
        await onDeviceCode(GranolaDeviceCode(userCode: userCode, verificationURL: verification))
        await openURL(verification)

        let deadline = Date().addingTimeInterval(expiresIn)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (data, response) = try await postForm(metadata.tokenEndpoint, [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": deviceCode,
                "client_id": client.clientID,
                "resource": metadata.resource,
            ])
            if (200...299).contains(response.statusCode) {
                try store(tokenResponse: data, clientID: client.clientID, redirectURI: client.redirectURI)
                return
            }
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            switch error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw GranolaAuthError.deviceCodeExpired
            case "access_denied": throw GranolaAuthError.accessDenied
            default: throw GranolaAuthError.tokenRequestFailed(error ?? "HTTP \(response.statusCode)")
            }
        }
        throw GranolaAuthError.deviceCodeExpired
    }

    // MARK: Tokens

    func accessToken() async throws -> String {
        if let token = credentials?.accessToken, !token.isEmpty,
           credentials?.accessTokenExpiry.map({ $0 > Date().addingTimeInterval(30) }) ?? true {
            return token
        }
        return try await refresh()
    }

    func refreshedAccessToken(after failedToken: String) async throws -> String {
        if let current = credentials?.accessToken, !current.isEmpty, current != failedToken {
            return current
        }
        return try await refresh()
    }

    /// One refresh at a time: Granola rotates refresh tokens, so two parallel
    /// refreshes with the same token would sign the user out.
    private func refresh() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let credentials, let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw GranolaAuthError.notSignedIn
        }
        let metadata = await metadata()
        let (data, response) = try await postForm(metadata.tokenEndpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID,
            "resource": metadata.resource,
        ])
        guard (200...299).contains(response.statusCode) else {
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            if error == "invalid_grant" || error == "invalid_client" || response.statusCode == 401 {
                signOut()
                throw GranolaAuthError.sessionExpired
            }
            throw GranolaAuthError.tokenRequestFailed(error ?? "HTTP \(response.statusCode)")
        }
        try store(tokenResponse: data, clientID: credentials.clientID, redirectURI: credentials.redirectURI)
        guard let token = self.credentials?.accessToken else { throw GranolaAuthError.notSignedIn }
        return token
    }

    private func exchange(form: [String: String], clientID: String, redirectURI: String?) async throws {
        let metadata = await metadata()
        let (data, response) = try await postForm(metadata.tokenEndpoint, form)
        guard (200...299).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw GranolaAuthError.tokenRequestFailed(Self.describe(json: json, status: response.statusCode))
        }
        try store(tokenResponse: data, clientID: clientID, redirectURI: redirectURI)
    }

    private func store(tokenResponse data: Data, clientID: String, redirectURI: String?) throws {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw GranolaAuthError.tokenRequestFailed("no access token in the response")
        }
        var updated = credentials ?? GranolaCredentials(clientID: clientID, redirectURI: redirectURI)
        updated.clientID = clientID
        updated.redirectURI = redirectURI ?? updated.redirectURI
        updated.accessToken = access
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
            updated.refreshToken = refresh
        }
        updated.accessTokenExpiry = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
        credentials = updated
        store.save(updated)
    }

    private func postForm(_ url: URL, _ form: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        return try await http.load(request)
    }

    static func formEncode(_ form: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return form
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
            }
            .joined(separator: "&")
    }

    private static func describe(json: [String: Any]?, status: Int) -> String {
        if let description = json?["error_description"] as? String, !description.isEmpty { return description }
        if let error = json?["error"] as? String, !error.isEmpty { return error }
        if let message = json?["message"] as? String, !message.isEmpty { return message }
        return "HTTP \(status)"
    }
}
