import Foundation
import os

/// HTTP client for the lidia-sync server.
/// Handles polling, pushing changes, and auth.
public actor SyncClient {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "SyncClient")

    private let session: URLSession
    private var serverURL: URL?
    private var token: String?
    private var lastSyncTime: Int64 = 0
    private var pollTask: Task<Void, Never>?

    public var isConfigured: Bool { serverURL != nil && token != nil }

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Configure the sync client with server URL and auth token.
    public func configure(serverURL: String, token: String) {
        self.serverURL = URL(string: serverURL)
        self.token = token
        self.lastSyncTime = 0
        Self.logger.info("Configured sync: \(serverURL, privacy: .public)")
    }

    /// Clear configuration and stop polling.
    public func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        serverURL = nil
        token = nil
        lastSyncTime = 0
    }

    // MARK: - Sync

    /// Fetch all changes since last sync. Returns nil if not configured or unreachable.
    public func sync() async -> SyncResponse? {
        guard let url = serverURL, let token else { return nil }

        let endpoint = url.appendingPathComponent("sync")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(lastSyncTime))]

        guard let requestURL = components.url else { return nil }

        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Self.logger.error("Sync failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)
            lastSyncTime = syncResponse.serverTime
            return syncResponse
        } catch {
            Self.logger.error("Sync error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Push

    /// Push a meeting to the server.
    public func pushMeeting(_ meeting: SyncMeeting) async -> Bool {
        await post(path: "meetings", body: meeting)
    }

    /// Push an action item to the server.
    public func pushActionItem(_ item: SyncActionItem) async -> Bool {
        await post(path: "action-items", body: item)
    }

    /// Soft-delete a meeting on the server.
    public func deleteMeeting(id: String) async -> Bool {
        await delete(path: "meetings/\(id)")
    }

    /// Soft-delete an action item on the server.
    public func deleteActionItem(id: String) async -> Bool {
        await delete(path: "action-items/\(id)")
    }

    /// Push a file (SOUL.md or MEMORY.md) to the server.
    public func pushFile(name: String, content: String) async -> Bool {
        await put(path: "files/\(name)", body: ["content": content])
    }

    /// Push settings to the server.
    public func pushSettings(_ settings: [String: String]) async -> Bool {
        await put(path: "settings", body: settings)
    }

    // MARK: - Poll Loop

    /// Start polling every `interval` seconds. Calls `onSync` with each response.
    public func startPolling(interval: TimeInterval = 30, onSync: @escaping @Sendable (SyncResponse) async -> Void) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let response = await self?.sync() {
                    await onSync(response)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stop the poll loop.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - HTTP Helpers

    private func post<T: Encodable>(path: String, body: T) async -> Bool {
        guard let url = serverURL, let token else { return false }

        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                Self.logger.error("POST /\(path) failed: HTTP \(status)")
                return false
            }
            return true
        } catch {
            Self.logger.error("POST /\(path) error: \(error.localizedDescription)")
            return false
        }
    }

    private func put<T: Encodable>(path: String, body: T) async -> Bool {
        guard let url = serverURL, let token else { return false }

        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                Self.logger.error("PUT /\(path) failed: HTTP \(status)")
                return false
            }
            return true
        } catch {
            Self.logger.error("PUT /\(path) error: \(error.localizedDescription)")
            return false
        }
    }

    private func delete(path: String) async -> Bool {
        guard let url = serverURL, let token else { return false }

        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                Self.logger.error("DELETE /\(path) failed: HTTP \(status)")
                return false
            }
            return true
        } catch {
            Self.logger.error("DELETE /\(path) error: \(error.localizedDescription)")
            return false
        }
    }
}
