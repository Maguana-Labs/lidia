import AVFoundation
import Foundation
import os

/// Which voice pipeline the assistant runs.
enum VoiceAssistantBackend: Equatable, Sendable {
    case localPipeline
    case openAIRealtime
    /// Grok's realtime voice (xAI), with the user's own xAI key.
    case xAIRealtime

    /// OpenAI Realtime streams mic audio, SOUL.md and meeting answers to
    /// OpenAI, so Local-only mode always forces the local pipeline.
    static func resolve(ttsProvider: AppSettings.TTSProvider, openAIAPIKey: String, localOnly: Bool) -> Self {
        guard !localOnly else { return .localPipeline }
        let hasOpenAIKey = !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Only use OpenAI Realtime when explicitly selected with a valid key
        if ttsProvider == .openai, hasOpenAIKey {
            return .openAIRealtime
        }
        return .localPipeline
    }

    /// Adds the Grok choice. Local-only mode wins over everything.
    static func resolve(
        ttsProvider: AppSettings.TTSProvider,
        openAIAPIKey: String,
        grokEnabled: Bool,
        xAIAPIKey: String,
        localOnly: Bool
    ) -> Self {
        guard !localOnly else { return .localPipeline }
        if grokEnabled, !xAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .xAIRealtime
        }
        return resolve(ttsProvider: ttsProvider, openAIAPIKey: openAIAPIKey, localOnly: localOnly)
    }
}

/// Which voice reads answers aloud in the local pipeline.
enum VoiceTTSChoice: Equatable, Sendable {
    case mlx(modelID: String)
    /// Sends the spoken answer (built from meeting data) to OpenAI.
    case openAI
    case system

    /// - Parameter mlxModelID: the downloaded MLX voice to use, if any.
    /// In Local-only mode OpenAI is never chosen: MLX if downloaded, else the
    /// system voice.
    static func resolve(
        provider: AppSettings.TTSProvider,
        hasOpenAIKey: Bool,
        mlxModelID: String?,
        localOnly: Bool
    ) -> VoiceTTSChoice {
        let local: VoiceTTSChoice = mlxModelID.map { .mlx(modelID: $0) } ?? .system
        switch provider {
        case .mlx:
            return local
        case .system:
            return .system
        case .openai:
            if localOnly { return local }
            return hasOpenAIKey ? .openAI : .system
        case .automatic:
            // Cascade: MLX (if downloaded) → OpenAI (if key, not Local-only) → System
            if let mlxModelID { return .mlx(modelID: mlxModelID) }
            return hasOpenAIKey && !localOnly ? .openAI : .system
        }
    }
}

/// A speech-to-speech service that speaks the OpenAI Realtime protocol.
///
/// - OpenAI: the GA Realtime API (`gpt-realtime-2.1`). The beta interface
///   (`OpenAI-Beta: realtime=v1`, `gpt-4o-realtime-preview`) this client used
///   before was shut down in May 2026.
/// - xAI: the Grok Voice Agent API, an OpenAI Realtime clone
///   (docs.x.ai/docs/guides/voice/agent).
enum RealtimeVoiceProvider: String, Sendable, CaseIterable {
    case openAI
    case xAI

    var displayName: String {
        switch self {
        case .openAI: "OpenAI voice"
        case .xAI: "Grok voice"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-realtime-2.1"
        case .xAI: "grok-voice-latest"
        }
    }

    /// Without the query; what the privacy gate checks.
    var endpoint: URL {
        switch self {
        case .openAI: URL(string: "wss://api.openai.com/v1/realtime")!
        case .xAI: URL(string: "wss://api.x.ai/v1/realtime")!
        }
    }

