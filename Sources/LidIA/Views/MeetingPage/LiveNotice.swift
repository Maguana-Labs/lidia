import AppKit
import Foundation

/// The one thing worth saying about a live recording, as a plain sentence with a button
/// that fixes it. The live page shows at most one.
struct LiveNotice: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case openScreenRecordingSettings
        case openSoundSettings
        case openMicrophoneSettings
        case keepRecording
    }

    var text: String
    var action: Action?
    /// Orange when it needs attention, secondary when it's information.
    var needsAttention = true

    var actionTitle: String? {
        switch action {
        case .openScreenRecordingSettings: "Turn On System Audio Recording…"
        case .openSoundSettings: "Open Sound Settings…"
        case .openMicrophoneSettings: "Open Microphone Settings…"
        case .keepRecording: "Keep Recording"
        case nil: nil
        }
    }

    /// The System Settings pane each fix opens.
    static func settingsURL(for action: Action) -> URL? {
        switch action {
        case .openScreenRecordingSettings:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .openSoundSettings:
            URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")
        case .openMicrophoneSettings:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .keepRecording:
            nil
        }
    }

    /// Picks the most important notice, or nil when everything is fine.
    ///
    /// - Parameters:
    ///   - systemAudioMissing: system audio was asked for but isn't being captured
    ///     (Screen Recording permission off, stream failed). Choosing "Microphone only"
    ///     on purpose isn't a problem and shows nothing.
    static func current(
        isPaused: Bool,
        autoStopSeconds: Int?,
        autoStopReason: String?,
        quality: RecordingSession.AudioQualityState,
        systemAudioMissing: Bool,
        liveTranscriptNotice: String?,
        captureMessage: String?
    ) -> LiveNotice? {
        if let seconds = autoStopSeconds {
            let reason = autoStopReason.map { "\($0)." } ?? "The meeting seems to have ended."
            return LiveNotice(text: "Stopping in \(seconds) s. \(reason)", action: .keepRecording)
        }
        if isPaused {
            return LiveNotice(text: "Recording is paused. Nothing is recorded until you resume.", action: nil, needsAttention: false)
        }
        if quality == .noInput {
            return LiveNotice(text: "Your microphone isn't picking up any sound.", action: .openSoundSettings)
        }
        if systemAudioMissing {
            return LiveNotice(text: "Other people aren't being recorded, only your microphone.", action: .openScreenRecordingSettings)
        }
        if let liveTranscriptNotice {
            return LiveNotice(text: liveTranscriptNotice, action: nil, needsAttention: !liveTranscriptNotice.hasPrefix("Downloading"))
        }
        if let captureMessage, !captureMessage.isEmpty, !systemAudioMissing {
            return LiveNotice(text: captureMessage, action: nil)
        }
        if quality == .clipping {
            return LiveNotice(text: "Your microphone is too loud, so the audio may distort.", action: .openSoundSettings)
        }
        return nil
    }
}
