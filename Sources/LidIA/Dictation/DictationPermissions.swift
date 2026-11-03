import AppKit
import ApplicationServices
import AVFoundation

/// The permissions dictation needs, and the system setting that makes the
/// Globe key do something on its own.
@MainActor
enum DictationPermissions {
    /// Accessibility: needed to see the dictation key in other apps and to type there.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (which also adds LidIA to the Accessibility list).
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// What "Press 🌐 key to" is set to in System Settings › Keyboard.
    enum GlobeKeyAction: Int {
        case doNothing = 0
        case changeInputSource = 1
        case showEmoji = 2
        case startDictation = 3

        var title: String {
            switch self {
            case .doNothing: "Do Nothing"
            case .changeInputSource: "Change Input Source"
            case .showEmoji: "Show Emoji & Symbols"
            case .startDictation: "Start Dictation"
            }
        }
    }

    /// Unset means the system default, which is "Show Emoji & Symbols".
    static var globeKeyAction: GlobeKeyAction {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? Int).flatMap(GlobeKeyAction.init(rawValue:)) ?? .showEmoji
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