    func url(model: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    /// Voices the realtime model accepts. OpenAI's text-to-speech voices
    /// (nova, fable, onyx) don't exist in Realtime.
    var voices: [String] {
        switch self {
        case .openAI: ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        case .xAI: ["eve", "ara", "leo", "rex", "sal"]
        }
    }

    /// `requested` if this service has it, else its default voice.
    func voice(for requested: String) -> String {
        let lowered = requested.lowercased()
        return voices.contains(lowered) ? lowered : voices[0]
    }

    /// A `session.update` that only replaces the instructions.
    func instructionsUpdate(_ instructions: String) -> [String: Any] {
        switch self {
        case .openAI:
            ["type": "session.update", "session": ["type": "realtime", "instructions": instructions]]
        case .xAI:
            ["type": "session.update", "session": ["instructions": instructions]]
        }
    }

    /// The `session.update` event for a turn-by-turn (push-to-talk) session.
    func sessionUpdate(instructions: String, voice: String) -> [String: Any] {
        let pcm: [String: Any] = ["type": "audio/pcm", "rate": RealtimeVoiceClient.audioSampleRate]
        switch self {
        case .openAI:
            return [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "instructions": instructions,
                    "output_modalities": ["audio"],
                    "audio": [
                        "input": [
                            "format": pcm,
                            "transcription": ["model": "gpt-4o-mini-transcribe"],
                            "turn_detection": NSNull(),
                        ],
                        "output": [
                            "format": pcm,
                            "voice": self.voice(for: voice),
                        ],
                    ],
                ] as [String: Any],
            ]
        case .xAI:
            return [
                "type": "session.update",
                "session": [
                    "instructions": instructions,
                    "voice": self.voice(for: voice),
                    "turn_detection": NSNull(),
                    "audio": [
                        "input": [
                            "format": pcm,
                            "transcription": ["model": "grok-transcribe"],
                        ],
                        "output": ["format": pcm],
                    ],
                ] as [String: Any],
            ]
        }
    }
}

enum RealtimeVoiceError: LocalizedError, Sendable {
    case missingSocket
    case apiError(String)
    case invalidAudioPayload
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingSocket:
            return "Realtime voice socket is not connected."
        case .apiError(let message):
            return "Realtime voice error: \(message)"
        case .invalidAudioPayload:
            return "The voice service returned invalid audio data."
        case .timedOut:
            return "The voice service didn't answer in time."
        }
    }
}

