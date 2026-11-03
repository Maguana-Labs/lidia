import Testing
import Foundation
@testable import LidIA

@Suite("Cloud policy and provider metadata")
struct CloudPolicyTests {

    // MARK: - Fallback rule

    @Test("Local to cloud fallback asks by default")
    func localToCloudAsks() {
        let outcome = FallbackRule.evaluate(
            primary: .onDevice, fallback: .cloud, policy: .ask,
            cloudAllowedForPrimary: true, cloudAllowedForFallback: false
        )
        #expect(outcome == .needsConsent)
    }

    @Test("Local to cloud fallback with policy Never is blocked without a prompt")
    func localToCloudNever() {
        let outcome = FallbackRule.evaluate(
            primary: .onDevice, fallback: .cloud, policy: .never,
            cloudAllowedForPrimary: true, cloudAllowedForFallback: false
        )
        #expect(outcome == .blockedSilently)
    }

    @Test("Local to cloud fallback runs only when the gate allows it")
    func localToCloudAlways() {
        let outcome = FallbackRule.evaluate(
            primary: .onDevice, fallback: .cloud, policy: .always,
            cloudAllowedForPrimary: true, cloudAllowedForFallback: true
        )
        #expect(outcome == .allow)
    }

    @Test("Local network server to cloud is also a crossing")
    func networkToCloud() {
        let outcome = FallbackRule.evaluate(
            primary: .localNetwork, fallback: .cloud, policy: .ask,
            cloudAllowedForPrimary: true, cloudAllowedForFallback: false
        )
        #expect(outcome == .needsConsent)
    }

    @Test("Fallback to a local provider is always allowed")
    func toLocalAllowed() {
        for primary in DataLocality.allCases {
            let outcome = FallbackRule.evaluate(
                primary: primary, fallback: .onDevice, policy: .never,
                cloudAllowedForPrimary: false, cloudAllowedForFallback: false
            )
            #expect(outcome == .allow)
        }
    }

