import Foundation
import Observation

/// The key you hold (or double-tap) to dictate into any app.
///
/// Only keys that are useless on their own are offered: a right-hand modifier
/// or Fn. Pressing the key together with any other key is a shortcut, not
/// dictation, so ⌥Space or ⌥N still work.
enum DictationTriggerKey: String, CaseIterable, Identifiable, Sendable {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .fn: "Fn / Globe (🌐)"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        case .fn: "fn"
        }
    }

    /// Virtual key codes reported in `flagsChanged` events for this key.
    /// The Globe key reports 63 (kVK_Function) on most keyboards and 179 on some.
    var keyCodes: Set<UInt16> {
        switch self {
        case .rightOption: [61]
        case .rightCommand: [54]
        case .rightControl: [62]
        case .fn: [63, 179]
        }
    }

    /// The modifier flag (CGEventFlags raw value) that is set while the key is down.
    var flagMask: UInt64 {
        switch self {
        case .rightOption: 0x0008_0000   // maskAlternate
        case .rightCommand: 0x0010_0000  // maskCommand
        case .rightControl: 0x0004_0000  // maskControl
        case .fn: 0x0080_0000            // maskSecondaryFn
        }
    }

    /// The `voiceHotkey` modifier name this key shares, if any (for conflict hints).
    var sharedHotkeyModifier: String? {
        switch self {
        case .rightOption: "option"
        case .rightCommand: "command"
        case .rightControl: "control"
        case .fn: nil
        }
    }
}

/// How the trigger key starts and stops dictation.
enum DictationActivation: String, CaseIterable, Identifiable, Sendable {
    /// Hold to talk; or double-tap to keep listening hands-free, tap again to finish.
    case holdOrDoubleTap
    /// Hold to talk, release to insert.
    case hold
    /// Double-tap to start, tap once to finish.
    case doubleTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdOrDoubleTap: "Hold, or double-tap for hands-free"
        case .hold: "Hold to talk"
        case .doubleTap: "Double-tap to start and stop"
        }
    }
}

/// How finished text gets into the other app.
enum DictationInsertionMethod: String, CaseIterable, Identifiable, Sendable {
    /// Accessibility where the field supports it, otherwise paste.
    case automatic
    /// Paste with ⌘V, then put the clipboard back.
    case paste
    /// Accessibility only. Text that can't be inserted is kept in History.
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .paste: "Paste (⌘V)"
        case .accessibility: "Accessibility only"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Types straight into the field, or pastes when the app doesn't allow that."
        case .paste: "Works in every app. Your clipboard is put back afterwards."
        case .accessibility: "Never touches the clipboard. Some apps (browsers, Electron) won't accept it."
        }
    }
}

/// Which speech recogniser dictation uses.
enum DictationEngineChoice: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device SpeechAnalyzer: live text, no download, many languages.
    case appleOnDevice
    /// The live engine registered through `DictationEngineRegistry` (the meeting engine).
    case liveEngine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleOnDevice: "Apple, on this Mac"
        case .liveEngine: "Same as live meeting transcripts"
        }
    }
}

/// Dictation preferences. Saved to user defaults as they change (`dictation.*`).
@MainActor
@Observable
final class DictationSettings {
    static let defaultHistoryLimit = 25

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    /// Off until the user turns it on (it needs Accessibility permission).
    var enabled = false { didSet { save(enabled, "enabled") } }
    var triggerKey: DictationTriggerKey = .rightOption { didSet { save(triggerKey.rawValue, "triggerKey") } }
    var activation: DictationActivation = .holdOrDoubleTap { didSet { save(activation.rawValue, "activation") } }
    var insertion: DictationInsertionMethod = .automatic { didSet { save(insertion.rawValue, "insertion") } }
    var engine: DictationEngineChoice = .appleOnDevice { didSet { save(engine.rawValue, "engine") } }
    /// BCP-47 identifier ("en-US", "es-ES"). Empty follows the transcription language, then the system.
    var language = "" { didSet { save(language, "language") } }
    /// Remove fillers, apply self-corrections and lists. Deterministic and instant.
    var tidyText = true { didSet { save(tidyText, "tidyText") } }
    /// Run the cleaned text through the AI provider (low effort). Off by default.
    var polishWithAI = false { didSet { save(polishWithAI, "polishWithAI") } }
    /// Keep recent dictations on this Mac.
    var keepHistory = true { didSet { save(keepHistory, "keepHistory") } }
    var historyLimit = DictationSettings.defaultHistoryLimit { didSet { save(historyLimit, "historyLimit") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        enabled = defaults.bool(forKey: key("enabled"))
        triggerKey = DictationTriggerKey(rawValue: defaults.string(forKey: key("triggerKey")) ?? "") ?? .rightOption
        activation = DictationActivation(rawValue: defaults.string(forKey: key("activation")) ?? "") ?? .holdOrDoubleTap
        insertion = DictationInsertionMethod(rawValue: defaults.string(forKey: key("insertion")) ?? "") ?? .automatic
        engine = DictationEngineChoice(rawValue: defaults.string(forKey: key("engine")) ?? "") ?? .appleOnDevice
        language = defaults.string(forKey: key("language")) ?? ""
        tidyText = defaults.object(forKey: key("tidyText")) as? Bool ?? true
        polishWithAI = defaults.bool(forKey: key("polishWithAI"))
        keepHistory = defaults.object(forKey: key("keepHistory")) as? Bool ?? true
        let limit = defaults.integer(forKey: key("historyLimit"))
        historyLimit = limit > 0 ? limit : Self.defaultHistoryLimit
    }

    /// The locale dictation listens for.
    func resolvedLocale(sttLanguage: String) -> Locale {
        if !language.isEmpty { return Locale(identifier: language) }
        if !sttLanguage.isEmpty { return Locale(identifier: sttLanguage) }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }

    private func key(_ name: String) -> String { "dictation.\(name)" }

    private func save(_ value: some Any, _ name: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key(name))
    }
}
