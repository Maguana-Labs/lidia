import Foundation
import Observation

/// Settings for the "better voice with your own key" option of the voice
/// assistant. OpenAI keeps using the existing `ttsProvider == .openai` choice
/// and the OpenAI key from AI settings; Grok needs its own xAI key, kept in
/// the Keychain. Every cloud voice is off in Local-only mode.
@MainActor
@Observable
final class VoiceLayerSettings {
    static let xAIKeyAccount = "xaiAPIKey"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let usesKeychain: Bool
    @ObservationIgnored private var isLoading = false

    /// Answer with Grok's realtime voice (xAI) when a key is set.
    var grokVoiceEnabled = false { didSet { save(grokVoiceEnabled, "grokVoiceEnabled") } }
    /// Grok voice ID ("eve", "ara", "leo", "rex", "sal").
    var grokVoice = "eve" { didSet { save(grokVoice, "grokVoice") } }
    var xAIAPIKey = "" {
        didSet {
            guard !isLoading, usesKeychain, xAIAPIKey != oldValue else { return }
            SettingsKeychain.save(key: Self.xAIKeyAccount, value: xAIAPIKey)
        }
    }

    /// - Parameter usesKeychain: false in tests, so nothing touches the real Keychain.
    init(defaults: UserDefaults = .standard, usesKeychain: Bool = true) {
        self.defaults = defaults
        self.usesKeychain = usesKeychain
        isLoading = true
        grokVoiceEnabled = defaults.bool(forKey: "voice.grokVoiceEnabled")
        grokVoice = defaults.string(forKey: "voice.grokVoice") ?? "eve"
        if usesKeychain {
            xAIAPIKey = SettingsKeychain.load(key: Self.xAIKeyAccount) ?? ""
        }
        isLoading = false
    }

    private func save(_ value: some Any, _ name: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: "voice.\(name)")
    }
}