    @Test("Cloud to cloud fallback follows the primary cloud gate")
    func cloudToCloud() {
        #expect(FallbackRule.evaluate(
            primary: .cloud, fallback: .cloud, policy: .never,
            cloudAllowedForPrimary: true, cloudAllowedForFallback: false
        ) == .allow)
        #expect(FallbackRule.evaluate(
            primary: .cloud, fallback: .cloud, policy: .always,
            cloudAllowedForPrimary: false, cloudAllowedForFallback: true
        ) == .blockedSilently)
    }

    @MainActor
    @Test("Settings-level decision blocks automatic-local to OpenRouter by default")
    func settingsDecisionBlocks() {
        let settings = AppSettings()
        let saved = settings.cloudFallbackPolicy
        defer { settings.cloudFallbackPolicy = saved }
        settings.cloudFallbackPolicy = .ask
        guard case .block(let error) = fallbackDecision(from: .automaticLocal, to: .openRouter, settings: settings) else {
            Issue.record("Expected the fallback to be blocked")
            return
        }
        guard case .cloudBlocked(let provider, _)? = error else {
            Issue.record("Expected a cloudBlocked error")
            return
        }
        #expect(provider == "OpenRouter")

        settings.cloudFallbackPolicy = .always
        guard case .allow = fallbackDecision(from: .automaticLocal, to: .openRouter, settings: settings) else {
            Issue.record("Expected the fallback to be allowed with policy Always")
            return
        }
    }

    // MARK: - Locality

    @Test("Server locality: loopback, private network, public host")
    func serverLocality() {
        #expect(DataLocality.forServer(urlString: "http://localhost:11434") == .onDevice)
        #expect(DataLocality.forServer(urlString: "http://127.0.0.1:1234/v1") == .onDevice)
        #expect(DataLocality.forServer(urlString: "http://[::1]:1234/v1") == .onDevice)
        #expect(DataLocality.forServer(urlString: "http://192.168.1.20:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://10.0.0.5:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://studio.local:1234/v1") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://172.20.1.1:1234") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "https://ollama.example.com") == .cloud)
    }

    @Test("IPv6 literals: only ::1 is loopback, only fc00::/7 and fe80::/10 are private")
    func ipv6Locality() {
        #expect(DataLocality.forServer(urlString: "http://[2606:4700::1111]:11434") == .cloud)
        #expect(DataLocality.forServer(urlString: "http://[2001:db8::1]:1234/v1") == .cloud)
        #expect(DataLocality.forServer(urlString: "http://[::1]:11434") == .onDevice)
        #expect(DataLocality.forServer(urlString: "http://[fd12:3456::1]:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://[fc00::5]:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://[fe80::1]:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://[fe80::1%25en0]:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://[fec0::1]:11434") == .cloud)  // fec0 is outside fe80::/10
        #expect(DataLocality.forServer(urlString: "http://[::ffff:192.168.1.2]:11434") == .localNetwork)
        #expect(DataLocality.forServer(urlString: "http://[::ffff:8.8.8.8]:11434") == .cloud)
        #expect(DataLocality.forHost("::") == .cloud)
        #expect(DataLocality.forHost("[::1]") == .onDevice)
    }

    @Test("IPv4 and names: RFC 1918, mDNS .local, strict dotted quads")
    func ipv4AndNameLocality() {
        #expect(DataLocality.forHost("127.0.0.2") == .onDevice)
        #expect(DataLocality.forHost("172.16.0.1") == .localNetwork)
        #expect(DataLocality.forHost("172.31.255.255") == .localNetwork)
        #expect(DataLocality.forHost("172.32.0.1") == .cloud)
        #expect(DataLocality.forHost("172.15.0.1") == .cloud)
        #expect(DataLocality.forHost("192.168.0.1") == .localNetwork)
        #expect(DataLocality.forHost("192.169.0.1") == .cloud)
        #expect(DataLocality.forHost("8.8.8.8") == .cloud)
        // A public DNS name that starts like a private address is not private.
        #expect(DataLocality.forHost("10.1.2.3.attacker.example") == .cloud)
        #expect(DataLocality.forHost("10.0.0.256") == .cloud)
        #expect(DataLocality.forHost("studio.local") == .localNetwork)
        #expect(DataLocality.forHost("Studio.Local.") == .localNetwork)
        #expect(DataLocality.forHost("nas") == .localNetwork)
        #expect(DataLocality.forHost("api.localhost") == .onDevice)
        #expect(DataLocality.forHost("localhost.") == .onDevice)
    }

    @Test("Every cloud provider is marked cloud and needs a key")
    func cloudProviders() {
        for provider in AppSettings.LLMProvider.allCases where provider.group == .cloud {
            #expect(provider.nominalLocality == .cloud)
            #expect(provider.requiresAPIKey)
        }
        #expect(AppSettings.LLMProvider.automaticLocal.nominalLocality == .onDevice)
        #expect(AppSettings.LLMProvider.mlx.nominalLocality == .onDevice)
    }

    // MARK: - Stored values

    @Test("Legacy stored provider values still decode")
    func legacyRawValues() {
        let legacy: [String: AppSettings.LLMProvider] = [
            "Ollama": .ollama,
            "LM Studio": .lmStudio,
            "Local (MLX)": .mlx,
            "OpenAI": .openai,
            "Anthropic": .anthropic,
            "Cerebras (Free)": .cerebras,
            "DeepSeek": .deepseek,
            "NVIDIA NIM": .nvidiaNIM,
            "OpenRouter": .openRouter,
        ]
        for (raw, expected) in legacy {
            #expect(AppSettings.LLMProvider(storedValue: raw) == expected)
        }
        #expect(AppSettings.LLMProvider(storedValue: "Cerebras") == .cerebras)
        #expect(AppSettings.LLMProvider(storedValue: "nonsense") == nil)
    }

    @Test("Route override JSON written by older builds still decodes")
    func legacyRouteOverrideJSON() throws {
        let json = #"{"provider":"Cerebras (Free)","model":"llama-3.3-70b"}"#
        let config = try JSONDecoder().decode(LLMRouteConfig.self, from: Data(json.utf8))
        #expect(config.provider == .cerebras)
        let roundTrip = try JSONDecoder().decode(LLMRouteConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip == config)
    }

    // MARK: - Unavailable client

    @Test("Unavailable client throws setupRequired instead of using another provider")
    func unavailableClientThrows() async {
        let client = UnavailableLLMClient(.setupRequired("Finish setup"))
        do {
            _ = try await client.chat(messages: [], model: "x", format: nil)
            Issue.record("Expected an error")
        } catch let error as LLMError {
            guard case .setupRequired = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}
