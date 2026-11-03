import AppKit
import Foundation
import os
import SwiftData

/// Runs "Import from Granola…" for the whole app.
///
/// One shared instance, so the File menu and Settings show the same import,
/// and closing the sheet doesn't stop it.
@MainActor
@Observable
final class GranolaImportController {
    static let shared = GranolaImportController()
    private static let logger = Logger(subsystem: "io.lidia.app", category: "GranolaImport")

    enum Phase: Equatable {
        case idle
        case signingIn
        case enterCode(GranolaDeviceCode)
        case working(GranolaImportProgress)
        case finished(GranolaImportSummary)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var isSignedIn = false
    /// Also re-download meetings imported before (keeps anything edited in LidIA).
    var refreshExisting = false

    var isBusy: Bool {
        switch phase {
        case .signingIn, .enterCode, .working: true
        default: false
        }
    }

    private let auth: GranolaAuth
    private var task: Task<Void, Never>?

    init(auth: GranolaAuth = GranolaAuth()) {
        self.auth = auth
        Task { [weak self] in await self?.refreshSignInState() }
    }

    func refreshSignInState() async {
        isSignedIn = await auth.isSignedIn
    }

    /// Signs in if needed, then imports.
    func start(container: ModelContainer) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(container: container)
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Back to the start screen (after a result or an error).
    func reset() {
        guard !isBusy else { return }
        phase = .idle
    }

    func signOut() {
        guard !isBusy else { return }
        Task {
            await auth.signOut()
            await refreshSignInState()
            phase = .idle
        }
    }

    private func run(container: ModelContainer) async {
        do {
            if !(await auth.isSignedIn) {
                phase = .signingIn
                try await auth.signIn(
                    openURL: { url in
                        await MainActor.run { _ = NSWorkspace.shared.open(url) }
                    },
                    onDeviceCode: { [weak self] code in
                        await MainActor.run { self?.phase = .enterCode(code) }
                    }
                )
                await refreshSignInState()
            }
            try Task.checkCancellation()
            phase = .working(.connecting)

            // Built off the main actor so its context works in the background.
            let store = await Task.detached { GranolaImportStore(modelContainer: container) }.value
            let importer = GranolaImporter(client: GranolaMCPClient(tokens: auth), store: store)
            let summary = try await importer.run(refreshExisting: refreshExisting) { [weak self] progress in
                await MainActor.run { self?.phase = .working(progress) }
            }
            phase = .finished(summary)
        } catch {
            await refreshSignInState()
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                || error as? OAuthLoopbackServer.ServerError == .cancelled {
                phase = .idle
                return
            }
            Self.logger.error("Granola import failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(Self.message(for: error))
        }
    }

    /// Plain words for what went wrong.
    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline. Connect to the internet and try again; meetings already imported are kept."
            case .timedOut:
                return "Granola took too long to answer. Try again; meetings already imported are kept."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "LidIA couldn't reach Granola. Check your connection and try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
