import AppKit
import AVFoundation
import os

/// Lock-protected audio buffer shared between the realtime audio tap and the main thread.
/// This is intentionally a standalone class with NO reference to any actor-isolated type,
/// ensuring the audio tap closure never triggers Swift 6.2 actor isolation checks.
/// @unchecked Sendable is safe: all mutable state protected by NSLock.
private final class AudioTapBuffer: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var rms: Float = 0.0
    var hasReceivedSpeech = false
    var silenceStart: Date?

    let silenceThreshold: Float = 0.02
    var silenceDuration: TimeInterval = 1.5

    func isSilenceDetected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hasReceivedSpeech, let start = silenceStart else { return false }
        return Date().timeIntervalSince(start) >= silenceDuration
    }

    func drain() -> (samples: [Float], rms: Float) {
        lock.lock()
        let s = samples
        let r = rms
        samples = []
        lock.unlock()
        return (s, r)
    }

    func reset() {
        lock.lock()
        samples = []
        rms = 0.0
        hasReceivedSpeech = false
        silenceStart = nil
        lock.unlock()
    }
}

/// Manages AVAudioEngine and sample collection entirely off MainActor.
/// The tap closure captures only AudioTapBuffer (non-isolated, non-actor),
/// so Swift won't insert MainActor assertions on the realtime audio thread.
/// @unchecked Sendable is safe: `buffer` is internally lock-protected,
/// and `engine` is only accessed from the owning VoiceInputController (@MainActor).
/// The audio tap closure captures only the lock-protected `buffer`, not `self`.
final class AudioCaptureSession: @unchecked Sendable {
    private let buffer = AudioTapBuffer()
    private var engine: AVAudioEngine?
    /// The microphone's native rate (44.1 kHz on many Macs, 16/24 kHz on
    /// headsets). Callers must resample from this, not assume 48 kHz.
    private(set) var sampleRate = 48_000

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // No input device: a 0 Hz / 0-channel format makes installTap raise an exception.
        try AudioCaptureError.checkInputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)

        // Capture only the buffer — NOT self — to avoid any actor isolation inheritance.
        let buf = buffer
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { pcmBuffer, _ in
            let channelData = pcmBuffer.floatChannelData?[0]
            let frameLength = Int(pcmBuffer.frameLength)
            guard let channelData, frameLength > 0 else { return }

            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength))

            buf.lock.lock()
            buf.samples.append(contentsOf: samples)
            buf.rms = rms

            if rms > buf.silenceThreshold {
                buf.hasReceivedSpeech = true
                buf.silenceStart = nil
            } else if buf.hasReceivedSpeech && buf.silenceStart == nil {
                buf.silenceStart = Date()
            }
            buf.lock.unlock()
        }

        try engine.start()
        self.engine = engine
        sampleRate = Int(format.sampleRate)
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    func drain() -> (samples: [Float], rms: Float) {
        buffer.drain()
    }

    func isSilenceDetected() -> Bool {
        buffer.isSilenceDetected()
    }

    func reset() {
        buffer.reset()
    }

    func setSilenceDuration(_ duration: TimeInterval) {
        buffer.lock.lock()
        buffer.silenceDuration = duration
        buffer.lock.unlock()
    }
}

