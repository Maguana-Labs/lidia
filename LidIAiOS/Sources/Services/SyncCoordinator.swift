import Foundation
import LidIAKit
import Observation
import SwiftData
import os

/// Keeps this iPhone and the Mac in step through the user's lidia-sync server.
///
/// How sync works today:
/// - The Mac's library is a local SwiftData store (no CloudKit), so the Mac
///   and the iPhone meet at the lidia-sync server the Mac already uses
///   (Settings → Sync on the Mac): same URL, same token.
/// - Pull: every 30 s and when the app comes to the foreground, changes since
///   the last pull are applied with LidIAKit's `SyncEngine` (same rules as the
///   Mac: strict IDs, audio paths never taken from the server).
/// - Push: a meeting is pushed when its notes are written here, and action
///   items when they're completed, edited or added. On first connect, every
///   finished meeting recorded on this iPhone is pushed once.
/// - This is the advanced alternative to iCloud sync (the default, through the
///   library's CloudKit store); it pauses while iCloud sync is on.
/// - Local-only mode pauses all of it.
@MainActor
@Observable
final class SyncCoordinator {
    enum State: Equatable {
        case off
        case paused(String)
        case syncing
        case idle(lastSync: Date?)
        case failed(String)
    }

    private static let logger = Logger(subsystem: "io.lidia.ios", category: "Sync")

    private let settings: AppSettings
    private let container: ModelContainer
    private let client: SyncClient
    private var engine: SyncEngine?
    private var pollTask: Task<Void, Never>?
    private var configuredKey = ""

    private(set) var state: State = .off
    private(set) var lastSync: Date?

    init(settings: AppSettings, container: ModelContainer) {
        self.settings = settings
        self.container = container
        // Bypass proxies (iCloud Private Relay can't reach Tailscale hosts).
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        client = SyncClient(session: URLSession(configuration: configuration))
    }

    var isRunning: Bool { pollTask != nil }

    /// True when the library opened with iCloud sync. Both syncs would import the same
    /// meetings, so the self-hosted server pauses while iCloud sync runs.
    var iCloudActive = false

    /// Starts, restarts or stops sync to match the settings.
    func configure() {
        guard settings.syncEnabled else { stop(.off); return }
        guard !settings.localOnly else { stop(.paused("Paused while Local-only is on.")); return }
        guard !iCloudActive else { stop(.paused("Paused while iCloud sync is on.")); return }
        let url = settings.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.syncAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !token.isEmpty else { stop(.paused("Add your sync server and token.")); return }
        guard SyncSafety.isAllowedServerURL(url) else {
            stop(.failed("Use an https:// address. Plain http:// only works for a private network address."))
            return
        }
        let key = url + "|" + token
        if key == configuredKey, pollTask != nil { return }
        configuredKey = key
        pollTask?.cancel()

        let engine = SyncEngine(client: client, modelContainer: container)
        self.engine = engine
        let firstPushKey = "sync.initialPush." + url
        pollTask = Task { [weak self] in
            await self?.client.configure(serverURL: url, token: token)
            if UserDefaults.standard.bool(forKey: firstPushKey) == false {
                await self?.pushAllRecordedHere()
                UserDefaults.standard.set(true, forKey: firstPushKey)
            }
            while !Task.isCancelled {
                await self?.pull()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Pulls now (pull-to-refresh, foreground).
    func syncNow() async {
        guard isRunning else { return }
        await pull()
    }

    func push(_ meeting: Meeting) {
        guard isRunning, !settings.localOnly, let engine else { return }
        let items = meeting.actionItems
        Task {
            await engine.pushMeeting(meeting)
            for item in items { await engine.pushActionItem(item) }
        }
    }

    func push(_ item: ActionItem) {
        guard isRunning, !settings.localOnly, let engine else { return }
        Task { await engine.pushActionItem(item) }
    }

    func deleteMeeting(id: UUID) {
        guard isRunning, !settings.localOnly else { return }
        let client = client
        Task { _ = await client.deleteMeeting(id: id.uuidString) }
    }

    func deleteActionItem(id: UUID) {
        guard isRunning, !settings.localOnly else { return }
        let client = client
        Task { _ = await client.deleteActionItem(id: id.uuidString) }
    }

    // MARK: - Private

    private func pull() async {
        guard !settings.localOnly, let engine else { return }
        state = .syncing
        if let response = await client.sync() {
            engine.apply(response)
            lastSync = .now
            state = .idle(lastSync: lastSync)
        } else {
            state = .failed("Couldn't reach the sync server. Retrying every 30 seconds.")
        }
    }

    private func pushAllRecordedHere() async {
        guard let engine else { return }
        let context = container.mainContext
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        let mine = meetings.filter { $0.recordedOnThisDevice && $0.status == .complete }
        Self.logger.info("Initial push: \(mine.count) meetings recorded on this iPhone")
        for meeting in mine {
            await engine.pushMeeting(meeting)
            for item in meeting.actionItems { await engine.pushActionItem(item) }
        }
    }

    private func stop(_ newState: State) {
        pollTask?.cancel()
        pollTask = nil
        engine = nil
        configuredKey = ""
        state = newState
        Task { await client.stopPolling() }
    }
}