actor RealtimeVoiceClient {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "RealtimeVoice")

    static let defaultModel = RealtimeVoiceProvider.openAI.defaultModel
    static let audioSampleRate = 24_000
    static var endpoint: URL { RealtimeVoiceProvider.openAI.endpoint }

    enum ServerEvent: Equatable, Sendable {
        case audioDelta(Data)
        case textDelta(String)
        case audioTranscriptDelta(String)
        /// The user's words. `isFinal` is false for xAI's cumulative updates.
        case inputTranscript(String, isFinal: Bool)
        case responseDone
        case sessionUpdated
        case other(String)
        case error(String)
    }

    struct Response: Sendable {
        let transcript: String
        let text: String
        let audioPCM16: Data

        var wavAudioData: Data? {
            guard !audioPCM16.isEmpty else { return nil }
            return Self.wrapPCM16AsWAV(audioPCM16, sampleRate: RealtimeVoiceClient.audioSampleRate)
        }

        private static func wrapPCM16AsWAV(_ pcm16: Data, sampleRate: Int) -> Data {
            let channelCount: UInt16 = 1
            let bitsPerSample: UInt16 = 16
            let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
            let blockAlign = channelCount * (bitsPerSample / 8)
            let chunkSize = 36 + UInt32(pcm16.count)
            let subchunkSize = UInt32(pcm16.count)

            var data = Data()
            data.append("RIFF".data(using: .ascii)!)
            data.append(Self.littleEndianBytes(chunkSize))
            data.append("WAVE".data(using: .ascii)!)
            data.append("fmt ".data(using: .ascii)!)
            data.append(Self.littleEndianBytes(UInt32(16)))
            data.append(Self.littleEndianBytes(UInt16(1)))
            data.append(Self.littleEndianBytes(channelCount))
            data.append(Self.littleEndianBytes(UInt32(sampleRate)))
            data.append(Self.littleEndianBytes(byteRate))
            data.append(Self.littleEndianBytes(blockAlign))
            data.append(Self.littleEndianBytes(bitsPerSample))
            data.append("data".data(using: .ascii)!)
            data.append(Self.littleEndianBytes(subchunkSize))
            data.append(pcm16)
            return data
        }

        private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
            var littleEndian = value.littleEndian
            return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
        }
    }

    private let apiKey: String
    private let provider: RealtimeVoiceProvider
    private let model: String
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    /// Events received but not yet consumed.
    private var buffered: [ServerEvent] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<ServerEvent?, Never>)?
    private var nextWaiterID = 0

    init(apiKey: String, provider: RealtimeVoiceProvider = .openAI, model: String? = nil, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.urlSession = urlSession
    }

    func disconnect() {
        pump?.cancel()
        pump = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        buffered = []
        resumeWaiter(with: nil)
    }

    /// Sends the user's audio and returns what they said. Waits at most a few
    /// seconds for the transcript; an empty string means none arrived.
    func completeTurn(
        samples: [Float],
        sourceSampleRate: Int,
        voice: String,
        instructions: String
    ) async throws -> String {
        try checkPrivacy()
        try connectIfNeeded()
        buffered = []
        try await sendEvent(provider.sessionUpdate(instructions: instructions, voice: voice))
        try await sendInputAudio(samples: samples, sourceSampleRate: sourceSampleRate)
        try await sendEvent(["type": "input_audio_buffer.commit"])
        return try await awaitInputTranscript()
    }

    /// Asks for the spoken answer, with `instructions` updated for this turn
    /// (for example with meeting context found from the transcript).
    func generateResponse(
        for transcript: String,
        voice: String,
        instructions: String
    ) async throws -> Response {
        try checkPrivacy()
        try connectIfNeeded()
        // Instructions only: the voice can't change once the session has spoken.
        try await sendEvent(provider.instructionsUpdate(instructions))
        try await sendEvent(["type": "response.create"])
        return try await awaitResponse(transcript: transcript)
    }

    /// Send-time backstop: in Local-only mode close any open socket and send
    /// nothing, even if this session started before the mode was turned on.
    private func checkPrivacy() throws {
        guard PrivacyGate.allowsAIEndpoint(provider.endpoint) else {
            disconnect()
            throw LLMError.cloudBlocked(
                provider: provider.displayName,
                reason: "Local-only mode is on, so your voice and meeting data stay on this Mac."
            )
        }
    }

    private func connectIfNeeded() throws {
        guard webSocketTask == nil else { return }
        var request = URLRequest(url: provider.url(model: model))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        task.resume()
        webSocketTask = task
        pump = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .data(let payload): data = payload
                    case .string(let payload): data = Data(payload.utf8)
                    @unknown default: continue
                    }
                    if let event = Self.parseServerEvent(from: data) {
                        await self?.deliver(event)
                    }
                } catch {
                    await self?.deliver(.error(error.localizedDescription))
                    await self?.socketClosed(task)
                    return
                }
            }
        }
    }

    private func socketClosed(_ task: URLSessionWebSocketTask) {
        if webSocketTask === task {
            webSocketTask = nil
            pump = nil
        }
    }

    private func deliver(_ event: ServerEvent) {
        if case .other(let type) = event {
            Self.logger.debug("Ignoring realtime event: \(type, privacy: .public)")
            return
        }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
        } else {
            buffered.append(event)
        }
    }

    private func resumeWaiter(with event: ServerEvent?) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: event)
    }

    /// The next event, or nil after `timeout`.
    private func nextEvent(timeout: Duration) async -> ServerEvent? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        nextWaiterID += 1
        let id = nextWaiterID
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireWaiter(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            waiter = (id, continuation)
        }
    }

    private func expireWaiter(_ id: Int) {
        guard waiter?.id == id else { return }
        resumeWaiter(with: nil)
    }

    private func awaitInputTranscript() async throws -> String {
        var latest = ""
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            // xAI only sends cumulative updates: a short quiet spell after one means done.
            let wait: Duration = latest.isEmpty ? deadline - ContinuousClock.now : .milliseconds(700)
            guard let event = await nextEvent(timeout: wait) else { return latest }
            switch event {
            case .inputTranscript(let transcript, let isFinal):
                latest = transcript
                if isFinal { return transcript }
            case .error(let message):
                throw RealtimeVoiceError.apiError(message)
            default:
                continue
            }
        }
        return latest
    }

    private func awaitResponse(transcript: String) async throws -> Response {
        var text = ""
        var audio = Data()
        var sawTextDelta = false

        while true {
            guard let event = await nextEvent(timeout: .seconds(30)) else {
                throw RealtimeVoiceError.timedOut
            }
            switch event {
            case .textDelta(let delta):
                sawTextDelta = true
                text += delta
            case .audioTranscriptDelta(let delta):
                guard !sawTextDelta else { continue }
                text += delta
            case .audioDelta(let delta):
                audio.append(delta)
            case .responseDone:
                return Response(transcript: transcript, text: text, audioPCM16: audio)
            case .error(let message):
                throw RealtimeVoiceError.apiError(message)
            default:
                continue
            }
        }
    }

    private func sendInputAudio(samples: [Float], sourceSampleRate: Int) async throws {
        let bytesPerChunk = 4_096 * MemoryLayout<Int16>.size
        let event = Self.inputAudioAppendEvent(samples: samples, sourceSampleRate: sourceSampleRate)
        guard let payload = event["audio"] as? String,
              let data = Data(base64Encoded: payload)
        else {
            throw RealtimeVoiceError.invalidAudioPayload
        }

        if data.isEmpty {
            try await sendEvent(event)
            return
        }

        for start in stride(from: 0, to: data.count, by: bytesPerChunk) {
            let end = min(start + bytesPerChunk, data.count)
            let chunk = data.subdata(in: start..<end)
            try await sendEvent([
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString()
            ])
        }
    }

    private func sendEvent(_ event: [String: Any]) async throws {
        guard let webSocketTask else { throw RealtimeVoiceError.missingSocket }
        let data = try JSONSerialization.data(withJSONObject: event)
        let text = String(decoding: data, as: UTF8.self)
        try await webSocketTask.send(.string(text))
    }

    nonisolated static func inputAudioAppendEvent(samples: [Float], sourceSampleRate: Int) -> [String: Any] {
        let normalizedSamples: [Float]
        if sourceSampleRate == audioSampleRate {
            normalizedSamples = samples
        } else {
            normalizedSamples = AudioResampler.resample(samples, from: sourceSampleRate, to: audioSampleRate)
        }

        let pcm16 = pcm16Data(from: normalizedSamples)
        return [
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ]
    }

    /// Parses GA (`response.output_audio.delta`), beta (`response.audio.delta`)
    /// and xAI event names.
    nonisolated static func parseServerEvent(from data: Data) -> ServerEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return nil
        }

        switch type {
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = json["delta"] as? String,
                  let decoded = Data(base64Encoded: delta)
            else { return nil }
            return .audioDelta(decoded)
        case "response.output_text.delta", "response.text.delta":
            guard let delta = json["delta"] as? String else { return nil }
            return .textDelta(delta)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = json["delta"] as? String else { return nil }
            return .audioTranscriptDelta(delta)
        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.updated":
            let isFinal = type.hasSuffix(".completed")
            if let transcript = json["transcript"] as? String {
                return .inputTranscript(transcript, isFinal: isFinal)
            }
            if let item = json["item"] as? [String: Any],
               let transcript = item["transcript"] as? String {
                return .inputTranscript(transcript, isFinal: isFinal)
            }
            return nil
        case "response.done", "response.completed":
            return .responseDone
        case "session.updated":
            return .sessionUpdated
        case "error":
            let message: String
            if let error = json["error"] as? [String: Any] {
                message = error["message"] as? String ?? "Unknown error"
            } else {
                message = json["message"] as? String ?? "Unknown error"
            }
            return .error(message)
        default:
            return .other(type)
        }
    }

    private nonisolated static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = clamped == -1
                ? Int16.min
                : Int16((clamped * Float(Int16.max)).rounded())
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}

