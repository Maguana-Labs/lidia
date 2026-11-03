import Foundation
import Observation

/// Where notes and Ask run. On this iPhone by default; a cloud model only
/// when the user picks one and adds their own key. Never a silent fallback.
enum NotesEngine: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case anthropic
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "On this iPhone"
        case .anthropic: "Claude (your key)"
        case .openAI: "OpenAI (your key)"
        }
    }

    var keyAccount: String? {
        switch self {
        case .onDevice: nil
        case .anthropic: "lidia.anthropic.apiKey"
        case .openAI: "lidia.openai.apiKey"
        }
    }

    var defaultModel: String {
        switch self {
        case .onDevice: "apple-on-device"
        case .anthropic: "claude-sonnet-5-5"
        case .openAI: "gpt-5"
        }
    }
}

/// The iPhone app's settings. Non-secret values in UserDefaults, saved on
/// set; keys and tokens in the Keychain.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    private let persist: Bool

    var displayName: String { didSet { save(displayName, "displayName") } }
    var localOnly: Bool { didSet { save(localOnly, "localOnlyMode") } }
    var notesEngine: NotesEngine { didSet { save(notesEngine.rawValue, "notesEngine") } }
    var cloudModel: String { didSet { save(cloudModel, "cloudModel") } }
    var transcriptionLocaleID: String { didSet { save(transcriptionLocaleID, "transcriptionLocale") } }
    var keepAudio: Bool { didSet { save(keepAudio, "keepAudio") } }
    var showLiveActivity: Bool { didSet { save(showLiveActivity, "showLiveActivity") } }
    var consentReminder: Bool { didSet { save(consentReminder, "consentReminder") } }
    /// "Let Siri read meeting content" (summaries, notes, Ask answers). Local-only
    /// overrides it. Read by `SiriContentPolicy` from the same key as the Mac.
    var siriReadsContent: Bool { didSet { save(siriReadsContent, "siriReadsMeetingContent") } }

    /// Sync the library with iCloud (private database, shared with the Mac). On by default.
    /// Read when the app starts: a change takes effect the next time LidIA opens.
    var iCloudSync: Bool { didSet { save(iCloudSync, Self.iCloudSyncKey) } }
    static let iCloudSyncKey = "iCloudSyncEnabled"

    // Sync with the Mac (lidia-sync server)
    var syncEnabled: Bool { didSet { save(syncEnabled, "syncEnabled") } }
    var syncServerURL: String { didSet { save(syncServerURL, "syncServerURL") } }
    var syncAuthToken: String { didSet { if persist { Keychain.save(syncAuthToken, account: "lidia.sync.authToken") } } }

    /// Keys typed on this iPhone, by provider.
    var anthropicKey: String { didSet { if persist { Keychain.save(anthropicKey, account: "lidia.anthropic.apiKey") } } }
    var openAIKey: String { didSet { if persist { Keychain.save(openAIKey, account: "lidia.openai.apiKey") } } }

    /// Suggestions on Home the user dismissed.
    var dismissedSuggestions: Set<String> { didSet { save(Array(dismissedSuggestions), "dismissedSuggestions") } }

    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        displayName = defaults.string(forKey: "displayName") ?? ""
        localOnly = defaults.bool(forKey: "localOnlyMode")
        notesEngine = NotesEngine(rawValue: defaults.string(forKey: "notesEngine") ?? "") ?? .onDevice
        cloudModel = defaults.string(forKey: "cloudModel") ?? ""
        transcriptionLocaleID = defaults.string(forKey: "transcriptionLocale") ?? Self.defaultLocaleID
        keepAudio = defaults.object(forKey: "keepAudio") as? Bool ?? true
        showLiveActivity = defaults.object(forKey: "showLiveActivity") as? Bool ?? true
        consentReminder = defaults.object(forKey: "consentReminder") as? Bool ?? true
        siriReadsContent = defaults.object(forKey: "siriReadsMeetingContent") as? Bool ?? true
        iCloudSync = defaults.object(forKey: Self.iCloudSyncKey) as? Bool ?? true
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncServerURL = defaults.string(forKey: "syncServerURL") ?? ""
        syncAuthToken = persist ? (Keychain.load(account: "lidia.sync.authToken") ?? "") : ""
        anthropicKey = persist ? (Keychain.load(account: "lidia.anthropic.apiKey") ?? "") : ""
        openAIKey = persist ? (Keychain.load(account: "lidia.openai.apiKey") ?? "") : ""
        dismissedSuggestions = Set(defaults.stringArray(forKey: "dismissedSuggestions") ?? [])
    }

    /// "en_US" from the current locale, without calendar or region overrides.
    static var defaultLocaleID: String {
        let locale = Locale.current
        guard let language = locale.language.languageCode?.identifier else { return "en_US" }
        if let region = locale.region?.identifier { return "\(language)_\(region)" }
        return language
    }

    var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? ""
    }

    var transcriptionLocale: Locale { Locale(identifier: transcriptionLocaleID) }

    /// The key for a cloud engine: typed here, else shared by the Mac.
    func apiKey(for engine: NotesEngine) -> (key: String, fromMac: Bool)? {
        switch engine {
        case .onDevice: return nil
        case .anthropic:
            if !anthropicKey.isEmpty { return (anthropicKey, false) }
        case .openAI:
            if !openAIKey.isEmpty { return (openAIKey, false) }
        }
        guard persist, let account = engine.keyAccount, let shared = Keychain.loadFromMac(account: account) else { return nil }
        return (shared, true)
    }

    var effectiveCloudModel: String {
        let trimmed = cloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? notesEngine.defaultModel : trimmed
    }

    private func save(_ value: Any, _ key: String) {
        guard persist else { return }
        defaults.set(value, forKey: key)
    }
}
