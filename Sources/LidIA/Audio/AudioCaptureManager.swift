@preconcurrency import AVFoundation
import CoreGraphics
import Observation
import os

enum AudioCaptureError: Error, LocalizedError {
    case micPermissionDenied
    case micUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
        case .micUnavailable(let detail):
            "Microphone unavailable: \(detail)"
        }
    }
}

extension AudioCaptureError {
    /// Throws when the input has no usable format. With no input device (a Mac mini or
    /// Studio with nothing plugged in, a closed laptop) the input node reports 0 Hz or 0
    /// channels, and installing a tap with that format raises an Objective-C exception,
    /// which can't be caught in Swift.
    nonisolated static func checkInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) throws {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw AudioCaptureError.micUnavailable(String(localized: "No microphone is connected or available."))
        }
    }
}

enum AudioCaptureMode: String, CaseIterable, Sendable {
    case micOnly = "Microphone Only"
    case micAndSystem = "Microphone + System Audio"
}

@Observable
@MainActor
final class AudioCaptureManager {
    enum CaptureStatus: Sendable {
        case healthy
        case warning(String)
        case fallbackToMic(String)
        case failed(String)
    }

    private static let logger = Logger(subsystem: "io.lidia.app", category: "AudioCaptureManager")

    private(set) var isCapturing = false
    private(set) var isPaused = false
    private(set) var activeCaptureMode: AudioCaptureMode = .micOnly
    private(set) var captureStatus: CaptureStatus = .healthy
    private(set) var elapsedTime: TimeInterval = 0
    private var pausedDuration: TimeInterval = 0
    private var pauseStart: Date?

    /// Consolidated audio tap state under a single lock to reduce contention
    /// on the real-time audio thread.
    struct AudioTapState: Sendable {
        var rms: Float = 0
        var micRMS: Float = 0
        var systemRMS: Float = 0
        var sourceEvents: [AudioSourceEvent] = []
        var accumulatedMicSamples: [Float] = []
        var accumulatedSystemSamples: [Float] = []
        /// While paused, captured audio is dropped (mic tap removed; system chunks skipped).
        var isPaused = false
    }

    nonisolated let tapState = OSAllocatedUnfairLock(initialState: AudioTapState())

    /// Disk recorder for the current capture, read from audio callback threads.
    nonisolated let recorderRef = OSAllocatedUnfairLock<MeetingAudioRecorder?>(initialState: nil)

    /// Called on the main actor when system audio stops being captured (permission missing,
    /// stream failure or stall) and the recording continues with the microphone only.
    var onFallbackToMic: (@MainActor (String) -> Void)?

    /// Latest RMS value from the audio tap (thread-safe read).
    nonisolated var currentRMS: Float {
        tapState.withLock { $0.rms }
    }

    private var micEngine: AVAudioEngine?
    private var systemCapture: SystemAudioCapture?
    private var systemForwardTask: Task<Void, Never>?
    private var rmsForwardTask: Task<Void, Never>?
    private var timer: Timer?
    private var healthTask: Task<Void, Never>?
    private var startTime: Date?

    /// Whether to accumulate resampled samples for batch post-processing.
    /// Only needed for WhisperKit batch mode; streaming engines (Parakeet, AppleSpeech)
    /// consume chunks directly from the stream.
    var shouldAccumulate = true

    private var _audioStream: AsyncStream<AudioChunk>?
    private var _continuation: AsyncStream<AudioChunk>.Continuation?

    var audioStream: AsyncStream<AudioChunk> {
        guard let stream = _audioStream else {
            return AsyncStream { $0.finish() }
        }
        return stream
    }

