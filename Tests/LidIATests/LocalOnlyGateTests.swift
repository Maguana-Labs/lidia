import Foundation
import Testing
@testable import LidIA

/// Snapshots `keys` in the standard defaults; call the result to restore them.
func saveDefaults(_ keys: [String]) -> () -> Void {
    let defaults = UserDefaults.standard
    let saved = keys.map { defaults.object(forKey: $0) }
    return {
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}

// Part of the serialized Local-only suite: it flips the same global setting.
extension LocalOnlyModeTests {

    @Test("Local-only allows only this Mac: on-device and loopback, not the network or the cloud")
    func localOnlyBlocksNetworkServers() async {
        await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true
            #expect(allowsMeetingData(to: .onDevice, for: .primary, settings: settings))
            #expect(!allowsMeetingData(to: .localNetwork, for: .primary, settings: settings))
            #expect(!allowsMeetingData(to: .cloud, for: .primary, settings: settings))

            settings.localOnlyMode = false
            #expect(allowsMeetingData(to: .localNetwork, for: .primary, settings: settings))
            #expect(allowsMeetingData(to: .cloud, for: .primary, settings: settings))
        }
    }

    @Test("Provider gate: LAN Ollama and cloud providers are blocked in Local-only mode")
    func providerGate() async {
        let restore = saveDefaults(["ollamaURL", "cloudFallbackPolicy"])
        defer { restore() }
        await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true

            settings.ollamaURL = "http://192.168.1.20:11434"
            #expect(providerBlockedError(.ollama, settings: settings) != nil)
            settings.ollamaURL = "http://[2606:4700::1111]:11434"
            #expect(providerBlockedError(.ollama, settings: settings) != nil)
            settings.ollamaURL = "http://localhost:11434"
            #expect(providerBlockedError(.ollama, settings: settings) == nil)

            #expect(providerBlockedError(.openai, settings: settings) != nil)
            #expect(providerBlockedError(.anthropic, settings: settings) != nil)
            #expect(providerBlockedError(.mlx, settings: settings) == nil)
            #expect(providerBlockedError(.automaticLocal, settings: settings) == nil)
            #expect(providerMenuDisabledReason(.openai, settings: settings) == "off in Local-only mode")
            #expect(providerMenuDisabledReason(.mlx, settings: settings) == nil)

            settings.localOnlyMode = false
            #expect(providerBlockedError(.openai, settings: settings) == nil)
        }
    }

    @Test("The gated factory hands back a client that refuses to send")
    func gatedFactoryRefuses() async throws {
        try await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true
            let client = try #require(makeGatedClient(for: .openai, settings: settings))
            #expect(client is UnavailableLLMClient)
            await #expect(throws: LLMError.self) {
                _ = try await client.chat(messages: [.init(role: "user", content: "hi")], model: "m", format: nil)
            }
        }
    }

    @Test("Fallbacks never leave this Mac in Local-only mode")
    func fallbackBlocked() async {
        let restore = saveDefaults(["ollamaURL", "cloudFallbackPolicy"])
        defer { restore() }
        await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true
            settings.cloudFallbackPolicy = .always
            guard case .block = fallbackDecision(from: .automaticLocal, to: .openai, settings: settings) else {
                Issue.record("Expected cloud fallback to be blocked")
                return
            }
            settings.ollamaURL = "http://10.0.0.5:11434"
            guard case .block = fallbackDecision(from: .automaticLocal, to: .ollama, settings: settings) else {
                Issue.record("Expected LAN fallback to be blocked")
                return
            }
        }
    }

    @Test("AI clients refuse non-loopback hosts at send time in Local-only mode")
    func transportBackstop() async {
        await withLocalOnly(true) {
            #expect(!PrivacyGate.allowsAIEndpoint(URL(string: "https://api.openai.com/v1")!))
            #expect(!PrivacyGate.allowsAIEndpoint(URL(string: "http://192.168.1.4:11434")!))
            #expect(PrivacyGate.allowsAIEndpoint(URL(string: "http://127.0.0.1:1234/v1")!))
            #expect(PrivacyGate.allowsAIEndpoint(URL(string: "http://[::1]:11434")!))

            // Built directly, skipping the factory: still nothing is sent.
            let openAI = OpenAIClient(apiKey: "k", baseURL: URL(string: "https://api.openai.com/v1")!)
            await #expect(throws: LLMError.self) {
                _ = try await openAI.chat(messages: [.init(role: "user", content: "hi")], model: "m", format: nil)
            }
            let anthropic = AnthropicClient(apiKey: "k")
            await #expect(throws: LLMError.self) {
                _ = try await anthropic.chat(messages: [.init(role: "user", content: "hi")], model: "m", format: nil)
            }
            let ollama = OllamaClient(baseURL: URL(string: "http://10.0.0.9:11434")!)
            var failed = false
            do {
                for try await _ in await ollama.chatStream(messages: [.init(role: "user", content: "hi")], model: "m") {}
            } catch let error as LLMError {
                if case .cloudBlocked = error { failed = true }
            } catch {}
            #expect(failed)
        }
        await withLocalOnly(false) {
            #expect(PrivacyGate.allowsAIEndpoint(URL(string: "https://api.openai.com/v1")!))
        }
    }

    @Test("The privacy list and toggle copy match the wider Local-only rule")
    func disclosureForNetworkServer() async {
        let restore = saveDefaults(["ollamaURL", "llmProvider"])
        defer { restore() }
        await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true
            settings.llmProvider = .ollama
            settings.ollamaURL = "http://192.168.1.20:11434"
            let ai = PrivacyDisclosure(settings: settings).items.first { $0.id == "ai" }
            #expect(ai?.status == .blockedByLocalOnly)
            #expect(ai?.detail.contains("another computer") == true)
            #expect(PrivacySettingsSection.localOnlyDescription.contains("AI servers on other computers are blocked"))
            #expect(PrivacySettingsSection.localOnlyDescription.contains("OpenAI voice"))
        }
    }
}
