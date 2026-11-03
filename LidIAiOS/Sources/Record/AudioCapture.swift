@preconcurrency import AVFoundation
import Foundation
import Synchronization
import os

/// Microphone capture: writes every buffer to disk as it arrives and hands
/// copies to the live transcriber and the level meter.
///
/// The file is CAF with AAC: CAF stays readable when the app is killed
/// mid-recording (no trailing index to write), so a crash loses seconds, not
/// the meeting. Buffers are converted to one fixed format first, so switching
/// to AirPods mid-meeting (a different sample rate) doesn't break the file.
final class AudioCapture: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.lidia.ios", category: "AudioCapture")

    /// What the file stores and the transcriber receives: 48 kHz mono float.
    static let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private let state = Mutex(State())
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private struct State {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var converterInput: AVAudioFormat?
        var paused = false
        var framesWritten: AVAudioFramePosition = 0
    }

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        self.onBuffer = onBuffer
        self.onLevel = onLevel
    }

    var secondsWritten: TimeInterval {
        Double(state.withLock { $0.framesWritten }) / Self.processingFormat.sampleRate
    }

    /// Configures the session for recording that continues with the screen locked.
    static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func start(writingTo url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        state.withLock { $0.file = file }
        try installTapAndStart()
    }

    /// Re-attaches after a route or configuration change (AirPods in or out).
    func restart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTapAndStart()
        } catch {
            Self.logger.error("Restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { $0.paused = paused }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.withLock {
            $0.file = nil // closes the file
            $0.converter = nil
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "LidIA", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        let shouldWrite = state.withLock { state -> AVAudioFile? in
            state.paused ? nil : state.file
        }
        guard let file = shouldWrite else {
            onLevel(0)
            return
        }
        do {
            try file.write(from: converted)
            state.withLock { $0.framesWritten += AVAudioFramePosition(converted.frameLength) }
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
        onBuffer(converted)
        onLevel(Self.level(of: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let output = Self.processingFormat
        let converter: AVAudioConverter? = state.withLock { state in
            if state.converterInput != buffer.format || state.converter == nil {
                state.converter = AVAudioConverter(from: buffer.format, to: output)
                state.converterInput = buffer.format
            }
            return state.converter
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// 0…1 loudness for the waveform (RMS in dB, mapped from -55 dB…-5 dB).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in stride(from: 0, to: count, by: 2) {
            sum += data[index] * data[index]
        }
        let rms = sqrt(sum / Float(max(1, count / 2)))
        let db = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (db + 55) / 50))
    }
}
