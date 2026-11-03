import Foundation

/// What LidIA may hand to Siri, Shortcuts and Spotlight.
///
/// Siri can process a request on Apple's servers, so meeting content counts as
/// leaving the device. Titles, dates, people, projects and action-item titles
/// are always fine (they're what Siri needs to find things). Summaries,
/// decisions, notes, transcript excerpts and Ask answers are content: they go
/// to Siri only when Local-only mode is off **and** the user leaves
/// "Let Siri read meeting content" on (Settings › Privacy).
///
/// Reads `UserDefaults` directly, like the Mac's `PrivacyGate`, so it can be
/// checked from any actor. Both apps store Local-only mode under the same key.
public struct SiriContentPolicy: Sendable, Equatable {
    /// The Mac's and the iPhone's Local-only mode setting.
    public static let localOnlyKey = "localOnlyMode"
    /// "Let Siri read meeting content". Missing means on.
    public static let readsContentKey = "siriReadsMeetingContent"

    public var localOnly: Bool
    public var userAllowsContent: Bool

    public init(localOnly: Bool, userAllowsContent: Bool) {
        self.localOnly = localOnly
        self.userAllowsContent = userAllowsContent
    }

    /// The policy right now.
    public static func current(_ defaults: UserDefaults = .standard) -> SiriContentPolicy {
        SiriContentPolicy(
            localOnly: defaults.bool(forKey: localOnlyKey),
            userAllowsContent: defaults.object(forKey: readsContentKey) as? Bool ?? true
        )
    }

    /// Whether summaries, decisions, notes, transcript and Ask answers may go to Siri.
    public var allowsMeetingContent: Bool { !localOnly && userAllowsContent }

    /// What Siri says instead of the content, or nil when content is allowed.
    public var blockedMessage: String? {
        if localOnly {
            return "Local-only mode is on, so LidIA keeps meeting content away from Siri. Open the meeting in LidIA to read it."
        }
        if !userAllowsContent {
            return "LidIA doesn't share meeting content with Siri. You can change this in LidIA's Settings, under Privacy."
        }
        return nil
    }
}

/// Errors the shared intents throw. Their text is what Siri says.
public enum LidIASiriError: Error, LocalizedError, Equatable {
    /// The library isn't open yet (the app is still starting).
    case notReady
    case meetingNotFound
    case actionItemNotFound
    /// Local-only mode or the user's setting keeps content away from Siri.
    case contentBlocked(String)
    case notRecording
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: "LidIA is still opening your library. Try again in a moment."
        case .meetingNotFound: "I couldn't find that meeting in LidIA."
        case .actionItemNotFound: "I couldn't find that action item in LidIA."
        case .contentBlocked(let message): message
        case .notRecording: "LidIA isn't recording a meeting right now."
        case .unavailable(let message): message
        }
    }
}
