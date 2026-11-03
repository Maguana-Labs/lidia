import AVFoundation
import Foundation
import os
import Speech
import Synchronization

final class AppleSpeechEngine: STTEngine, STTFailureReporting {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "AppleSpeechEngine")
    private let locale: Locale
    private let failureReasonMutex = Mutex<String?>(nil)

    var failureReason: String? {
        failureReasonMutex.withLock { $0 }
    }

    private func fail(_ reason: String) {
        failureReasonMutex.withLock { $0 = reason }
    }

    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Whether this Mac can recognise `locale` without sending audio to Apple.
    static func supportsOnDeviceRecognition(for locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// Whether Apple Speech can take over live transcription on its own: on-device for
    /// `locale` and not refused permission (an undecided permission is asked when used).
    static func isOnDeviceFallbackAvailable(for locale: Locale) -> Bool {
        isUsableFallback(
            authorization: SFSpeechRecognizer.authorizationStatus(),
            supportsOnDevice: supportsOnDeviceRecognition(for: locale)
        )
    }

    static func isUsableFallback(authorization: SFSpeechRecognizerAuthorizationStatus, supportsOnDevice: Bool) -> Bool {
        guard supportsOnDevice else { return false }
        switch authorization {
        case .authorized, .notDetermined: return true
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    /// Configures a request to stay on the device whenever the recogniser supports it.
    /// Returns whether recognition is on-device.
    @discardableResult
    static func configurePrivacy(of request: SFSpeechRecognitionRequest, supportsOnDevice: Bool) -> Bool {
        request.requiresOnDeviceRecognition = supportsOnDevice
        return supportsOnDevice
    }

    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        AsyncStream { continuation in
            Task { @Sendable in
                // Request speech recognition authorization
                let authStatus = await withCheckedContinuation { cont in
                    SFSpeechRecognizer.requestAuthorization { status in
                        cont.resume(returning: status)
                    }
                }
                guard authStatus == .authorized else {
                    Self.logger.error("Speech recognition not authorized: \(authStatus.rawValue)")
                    self.fail("Speech Recognition permission is off for LidIA in System Settings > Privacy & Security > Speech Recognition")
                    continuation.finish()
                    return
                }

                guard let recognizer = SFSpeechRecognizer(locale: self.locale),
                      recognizer.isAvailable else {
                    Self.logger.error("SFSpeechRecognizer unavailable for locale: \(self.locale)")
                    self.fail("Apple Speech isn't available for \(self.locale.identifier)")
                    continuation.finish()
                    return
                }

                // Local-only mode: never fall back to Apple's servers.
                if PrivacyGate.isLocalOnly && !recognizer.supportsOnDeviceRecognition {
                    Self.logger.error("Apple Speech: on-device recognition unavailable for \(self.locale.identifier) and Local-only mode is on; not transcribing")
                    self.fail("on-device recognition isn't available for \(self.locale.identifier) and Local-only mode is on")
                    continuation.finish()
                    return
                }

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                // Keep meeting audio on the Mac. On-device recognition also has no
                // one-minute limit, which server recognition has.
                if Self.configurePrivacy(of: request, supportsOnDevice: recognizer.supportsOnDeviceRecognition) {
                    Self.logger.info("Apple Speech: on-device recognition for \(self.locale.identifier)")
                } else {
                    Self.logger.warning("Apple Speech: on-device recognition unavailable for \(self.locale.identifier); audio will be sent to Apple")
                }

                // Signalled when recognition ends (final result or error).
                let (doneStream, doneContinuation) = AsyncStream.makeStream(of: Void.self)

                let lastWordCount = Mutex(0)
                var chunkCount = 0
                var fedSeconds: TimeInterval = 0
                var cachedFormat: AVAudioFormat?

                let task = recognizer.recognitionTask(with: request) { result, error in
                    guard let result else {
                        if let error {
                            AppleSpeechEngine.logger.error("Recognition error: \(error.localizedDescription)")
                            doneContinuation.finish()
                        }
                        return
                    }

                    let segments = result.bestTranscription.segments
                    let currentCount = lastWordCount.withLock { value in
                        let prev = value
                        value = segments.count
                        return prev
                    }
                    let newSegments = segments.dropFirst(currentCount)

                    for segment in newSegments {
                        let word = TranscriptWord(
                            word: segment.substring,
                            start: segment.timestamp,
                            end: segment.timestamp + segment.duration,
                            confidence: Double(segment.confidence),
                            speaker: nil
                        )
                        continuation.yield(word)
                    }

                    if result.isFinal {
                        doneContinuation.finish()
                    }
                }

                for await chunk in audioStream {
                    // Create or reuse format matching the chunk's sample rate
                    if cachedFormat == nil || Int(cachedFormat!.sampleRate) != chunk.sampleRate {
                        cachedFormat = AVAudioFormat(
                            commonFormat: .pcmFormatFloat32,
                            sampleRate: Double(chunk.sampleRate),
                            channels: 1,
                            interleaved: false
                        )
                        Self.logger.info("Audio format: \(chunk.sampleRate)Hz, mono, Float32")
                    }

                    guard let format = cachedFormat else { continue }

                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(chunk.samples.count)
                    ) else { continue }

                    buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
                    chunk.samples.withUnsafeBufferPointer { src in
                        buffer.floatChannelData![0]
                            .update(from: src.baseAddress!, count: src.count)
                    }

                    // Log audio level periodically
                    chunkCount += 1
                    if chunkCount % 50 == 1 {
                        let rms = sqrt(
                            chunk.samples.reduce(0.0) { $0 + $1 * $1 }
                                / max(Float(chunk.samples.count), 1)
                        )
                        Self.logger.debug("Chunk #\(chunkCount): \(chunk.samples.count) samples, RMS=\(String(format: "%.4f", rms))")
                    }

                    request.append(buffer)
                    fedSeconds += chunk.duration
                }

                Self.logger.info("Audio stream ended, finalizing recognition...")
                request.endAudio()
                // Wait for the final result instead of a fixed delay, so the last words
                // (or a whole recording fed at once) aren't cut off. The timeout only
                // matters if the recogniser never reports back.
                let timeout = 10 + fedSeconds / 4
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in doneStream {} }
                    group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
                    await group.next()
                    group.cancelAll()
                }
                task.cancel()
                continuation.finish()
            }
        }
    }
}