    /// Starts capturing. When a `recorder` is given, every captured chunk is also written to
    /// disk and samples are not accumulated in memory.
    func startCapture(mode: AudioCaptureMode = .micOnly, recorder: MeetingAudioRecorder? = nil) async throws {
        guard !isCapturing else { return }
        captureStatus = .healthy
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        _audioStream = stream
        _continuation = continuation
        recorderRef.withLock { $0 = recorder }
        shouldAccumulate = recorder == nil
        tapState.withLock { $0.isPaused = false }

        do {
            switch mode {
            case .micOnly:
                try await startMicOnlyCapture()
                activeCaptureMode = .micOnly
            case .micAndSystem:
                if let reason = Self.systemAudioUnavailableReason() {
                    // Don't let a missing permission become a silent failure: record the mic
                    // and say why the other side isn't being captured.
                    Self.logger.warning("System audio unavailable: \(reason)")
                    try await startMicOnlyCapture()
                    activeCaptureMode = .micOnly
                    reportFallback(reason)
                } else {
                    do {
                        try await startSystemAudioCapture()
                        activeCaptureMode = .micAndSystem
                    } catch {
                        Self.logger.warning("System audio capture failed, falling back to mic only: \(error.localizedDescription)")
                        try await startMicOnlyCapture()
                        activeCaptureMode = .micOnly
                        reportFallback("System audio couldn't start (\(error.localizedDescription)). Recording your microphone only.")
                    }
                }
            }
        } catch {
            recorderRef.withLock { $0 = nil }
            _continuation?.finish()
            _continuation = nil
            _audioStream = nil
            throw error
        }

        isCapturing = true
        isPaused = false
        pausedDuration = 0
        pauseStart = nil
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                let total = Date().timeIntervalSince(start)
                let currentPause = self.isPaused ? Date().timeIntervalSince(self.pauseStart ?? Date()) : 0
                self.elapsedTime = total - self.pausedDuration - currentPause
            }
        }

        if activeCaptureMode == .micAndSystem {
            startHealthWatchdog()
        }
    }

    nonisolated func drainAccumulatedMicSamples() -> [Float] {
        tapState.withLock { state in
            let drained = state.accumulatedMicSamples
            state.accumulatedMicSamples.removeAll(keepingCapacity: false)
            return drained
        }
    }

    nonisolated func drainAccumulatedSystemSamples() -> [Float] {
        tapState.withLock { state in
            let drained = state.accumulatedSystemSamples
            state.accumulatedSystemSamples.removeAll(keepingCapacity: false)
            return drained
        }
    }

    nonisolated func drainSourceEvents() -> [AudioSourceEvent] {
        tapState.withLock { state in
            let drained = state.sourceEvents
            state.sourceEvents.removeAll(keepingCapacity: true)
            return drained
        }
    }

    /// Returns the latest per-source RMS values (mic and system independently).
    nonisolated func recentPerSourceRMS() -> CaptureService.PerSourceRMS {
        tapState.withLock { state in
            CaptureService.PerSourceRMS(mic: state.micRMS, system: state.systemRMS)
        }
    }

    func pauseCapture() {
        guard isCapturing, !isPaused else { return }
        isPaused = true
        pauseStart = Date()

        // Mute the tap — remove tap so no audio flows. System audio keeps arriving from
        // ScreenCaptureKit, so it is dropped via the paused flag instead.
        micEngine?.inputNode.removeTap(onBus: 0)
        tapState.withLock {
            $0.rms = 0
            $0.isPaused = true
        }
        recorderRef.withLock { $0 }?.pause()
    }

    func resumeCapture() {
        guard isCapturing, isPaused else { return }
        if let start = pauseStart {
            pausedDuration += Date().timeIntervalSince(start)
        }
        isPaused = false
        pauseStart = nil
        recorderRef.withLock { $0 }?.resume()
        tapState.withLock { $0.isPaused = false }

        // Re-install the tap if mic engine is active. Remove any tap first: the system
        // audio watchdog can switch to the mic (installing a tap) while paused, and a
        // second tap on the same bus raises an Objective-C exception.
        if let engine = micEngine, let continuation = _continuation {
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: nil,
                block: Self.makeMicTapBlock(
                    continuation: continuation,
                    tapState: tapState,
                    recorderRef: recorderRef,
                    shouldAccumulate: shouldAccumulate
                )
            )
        }
    }

    func stopCapture() {
        // Stop mic engine if active
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        // Stop system audio capture if active
        if let systemCapture {
            Task { await systemCapture.stopCapture() }
            self.systemCapture = nil
        }
        systemForwardTask?.cancel()
        systemForwardTask = nil
        rmsForwardTask?.cancel()
        rmsForwardTask = nil

        timer?.invalidate()
        timer = nil
        healthTask?.cancel()
        healthTask = nil

        isCapturing = false
        isPaused = false
        recorderRef.withLock { $0 = nil }
        tapState.withLock { state in
            state.rms = 0
            state.micRMS = 0
            state.systemRMS = 0
            state.accumulatedMicSamples.removeAll(keepingCapacity: false)
            state.accumulatedSystemSamples.removeAll(keepingCapacity: false)
            state.sourceEvents.removeAll()
            state.isPaused = false
        }
        _continuation?.finish()
        _continuation = nil
        _audioStream = nil
    }

    // MARK: - Mic-Only Capture (AVAudioEngine)

    private func startMicOnlyCapture() async throws {
        try await checkMicPermission()
        guard let continuation = _continuation else {
            throw AudioCaptureError.micUnavailable("Audio stream not initialized")
        }

        let engine = try Self.setupMicEngine(
            continuation: continuation,
            tapState: tapState,
            recorderRef: recorderRef,
            shouldAccumulate: shouldAccumulate
        )
        micEngine = engine
    }

    // MARK: - System Audio + Mic Capture (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let capture = SystemAudioCapture()
        capture.tapStateRef = tapState
        capture.shouldAccumulate = shouldAccumulate
        let sourceStream = try await capture.startCapture(includeMic: true)
        systemCapture = capture
        captureStatus = .healthy
        systemForwardTask?.cancel()
        guard let continuation = _continuation else {
            throw AudioCaptureError.micUnavailable("Audio stream not initialized")
        }
        let state = tapState
        let recorderRef = recorderRef
        systemForwardTask = Task {
            for await chunk in sourceStream {
                if Task.isCancelled { break }
                if state.withLock({ $0.isPaused }) { continue }
                recorderRef.withLock { $0 }?.append(chunk)
                continuation.yield(chunk)
                let rms = AudioChunk.computeRMS(chunk.samples)
                state.withLock { s in
                    switch chunk.source {
                    case .mic: s.micRMS = rms
                    case .system: s.systemRMS = rms
                    case .unknown: break
                    }
                    s.sourceEvents.append(AudioSourceEvent(source: chunk.source, timestamp: chunk.timestamp, rms: rms))
                }
            }
        }

        // Forward RMS from system capture
        rmsForwardTask?.cancel()
        let captureRef = capture
        rmsForwardTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let rms = captureRef.currentRMS
                // Note: System audio capture updates per-source RMS in the chunk handler above.
                // This forward task only updates the combined RMS for the general quality indicator.
                state.withLock { $0.rms = rms }
            }
        }
    }

    private func startHealthWatchdog() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            guard let self else { return }
            var restartAttempted = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.isCapturing else { continue }
                guard let systemCapture = self.systemCapture else { continue }

                if systemCapture.secondsSinceLastSample > 4 {
                    if !restartAttempted {
                        restartAttempted = true
                        self.captureStatus = .warning("System audio stream stalled, retrying…")
                        Self.logger.warning("System audio stream stalled; attempting restart")
                        do {
                            try await self.restartSystemCapture()
                            self.captureStatus = .healthy
                            restartAttempted = false
                            continue
                        } catch {
                            Self.logger.error("System audio restart failed: \(error.localizedDescription)")
                        }
                    }

                    do {
                        try await self.fallbackToMicOnly()
                        self.reportFallback("System audio stopped responding. Recording your microphone only.")
                        return
                    } catch {
                        self.captureStatus = .failed("Audio capture failed: \(error.localizedDescription)")
                        return
                    }
                }
            }
        }
    }

    private func restartSystemCapture() async throws {
        guard isCapturing else { return }
        if let systemCapture {
            await systemCapture.stopCapture()
        }
        systemForwardTask?.cancel()
        systemForwardTask = nil
        rmsForwardTask?.cancel()
        rmsForwardTask = nil
        try await startSystemAudioCapture()
    }

    private func fallbackToMicOnly() async throws {
        guard isCapturing else { return }

        if let systemCapture {
            await systemCapture.stopCapture()
            self.systemCapture = nil
        }
        rmsForwardTask?.cancel()
        rmsForwardTask = nil

        try await checkMicPermission()
        guard let continuation = _continuation else {
            throw AudioCaptureError.micUnavailable("Audio stream not initialized")
        }
        let engine = try Self.setupMicEngine(
            continuation: continuation,
            tapState: tapState,
            recorderRef: recorderRef,
            shouldAccumulate: shouldAccumulate
        )
        micEngine = engine
        activeCaptureMode = .micOnly
    }

    private func reportFallback(_ reason: String) {
        captureStatus = .fallbackToMic(reason)
        onFallbackToMic?(reason)
    }

    /// Why system audio can't be captured right now, or nil if it should work.
    /// Asks for Screen Recording access once if it was never granted (non-blocking).
    private static func systemAudioUnavailableReason() -> String? {
        if CGPreflightScreenCaptureAccess() { return nil }
        _ = CGRequestScreenCaptureAccess()
        return "Screen Recording permission is off, so other participants aren't being captured. "
            + "Recording your microphone only. Turn on LidIA in System Settings > Privacy & Security > Screen & System Audio Recording."
    }

    // MARK: - Mic Permission

    private func checkMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            throw AudioCaptureError.micPermissionDenied
        }
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw AudioCaptureError.micPermissionDenied
            }
        }
    }

    // MARK: - Engine Setup (off main actor)

    /// Setup and start the AVAudioEngine off the main actor.
    /// AVAudioEngine has internal dispatch queue requirements that
    /// conflict with running on the main thread.
    private nonisolated static func setupMicEngine(
        continuation: AsyncStream<AudioChunk>.Continuation,
        tapState: OSAllocatedUnfairLock<AudioTapState>,
        recorderRef: OSAllocatedUnfairLock<MeetingAudioRecorder?>,
        shouldAccumulate: Bool
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        try AudioCaptureError.checkInputFormat(
            sampleRate: hardwareFormat.sampleRate,
            channelCount: hardwareFormat.channelCount
        )

        // Use nil format to accept the hardware's native format.
        // installTap cannot resample — must match hardware.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil,
            block: makeMicTapBlock(
                continuation: continuation,
                tapState: tapState,
                recorderRef: recorderRef,
                shouldAccumulate: shouldAccumulate
            )
        )

        engine.prepare()
        try engine.start()
        return engine
    }

    /// The mic tap: forwards each buffer to the live stream, the disk recorder and the meters.
    private nonisolated static func makeMicTapBlock(
        continuation: AsyncStream<AudioChunk>.Continuation,
        tapState: OSAllocatedUnfairLock<AudioTapState>,
        recorderRef: OSAllocatedUnfairLock<MeetingAudioRecorder?>,
        shouldAccumulate: Bool
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channelData = buffer.floatChannelData,
                  buffer.frameLength > 0 else { return }

            let sampleRate = Int(buffer.format.sampleRate)
            let samples = Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(buffer.frameLength)
                )
            )
            let chunk = AudioChunk(
                samples: samples,
                sampleRate: sampleRate,
                timestamp: Date().timeIntervalSince1970,
                source: .mic
            )
            let rms = AudioChunk.computeRMS(samples)
            // Single lock acquisition for RMS + source events + optional accumulation
            let paused = tapState.withLock { state -> Bool in
                guard !state.isPaused else { return true }
                state.rms = rms
                state.micRMS = rms
                state.sourceEvents.append(AudioSourceEvent(source: .mic, timestamp: chunk.timestamp, rms: rms))
                if shouldAccumulate {
                    let resampled = AudioResampler.resample(samples, from: sampleRate, to: 16000)
                    state.accumulatedMicSamples.append(contentsOf: resampled)
                }
                return false
            }
            guard !paused else { return }
            recorderRef.withLock { $0 }?.append(chunk)
            continuation.yield(chunk)
        }
    }
}
