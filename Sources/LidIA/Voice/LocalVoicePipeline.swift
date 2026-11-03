import Foundation
import SwiftData
import Synchronization
import os

/// Local voice pipeline: STT → agent (LidIA's tools, any model) → TTS.
/// The agent fetches meeting data through tools; changes wait for a spoken yes.
/// @unchecked Sendable is safe: all `let` properties are Sendable, and
/// `currentTask` is protected by a Mutex.
final class LocalVoicePipeline: VoicePipeline, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "LocalVoicePipeline")

    private let sttEngine: any STTEngine
    private let agent: VoiceAgent
    private let ttsEngine: any TTSEngine
    private let fallbackTTS: any TTSEngine
    private let currentTaskMutex = Mutex<Task<Void, Never>?>(nil)

    init(
        stt: any STTEngine,
        agent: VoiceAgent,
        tts: any TTSEngine,
        fallbackTTS: any TTSEngine
    ) {
        self.sttEngine = stt
        self.agent = agent
        self.ttsEngine = tts
        self.fallbackTTS = fallbackTTS
    }

    func process(turn: VoiceTurnInput) -> AsyncStream<VoicePipelineEvent> {
        AsyncStream { continuation in
            let task = Task { [sttEngine, agent, ttsEngine, fallbackTTS] in
                do {
                    // 1. Resample audio to 16 kHz
                    let samples16k = AudioResampler.resample(turn.audioSamples, from: turn.sampleRate, to: 16000)
                    guard !samples16k.isEmpty else {
                        continuation.yield(.finished)
                        continuation.finish()
                        return
                    }

                    try Task.checkCancellation()

                    // 2. Transcribe
                    let transcript = await Self.transcribe(samples: samples16k, engine: sttEngine, continuation: continuation)
                    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.yield(.finished)
                        continuation.finish()
                        return
                    }
                    continuation.yield(.transcribed(transcript))

                    try Task.checkCancellation()

                    // 3. The agent answers (tools as needed), streamed sentence by sentence to TTS.
                    let history = turn.conversationHistory.filter { $0.role != "system" }
                    var spoken = ""
                    var sentenceBuffer = ""
                    var finalAnswer = ""
                    var note: String?

                    for await event in agent.respond(to: transcript, history: history) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let chunk):
                            spoken += chunk
                            sentenceBuffer += chunk
                            continuation.yield(.responseChunk(chunk))
                            while let range = sentenceBuffer.rangeOfSentenceBoundary() {
                                let sentence = String(sentenceBuffer[sentenceBuffer.startIndex..<range.upperBound])
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                sentenceBuffer = String(sentenceBuffer[range.upperBound...])
                                await Self.speak(sentence, tts: ttsEngine, fallback: fallbackTTS, continuation: continuation)
                            }
                        case .reset:
                            // Text before a tool call that wasn't spoken yet is dropped.
                            sentenceBuffer = ""
                        case .finished(let answer, let toolNote):
                            finalAnswer = answer
                            note = toolNote
                        }
                    }

                    // Flush what's left; if nothing streamed (an error or a timeout), speak the answer.
                    let remaining = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remaining.isEmpty {
                        await Self.speak(remaining, tts: ttsEngine, fallback: fallbackTTS, continuation: continuation)
                    } else if spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !finalAnswer.isEmpty {
                        await Self.speak(finalAnswer, tts: ttsEngine, fallback: fallbackTTS, continuation: continuation)
                    }

                    try Task.checkCancellation()

                    continuation.yield(.responseComplete(finalAnswer.isEmpty ? spoken : finalAnswer))
                    if let note {
                        continuation.yield(.toolResult(note))
                        Self.logger.info("Voice agent: \(note)")
                    }

                    continuation.yield(.finished)
                } catch is CancellationError {
                    Self.logger.debug("Local pipeline cancelled")
                    continuation.yield(.finished)
                } catch {
                    Self.logger.error("Local pipeline error: \(error.localizedDescription)")
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
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [sttEngine] in
                do {
                    try await sttEngine.preload()
                } catch {
                    Self.logger.warning("STT preload failed (will attempt lazy init): \(error)")
                }
            }
            group.addTask { [ttsEngine] in await ttsEngine.warmup() }
        }
    }

    func cancel() {
        currentTaskMutex.withLock { task in
            task?.cancel()
            task = nil
        }
        ttsEngine.stop()
    }

    /// Unload heavy models (TTS, STT) to free memory after session ends.
    func unloadModels() async {
        await ttsEngine.unloadModel()
        Self.logger.info("Voice pipeline models unloaded")
    }

    /// Transcribes one utterance, streaming partial text to the orb.
    private static func transcribe(
        samples: [Float],
        engine: any STTEngine,
        continuation: AsyncStream<VoicePipelineEvent>.Continuation
    ) async -> String {
        let chunk = AudioChunk(samples: samples, sampleRate: 16000, timestamp: 0)
        let stream = engine.transcribe(audioStream: AsyncStream { c in
            c.yield(chunk)
            c.finish()
        })
        var words: [String] = []
        for await word in stream {
            words.append(word.word)
            continuation.yield(.partialTranscript(words.joined(separator: " ")))
        }
        return words.joined(separator: " ")
    }

    /// Synthesises one sentence, falling back to the system voice.
    private static func speak(
        _ sentence: String,
        tts: any TTSEngine,
        fallback: any TTSEngine,
        continuation: AsyncStream<VoicePipelineEvent>.Continuation
    ) async {
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        do {
            let audio = try await tts.synthesize(cleaned)
            if !audio.isEmpty { continuation.yield(.audioReady(audio)) }
        } catch {
            logger.warning("Primary TTS failed, trying fallback: \(error)")
            if let audio = try? await fallback.synthesize(cleaned), !audio.isEmpty {
                continuation.yield(.audioReady(audio))
            }
        }
    }
}

// MARK: - Sentence Boundary Detection

private extension String {
    /// Find the first sentence boundary (. ! ? followed by space/newline/end).
    func rangeOfSentenceBoundary() -> Range<String.Index>? {
        for i in indices {
            let char = self[i]
            guard char == "." || char == "!" || char == "?" else { continue }

            // Don't split on abbreviations like "Dr.", "Mr.", "e.g.", numbers like "3.5"
            // Simple heuristic: require at least 15 chars before the split point
            let distance = self.distance(from: startIndex, to: i)
            guard distance >= 15 else { continue }

            let nextIndex = index(after: i)
            if nextIndex == endIndex {
                // Punctuation at end of string — this is a boundary
                return i..<nextIndex
            }
            if nextIndex < endIndex {
                let next = self[nextIndex]
                if next == " " || next == "\n" {
                    return i..<index(after: nextIndex) // Include the space/newline
                }
            }
        }
        return nil
    }
}
