import Foundation

protocol STTEngine: Sendable {
    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord>
    /// Pre-load models so the first transcription call is fast. Default: no-op.
    func preload() async throws
}

extension STTEngine {
    func preload() async throws {}
}

/// One update from a live engine.
enum LiveSTTEvent: Sendable, Equatable {
    /// Words the engine won't change any more. They're appended to the transcript as is.
    case finalized([TranscriptWord])
    /// The engine's current guess for the speech after the last finalized word. Each one
    /// replaces the previous guess; an empty text clears it. `start` is when that speech
    /// began, on the same clock as the engine's word times (nil when unknown).
    case volatile(text: String, start: TimeInterval?)
}

/// An engine that reports a refining guess while someone speaks, plus final words.
/// Plain `STTEngine`s only report final words.
protocol LiveSTTEngine: STTEngine {
    func transcribeLive(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<LiveSTTEvent>
}

extension LiveSTTEngine {
    /// Final words only, for callers that don't show a live guess (recorded audio).
    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        LiveSTTEvents.finalWords(of: transcribeLive(audioStream: audioStream))
    }
}

extension STTEngine {
    /// Live updates from any engine: the engine's own when it reports a guess, otherwise
    /// each word as a finalized update.
    func liveEvents(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<LiveSTTEvent> {
        if let live = self as? any LiveSTTEngine {
            return live.transcribeLive(audioStream: audioStream)
        }
        let words = transcribe(audioStream: audioStream)
        return AsyncStream { continuation in
            let task = Task {
                for await word in words { continuation.yield(.finalized([word])) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum LiveSTTEvents {
    static func finalWords(of events: AsyncStream<LiveSTTEvent>) -> AsyncStream<TranscriptWord> {
        AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .finalized(let words) = event {
                        for word in words { continuation.yield(word) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#if DEBUG
/// Mock STT engine for testing. Thread-safe: mockWords is immutable after init.
final class MockSTTEngine: STTEngine, Sendable {
    let mockWords: [TranscriptWord]

    init(mockWords: [TranscriptWord] = []) {
        self.mockWords = mockWords
    }

    func transcribe(audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        let words = mockWords
        return AsyncStream { continuation in
            for word in words {
                continuation.yield(word)
            }
            continuation.finish()
        }
    }
}
#endif
