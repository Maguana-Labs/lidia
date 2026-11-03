import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that catches an OAuth redirect
/// (RFC 8252 loopback redirect for native apps).
///
/// Bound to the loopback interface only, so nothing else on the network can
/// reach it. Checks the `state` parameter, answers the browser with a short
/// page, and hands back the authorization code. Shared by Google Calendar and
/// Granola sign-in.
@MainActor
final class OAuthLoopbackServer {
    /// The parsed loopback callback.
    enum Callback: Equatable, Sendable {
        case code(String)
        case denied(String)
        case stateMismatch
        /// Not the OAuth redirect (a favicon request, say). Keep listening.
        case ignored
    }

    enum ServerError: Error, LocalizedError, Equatable {
        case couldNotListen
        case timeout
        case accessDenied(String)
        case stateMismatch
        case cancelled

        var errorDescription: String? {
            switch self {
            case .couldNotListen: "LidIA couldn't open a local port to finish sign-in."
            case .timeout: "Sign-in timed out. Please try again."
            case .accessDenied: "Sign-in was cancelled."
            case .stateMismatch: "Sign-in didn't match this request. Please try again."
            case .cancelled: "Sign-in was cancelled."
            }
        }
    }

    /// Path the redirect URI ends with: "" for "http://127.0.0.1:port", or "/callback".
    let callbackPath: String
    /// Text shown in the browser once the code arrives.
    var successTitle = "You're signed in"
    var successMessage = "You can close this tab and go back to LidIA."

    private var listener: NWListener?
    private(set) var port: UInt16?
    private var expectedState = ""
    private var waiter: CheckedContinuation<String, Error>?
    /// A callback that arrived before `waitForCode` was called.
    private var early: Result<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(callbackPath: String = "") {
        self.callbackPath = callbackPath
    }

    /// "http://127.0.0.1:<port><callbackPath>". Valid after `start`.
    var redirectURI: String {
        "http://127.0.0.1:\(port ?? 0)\(callbackPath)"
    }

    /// Starts listening. Tries `preferredPort` first (so a redirect URI
    /// registered earlier matches exactly), then any free port.
    func start(expectedState: String, preferredPort: UInt16? = nil) async throws {
        self.expectedState = expectedState
        if let preferredPort, preferredPort != 0, (try? await listen(on: preferredPort)) != nil {
            return
        }
        try await listen(on: nil)
    }

    private func listen(on requestedPort: UInt16?) async throws {
        let parameters = NWParameters.tcp
        let nwPort = requestedPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        let gate = OnceGate()

        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready:
                            if gate.open() { continuation.resume() }
                        case .failed, .cancelled:
                            if gate.open() {
                                continuation.resume(throwing: ServerError.couldNotListen)
                            } else if self?.listener === listener {
                                self?.finish(.failure(ServerError.couldNotListen))
                            }
                        default:
                            break
                        }
                    }
                }
                listener.start(queue: .main)
            }
        } catch {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            throw error
        }
        guard listener.port != nil else {
            listener.cancel()
            throw ServerError.couldNotListen
        }
        self.listener = listener
        self.port = listener.port?.rawValue
    }

    /// Waits for the browser to come back with a code.
    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        if let early {
            self.early = nil
            stop()
            return try early.get()
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(ServerError.timeout))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let early {
                    self.early = nil
                    continuation.resume(with: early)
                    stop()
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(ServerError.cancelled)) }
        }
    }

    /// Stops listening. Safe to call more than once.
    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<String, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
            stop()
        } else if early == nil {
            early = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self,
                      let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.split(separator: "\r\n").first else {
                    connection.cancel()
                    return
                }
                let parts = firstLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else {
                    connection.cancel()
                    return
                }
                switch Self.parseCallback(requestTarget: String(parts[1]), expectedState: self.expectedState) {
                case .code(let code):
                    Self.respond(connection, status: "200 OK", title: self.successTitle, message: self.successMessage)
                    self.finish(.success(code))
                case .denied(let reason):
                    Self.respond(connection, status: "200 OK", title: "Sign-in cancelled", message: "You can close this tab.")
                    self.finish(.failure(ServerError.accessDenied(reason)))
                case .stateMismatch:
                    Self.respond(connection, status: "400 Bad Request", title: "Sign-in failed",
                                 message: "This sign-in didn't come from LidIA. Try again from the app.")
                    self.finish(.failure(ServerError.stateMismatch))
                case .ignored:
                    // A favicon request or similar: answer it and keep waiting.
                    Self.respond(connection, status: "404 Not Found", title: "Not found", message: "")
                }
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, title: String, message: String) {
        let html = "<html><head><meta charset='utf-8'></head><body style='font-family:system-ui;text-align:center;padding:40px'>"
            + "<h2>\(title)</h2><p>\(message)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Reads the request target of the browser's GET to the loopback server.
    nonisolated static func parseCallback(requestTarget: String, expectedState: String) -> Callback {
        guard let components = URLComponents(string: "http://127.0.0.1\(requestTarget)") else { return .ignored }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        let code = value("code")
        let error = value("error")
        guard code != nil || error != nil else { return .ignored }
        guard value("state") == expectedState else { return .stateMismatch }
        if let code, !code.isEmpty { return .code(code) }
        return .denied(error ?? "unknown")
    }
}

/// Lets exactly one caller through. Main-actor only.
@MainActor
private final class OnceGate {
    private var used = false
    func open() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}
