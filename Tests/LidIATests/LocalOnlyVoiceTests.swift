import Foundation
import Testing
@testable import LidIA

@Suite("Voice privacy")
struct VoicePrivacyTests {

    @Test("Local-only forces the local pipeline even with TTS set to OpenAI")
    func realtimeBlocked() {
        #expect(VoiceAssistantBackend.resolve(ttsProvider: .openai, openAIAPIKey: "sk-test", localOnly: true) == .localPipeline)
        #expect(VoiceAssistantBackend.resolve(ttsProvider: .automatic, openAIAPIKey: "sk-test", localOnly: true) == .localPipeline)
    }

    @Test("Automatic TTS with no local voice and an OpenAI key uses the system voice in Local-only mode")
    func automaticTTS() {
        #expect(VoiceTTSChoice.resolve(provider: .automatic, hasOpenAIKey: true, mlxModelID: nil, localOnly: false) == .openAI)
        #expect(VoiceTTSChoice.resolve(provider: .automatic, hasOpenAIKey: true, mlxModelID: nil, localOnly: true) == .system)
        #expect(VoiceTTSChoice.resolve(provider: .automatic, hasOpenAIKey: true, mlxModelID: "kokoro", localOnly: true) == .mlx(modelID: "kokoro"))
        #expect(VoiceTTSChoice.resolve(provider: .automatic, hasOpenAIKey: false, mlxModelID: nil, localOnly: false) == .system)
    }

    @Test("TTS set to OpenAI falls back to MLX, then the system voice, in Local-only mode")
    func openAITTS() {
        #expect(VoiceTTSChoice.resolve(provider: .openai, hasOpenAIKey: true, mlxModelID: nil, localOnly: false) == .openAI)
        #expect(VoiceTTSChoice.resolve(provider: .openai, hasOpenAIKey: true, mlxModelID: "kokoro", localOnly: true) == .mlx(modelID: "kokoro"))
        #expect(VoiceTTSChoice.resolve(provider: .openai, hasOpenAIKey: true, mlxModelID: nil, localOnly: true) == .system)
        #expect(VoiceTTSChoice.resolve(provider: .mlx, hasOpenAIKey: true, mlxModelID: nil, localOnly: false) == .system)
        #expect(VoiceTTSChoice.resolve(provider: .system, hasOpenAIKey: true, mlxModelID: "kokoro", localOnly: false) == .system)
    }
}

// Part of the serialized Local-only suite: it flips the same global setting.
extension LocalOnlyModeTests {

    @Test("OpenAI TTS and Realtime refuse to send at send time in Local-only mode")
    func voiceBackstops() async {
        await withLocalOnly(true) {
            let tts = OpenAITTSEngine(apiKey: "sk-test")
            await #expect(throws: LLMError.self) {
                _ = try await tts.synthesize("Your next meeting is with Acme")
            }
            let realtime = RealtimeVoiceClient(apiKey: "sk-test")
            await #expect(throws: LLMError.self) {
                _ = try await realtime.completeTurn(samples: [0, 0], sourceSampleRate: 48_000, voice: "nova", instructions: "SOUL")
            }
        }
    }
}
