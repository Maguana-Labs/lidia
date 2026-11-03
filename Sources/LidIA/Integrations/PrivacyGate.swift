import Foundation
import os

/// The single switch every outbound integration checks before sending meeting
/// content off this Mac.
///
/// `AppSettings.localOnlyMode` persists to the `localOnlyMode` user default;
/// this reads the same key so that actors and background tasks can check it
/// without hopping to the main actor. `UserDefaults` is thread-safe.
///
/// Integrations call `try PrivacyGate.check(.notion)` (throwing paths) or
/// `guard PrivacyGate.allows(.slack) else { return }` (fire-and-forget paths).
///
/// Inbound-only reads are not gated, because they send no meeting content:
/// Google and Apple Calendar reads, and "Import from Granola…", which only
/// downloads the user's Granola meetings (it sends Granola its own meeting IDs).
enum PrivacyGate {
    static let localOnlyModeKey = "localOnlyMode"
    private static let logger = Logger(subsystem: "io.lidia.app", category: "PrivacyGate")

    /// Places meeting content can be sent to.
    enum Destination: String, Sendable, CaseIterable {
        case notion = "Notion"
        case n8n = "n8n"
        case slack = "Slack"
        case clickUp = "ClickUp"
        case linear = "Linear"
        case deviceSync = "Device Sync"
        case companyLogos = "Company logos"
    }

    struct LocalOnlyModeError: LocalizedError, Equatable {
        let destination: Destination

        var errorDescription: String? {
            "Local-only mode is on, so nothing was sent to \(destination.rawValue). Turn it off in Settings › General › Privacy to send."
        }
    }

    /// True when Local-only mode is on.
    static var isLocalOnly: Bool {
        UserDefaults.standard.bool(forKey: localOnlyModeKey)
    }

    /// Whether content may be sent to `destination` right now.
    static func allows(_ destination: Destination) -> Bool {
        if isLocalOnly {
            logger.info("Blocked by Local-only mode: \(destination.rawValue, privacy: .public)")
            return false
        }
        return true
    }

    /// Throws `LocalOnlyModeError` when Local-only mode blocks `destination`.
    static func check(_ destination: Destination) throws {
        guard allows(destination) else { throw LocalOnlyModeError(destination: destination) }
    }

    /// Whether an AI request carrying meeting content may go to `url`.
    ///
    /// The transport-level backstop behind `makeLLMClient` / `makeGatedClient`:
    /// AI clients (chat, chat streams, the OpenAI WebSocket chat, OpenAI voice
    /// and TTS) call it right before sending, so a path that skipped the
    /// factory still can't leave this Mac. In Local-only mode only loopback
    /// hosts are allowed; servers on the network and the cloud are blocked.
    static func allowsAIEndpoint(_ url: URL) -> Bool {
        guard isLocalOnly else { return true }
        // No host (file URLs, unparsed strings) means nothing goes on the network.
        guard let host = url.host, !host.isEmpty else { return true }
        if DataLocality.forHost(host) == .onDevice { return true }
        logger.info("Blocked AI request to \(host, privacy: .public) by Local-only mode")
        return false
    }

    /// Throws `LLMError.cloudBlocked` when Local-only mode blocks `url`.
    static func checkAIEndpoint(_ url: URL, provider: String) throws {
        guard allowsAIEndpoint(url) else {
            throw LLMError.cloudBlocked(
                provider: provider,
                reason: "Local-only mode is on, so meeting data stays on this Mac."
            )
        }
    }
}