actor RealtimeAudioPlayer {
    private var audioPlayer: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    /// Which `play` call the pending continuation belongs to, so a late "finished"
    /// from an earlier clip can't end the next one.
    private var playback = 0

    func play(wavData: Data) async throws {
        let player = try AVAudioPlayer(data: wavData)
        audioPlayer = player
        playback += 1
        let thisPlayback = playback
        player.prepareToPlay()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            // Finishing and stop() both resume through `finishPlayback()` on this actor,
            // which resumes the continuation once. Resuming it from the delegate directly
            // raced a stop() arriving as the audio ended, and a second resume traps.
            let delegate = AudioPlayerDelegate { [weak self] in
                Task { await self?.finishPlayback(thisPlayback) }
            }
            player.delegate = delegate
            objc_setAssociatedObject(player, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            player.play()
        }

        audioPlayer = nil
    }

    nonisolated func stop() {
        Task { await stopInternal() }
    }

    private func stopInternal() {
        audioPlayer?.stop()
        audioPlayer = nil
        finishPlayback()
    }

    private func finishPlayback(_ finished: Int? = nil) {
        if let finished, finished != playback { return }
        continuation?.resume()
        continuation = nil
    }
}

/// AVAudioPlayerDelegate bridge. @unchecked Sendable is safe because:
/// - Only stored property is an immutable `let` closure
/// - NSObject base class prevents compiler-synthesized Sendable conformance
private final class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
