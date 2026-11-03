import AVFoundation
import os

/// Microphone capture for dictation: 16 kHz mono Float32 chunks on an
/// `AsyncStream`, plus a smoothed level for the HUD meter.
///
/// Separate from meeting capture on purpose: it starts in a few tens of
/// milliseconds, writes nothing to disk and never touches system audio.
/// @unchecked Sendable: mutable state is behind `lock`; the tap closure only
/// captures the lock-protected `Shared` box, never `self`.
final class DictationAudioCapture: @unchecked Sendable {
    static let sampleRate = 16_000
    private static let logger = Logger(subsystem: "io.lidia.app", category: "DictationAudio")

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var level: Float = 0
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var framesDelivered = 0
    }

    private let shared = Shared()
    private let lock = NSLock()
    private var engine: AVAudioEngine?

    /// 0…1, smoothed, for the level meter.
    var level: Float {
        shared.lock.withLock { shared.level }
    }

    /// Seconds of audio delivered so far.
    var capturedDuration: TimeInterval {
        shared.lock.withLock { Double(shared.framesDelivered) / Double(Self.sampleRate) }
    }

    /// Starts the microphone. Audio flows into the returned stream until `stop()`.
    func start() throws -> AsyncStream<AudioChunk> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        shared.lock.withLock {
            shared.continuation = continuation
            shared.level = 0
            shared.framesDelivered = 0
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            continuation.finish()
            throw DictationError.noMicrophone
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            continuation.finish()
            throw DictationError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.makeTap(shared: shared, converter: converter, target: target))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        lock.withLock { self.engine = engine }
        return stream
    }

    /// Stops the microphone and ends the stream (the recogniser then finalizes).
    func stop() {
        let engine = lock.withLock { () -> AVAudioEngine? in
            defer { self.engine = nil }
            return self.engine
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let continuation = shared.lock.withLock { () -> AsyncStream<AudioChunk>.Continuation? in
            defer { shared.continuation = nil; shared.level = 0 }
            return shared.continuation
        }
        continuation?.finish()
    }

    /// Built outside any actor: AVAudioEngine calls it on its realtime thread.
    private static func makeTap(shared: Shared, converter: AVAudioConverter, target: AVAudioFormat) -> AVAudioNodeTapBlock {
        let ratio = target.sampleRate / converter.inputFormat.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
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
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            // Speech RMS sits around 0.02–0.2; map to 0…1 on a log-ish curve.
            let normalized = min(1, max(0, (20 * log10(max(rms, 1e-5)) + 50) / 40))
            shared.lock.lock()
            let timestamp = Double(shared.framesDelivered) / Double(DictationAudioCapture.sampleRate)
            shared.framesDelivered += samples.count
            shared.level = shared.level * 0.6 + normalized * 0.4
            let continuation = shared.continuation
            shared.lock.unlock()
            continuation?.yield(AudioChunk(samples: samples, sampleRate: DictationAudioCapture.sampleRate, timestamp: timestamp, source: .mic))
        }
    }
}

enum DictationError: LocalizedError, Equatable {
    case noMicrophone
    case microphoneDenied
    case languageUnavailable(String)
    case recognizerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        case .microphoneDenied: "LidIA can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .languageUnavailable(let language): "On-device dictation isn't available for \(language) on this Mac."
        case .recognizerFailed(let reason): reason
        }
    }
}
