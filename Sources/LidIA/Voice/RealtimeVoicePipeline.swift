import Foundation
import Synchronization
import os

/// VoicePipeline over a realtime speech-to-speech service (OpenAI or Grok):
/// the user's audio goes up, the transcript comes back, meeting context found
/// from that transcript is added to the instructions, then the spoken answer
/// streams down. No tool execution: text and audio arrive together (D2).
/// @unchecked Sendable is safe: `client` and `voice` are immutable,
/// `currentTask` is protected by a Mutex.
final class RealtimeVoicePipeline: VoicePipeline, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "RealtimeVoicePipeline")

    private let client: RealtimeVoiceClient
    private let voice: String
    private let currentTaskMutex = Mutex<Task<Void, Never>?>(nil)

    init(apiKey: String, provider: RealtimeVoiceProvider = .openAI, voice: String = "marin") {
        self.client = RealtimeVoiceClient(apiKey: apiKey, provider: provider)
        self.voice = provider.voice(for: voice)
    }

    func process(turn: VoiceTurnInput) -> AsyncStream<VoicePipelineEvent> {
        AsyncStream { continuation in
            let task = Task { [client, voice] in
                do {
                    // 1. Send audio and get transcript
                    let transcript = try await client.completeTurn(
                        samples: turn.audioSamples,
                        sourceSampleRate: turn.sampleRate,
                        voice: voice,
                        instructions: turn.baseSystemPrompt
                    )
                    continuation.yield(.transcribed(transcript))

                    try Task.checkCancellation()

                    // 2. Meeting context for what was asked (same as the local pipeline).
                    let enriched = transcript.isEmpty ? "" : await turn.contextProvider(transcript)

                    // 3. Generate response (text + audio together)
                    let result = try await client.generateResponse(
                        for: transcript,
                        voice: voice,
                        instructions: enriched.isEmpty ? turn.baseSystemPrompt : enriched
                    )

                    // 4. Yield response text (no tool stripping — D2)
                    continuation.yield(.responseComplete(result.text))

                    // 5. Yield audio if available
                    if let wavData = result.wavAudioData {
                        continuation.yield(.audioReady(wavData))
                    }

                    continuation.yield(.finished)
                } catch is CancellationError {
                    Self.logger.debug("Realtime pipeline cancelled")
                    continuation.yield(.finished)
                } catch {
                    Self.logger.error("Realtime pipeline error: \(error.localizedDescription)")
                    continuation.yield(.error(error.localizedDescription))
                    continuation.yield(.finished)
                }
                continuation.finish()
            }
            self.currentTaskMutex.withLock { $0 = task }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func warmup() async {
        // No-op: realtime services don't need local model pre-loading.
    }

    func cancel() {
        currentTaskMutex.withLock { task in
            task?.cancel()
            task = nil
        }
        Task { await client.disconnect() }
    }
}