@MainActor
@Observable
final class VoiceInputController {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "VoiceInput")

    enum State {
        case idle
        case listening
        case thinking
        case speaking
    }

    var state: State = .idle
    var transcribedText: String = ""
    var responseText: String = ""
    var audioLevel: Float = 0.0
    var isMuted: Bool = false

    var hotkeyCode: UInt16 = 49
    var hotkeyModifiers: NSEvent.ModifierFlags = .option

    /// Configurable silence duration (seconds) before auto-submit.
    var silenceDuration: TimeInterval = 1.5

    /// Callback fired when silence is detected after speech.
    var onSilenceDetected: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var captureSession: AudioCaptureSession?
    private var audioSamples: [Float] = []
    private var drainTimer: Timer?

    /// Sample rate of the samples `stopListening()` returns.
    private(set) var captureSampleRate = 48_000

    func startListening() {
        // Allow restarting from idle or from other states in a session
        state = .listening
        transcribedText = ""
        responseText = ""
        audioSamples = []
        startAudioCapture()
    }

    func stopListening() -> [Float] {
        guard state == .listening else { return [] }
        stopAudioCapture()
        let samples = audioSamples
        audioSamples = []
        return samples
    }

    func setThinking() {
        state = .thinking
    }

    func setSpeaking() {
        state = .speaking
    }

    func setIdle() {
        state = .idle
        isMuted = false
        stopAudioCapture()
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            captureSession?.stop()
        } else if state == .listening {
            // Resume capture
            let session = AudioCaptureSession()
            session.setSilenceDuration(silenceDuration)
            do {
                try session.start()
                self.captureSession = session
                captureSampleRate = session.sampleRate
            } catch {
                Self.logger.error("Failed to resume capture after unmute: \(error)")
            }
        }
    }

    // MARK: - Hotkey Configuration

    func applyHotkeyString(_ hotkey: String) {
        let parts = hotkey.lowercased().split(separator: "+").map(String.init)
        var modifiers: NSEvent.ModifierFlags = []
        var keyName = ""

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            switch trimmed {
            case "option", "alt", "⌥": modifiers.insert(.option)
            case "command", "cmd", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "control", "ctrl", "⌃": modifiers.insert(.control)
            default: keyName = trimmed
            }
        }

        if let code = Self.keyCodeMap[keyName] {
            hotkeyCode = code
            hotkeyModifiers = modifiers
        }
    }

    var hotkeyDisplayString: String {
        var parts: [String] = []
        if hotkeyModifiers.contains(.control) { parts.append("⌃") }
        if hotkeyModifiers.contains(.option) { parts.append("⌥") }
        if hotkeyModifiers.contains(.shift) { parts.append("⇧") }
        if hotkeyModifiers.contains(.command) { parts.append("⌘") }
        if let name = Self.keyCodeMap.first(where: { $0.value == hotkeyCode })?.key {
            parts.append(name.capitalized)
        }
        return parts.joined(separator: "")
    }

    // MARK: - Global Hotkey

    func registerHotkey() {
        // Idempotent: a second registration would toggle twice per press (on, off).
        unregisterHotkey()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
            return event
        }
    }

    func unregisterHotkey() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if Self.matchesHotkey(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                              hotkeyCode: hotkeyCode, hotkeyModifiers: hotkeyModifiers), event.type == .keyDown {
            // Toggle voice mode via notification
            NotificationCenter.default.post(name: .voiceToggleRequested, object: nil)
        }
    }

    /// The exact modifiers must match (⌘⌥Space is not ⌥Space), a held key's
    /// auto-repeat doesn't toggle again, and a hotkey without a modifier
    /// never fires (a bare Space would turn the assistant on while typing).
    nonisolated static func matchesHotkey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool,
        hotkeyCode: UInt16,
        hotkeyModifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard !isRepeat, keyCode == hotkeyCode, !hotkeyModifiers.intersection(relevant).isEmpty else { return false }
        return modifiers.intersection(relevant) == hotkeyModifiers.intersection(relevant)
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        let session = AudioCaptureSession()
        session.setSilenceDuration(silenceDuration)

        do {
            try session.start()
            self.captureSession = session
            captureSampleRate = session.sampleRate
            Self.logger.info("Voice capture started")
        } catch {
            Self.logger.error("Failed to start voice capture: \(error)")
            state = .idle
            return
        }

        drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let session = self.captureSession else { return }

                let (samples, rms) = session.drain()
                if !samples.isEmpty {
                    self.audioSamples.append(contentsOf: samples)
                    self.audioLevel = rms
                }

                // Check for end-of-turn silence
                if self.state == .listening && session.isSilenceDetected() {
                    self.onSilenceDetected?()
                }
            }
        }
    }

    private func stopAudioCapture() {
        drainTimer?.invalidate()
        drainTimer = nil
        if let session = captureSession {
            let (samples, _) = session.drain()
            audioSamples.append(contentsOf: samples)
            session.stop()
        }
        captureSession = nil
    }

    // MARK: - Key Code Map

    private static let keyCodeMap: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "space": 49, "`": 50,
        "delete": 51, "escape": 53, "return": 36, "tab": 48,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 94,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}

// MARK: - Notification Names

extension Notification.Name {
    static let voiceToggleRequested = Notification.Name("voiceToggleRequested")
    static let voiceInputCompleted = Notification.Name("voiceInputCompleted")
}
