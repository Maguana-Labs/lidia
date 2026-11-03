import Foundation

/// Who has the microphone for a voice feature right now, so dictation and the
/// voice assistant never listen at the same time.
///
/// - Starting the assistant cancels a dictation in progress.
/// - The dictation key does nothing while the assistant is open.
@MainActor
enum VoiceActivity {
    static var isAssistantActive = false
    static var isDictating = false
    /// Set by the dictation controller.
    static var cancelDictation: (() -> Void)?

    static func assistantWillStart() {
        if isDictating { cancelDictation?() }
        isAssistantActive = true
    }

    static func assistantDidEnd() {
        isAssistantActive = false
    }
}
