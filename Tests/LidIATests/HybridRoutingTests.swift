import Foundation
import os
import Testing
@testable import LidIA

/// Settings in a known state, with everything Hybrid touches restored after.
/// No API keys are set: that would write the Keychain. The cloud side uses an
/// OpenAI-compatible endpoint on a public host, which counts as configured
/// once it has a base URL.
@MainActor
func withHybridSettings(_ body: (AppSettings) async throws -> Void) async rethrows {
    let restore = saveDefaults([
        "llmProvider", "hybridEnabled", "hybridCloudProvider", "hybridOfferHandled", "routeOverrides",
        "customBaseURL", "customModel", "settings.lastLocalProvider", "settings.lastCloudProvider",
        "queryModel", "summaryModel", "fallbackProvider",
    ])
    defer { restore() }
    let settings = AppSettings()
    settings.llmProvider = .appleOnDevice
    settings.llm.hybridEnabled = false
    settings.llm.hybridOfferHandled = false
    settings.llm.customBaseURL = "https://llm.example.com/v1"
    settings.llm.customModel = "big-model"
    settings.llm.hybridCloudProvider = .openAICompatible
    settings.queryModel = ""
    settings.summaryModel = ""
    settings.fallbackProvider = ""
    for task in LLMTaskType.allCases { settings.setRouteConfig(nil, for: task) }
    try await body(settings)
}

// Nested in the serialized Local-only suite: `AppSettings()` reads the
// Local-only flag that suite flips, so these must not run beside it.
extension LocalOnlyModeTests {
@Suite("Hybrid routing")
@MainActor
struct HybridRoutingTests {

    @Test("Hybrid defaults: notes, Ask and follow-ups to the cloud; the rest on this Mac")
    func hybridDefaults() async {
        await withHybridSettings { settings in
            settings.llm.hybridEnabled = true
            #expect(runMode(settings: settings) == .hybrid)

            for task in [LLMTaskType.summarization, .ask, .followUp] {
                let route = resolveRoute(settings: settings, taskType: task)
                #expect(route.provider == .openAICompatible, "\(task)")
                #expect(route.source == .hybridCloud)
                #expect(effectiveModel(for: .summary, settings: settings, taskType: task) == "big-model")
            }
            for task in [LLMTaskType.actionItems, .prepBrief, .chat, .templateDetection, .transcriptRefinement] {
                let route = resolveRoute(settings: settings, taskType: task)
                #expect(route.provider == .appleOnDevice, "\(task)")
                #expect(route.source == .hybridLocal)
                #expect(effectiveModel(for: .query, settings: settings, taskType: task) == AppleFoundationClient.modelID)
            }
            // No task: the local engine.
            #expect(resolvedProvider(settings: settings, taskType: nil) == .appleOnDevice)
        }
    }

    @Test("Every task has a Hybrid row, and the list order covers them all")
    func hybridList() {
        #expect(Set(LLMTaskType.hybridListOrder) == Set(LLMTaskType.allCases))
        #expect(LLMTaskType.summarization.displayName == "Meeting notes")
        #expect(LLMTaskType.summarization.hybridDefault == .cloud)
        #expect(LLMTaskType.actionItems.hybridDefault == .onThisMac)
    }

    @Test("Flipping a row is an ordinary route override; flipping back removes it")
    func perTaskOverride() async {
        await withHybridSettings { settings in
            settings.llm.hybridEnabled = true

            setHybridPlacement(.onThisMac, for: .summarization, settings: settings)
            #expect(settings.routeConfig(for: .summarization)?.provider == .appleOnDevice)
            #expect(hybridPlacement(of: .summarization, settings: settings) == .onThisMac)
            #expect(resolveRoute(settings: settings, taskType: .summarization).source == .override)

            setHybridPlacement(.cloud, for: .prepBrief, settings: settings)
            #expect(resolvedProvider(settings: settings, taskType: .prepBrief) == .openAICompatible)

            // Back to the default: no override left behind.
            setHybridPlacement(.cloud, for: .summarization, settings: settings)
            #expect(settings.routeConfig(for: .summarization) == nil)
            #expect(resolveRoute(settings: settings, taskType: .summarization).source == .hybridCloud)
        }
    }

    @Test("Hybrid without a configured cloud provider keeps everything on this Mac")
    func hybridWithoutCloud() async {
        await withHybridSettings { settings in
            settings.llm.hybridEnabled = true
            settings.llm.customBaseURL = ""
            #expect(resolvedProvider(settings: settings, taskType: .summarization) == .appleOnDevice)
            #expect(hybridPlacement(of: .ask, settings: settings) == .onThisMac)
        }
    }

    @Test("Existing users keep their behaviour: On this Mac and Cloud resolve as before")
    func migration() async {
        await withHybridSettings { settings in
            // On this Mac, no overrides: everything on the main provider.
            #expect(runMode(settings: settings) == .onThisMac)
            for task in LLMTaskType.allCases {
                #expect(resolvedProvider(settings: settings, taskType: task) == .appleOnDevice)
            }
            // An old "Chat" override still covers Ask and follow-ups; an old
            // "Summarization" override still covers prep briefs.
            settings.setRouteConfig(LLMRouteConfig(provider: .openAICompatible, model: "m"), for: .chat)
            settings.setRouteConfig(LLMRouteConfig(provider: .ollama, model: "q"), for: .summarization)
            #expect(resolveRoute(settings: settings, taskType: .ask) == LLMRoute(provider: .openAICompatible, model: "m", source: .inheritedOverride))
            #expect(resolvedProvider(settings: settings, taskType: .followUp) == .openAICompatible)
            #expect(resolvedProvider(settings: settings, taskType: .prepBrief) == .ollama)
            #expect(effectiveModel(for: .query, settings: settings, taskType: .ask) == "m")

            // A cloud main provider reads as Cloud mode.
            settings.setRouteConfig(nil, for: .chat)
            settings.setRouteConfig(nil, for: .summarization)
            settings.llmProvider = .anthropic
            #expect(runMode(settings: settings) == .cloud)
            #expect(resolvedProvider(settings: settings, taskType: .summarization) == .anthropic)
            #expect(resolvedProvider(settings: settings, taskType: .chat) == .anthropic)
        }
    }

    @Test("Switching modes: into Hybrid keeps the local engine; out of it drops cloud flips")
    func switchingModes() async {
        await withHybridSettings { settings in
            setRunMode(.hybrid, settings: settings)
            #expect(settings.llm.hybridEnabled)
            #expect(settings.llmProvider == .appleOnDevice)
            #expect(settings.llm.hybridOfferHandled)

            setHybridPlacement(.cloud, for: .chat, settings: settings)
            setRunMode(.onThisMac, settings: settings)
            #expect(!settings.llm.hybridEnabled)
            #expect(settings.routeConfig(for: .chat) == nil)
            #expect(resolvedProvider(settings: settings, taskType: .chat) == .appleOnDevice)

            // From Cloud, Hybrid takes the cloud provider as its cloud side.
            settings.llmProvider = .anthropic
            setRunMode(.hybrid, settings: settings)
            #expect(settings.llm.hybridCloudProvider == .anthropic)
            #expect(settings.llmProvider.nominalLocality == .onDevice)
        }
    }

    @Test("Use Hybrid? is offered once, only on this Mac, only with a key")
    func hybridOffer() async {
        await withHybridSettings { settings in
            let anthropicOnly: (AppSettings.LLMProvider) -> Bool = { $0 == .anthropic }
            #expect(hybridOfferProvider(settings: settings, hasKey: { _ in false }) == nil)
            #expect(hybridOfferProvider(settings: settings, hasKey: anthropicOnly) == .anthropic)

            settings.llm.hybridOfferHandled = true
            #expect(hybridOfferProvider(settings: settings, hasKey: anthropicOnly) == nil)

            settings.llm.hybridOfferHandled = false
            settings.llm.hybridEnabled = true
            #expect(hybridOfferProvider(settings: settings, hasKey: anthropicOnly) == nil)
        }
    }

    @Test("Request classifier finds the pipeline's sub-steps")
    func classifier() {
        #expect(LLMRequestClassifier.task(for: [LLMChatMessage(role: "system", content: SummaryPrompts.factsMarker + " …")]) == .actionItems)
        #expect(LLMRequestClassifier.task(for: [LLMChatMessage(role: "user", content: AppSettings.templateDetectionMarker + "\n…")]) == .templateDetection)
        #expect(LLMRequestClassifier.task(for: [LLMChatMessage(role: "system", content: SummaryPrompts.markdownSummaryMarker)]) == .summarization)
        #expect(LLMRequestClassifier.task(for: [LLMChatMessage(role: "user", content: "hello")]) == nil)
    }

    @Test("Hybrid's notes client sends the facts step to its own (local) route")
    func factsStayLocal() async throws {
        await withHybridSettings { settings in
            settings.llm.hybridEnabled = true
            let client = makeLLMClient(settings: settings, taskType: .summarization)
            guard let routed = client as? TaskRoutedClient else {
                Issue.record("Expected a TaskRoutedClient, got \(type(of: client)), localOnly \(settings.localOnlyMode)")
                return
            }
            #expect(routed.primary.isCloud)
            #expect(routed.localFallback != nil)
            #expect(routed.subRoutes[.actionItems]?.isCloud == false)
            let facts = [LLMChatMessage(role: "system", content: SummaryPrompts.factsMarker)]
            #expect(routed.target(for: facts, callerModel: "big-model").target.isCloud == false)
            #expect(routed.target(for: [LLMChatMessage(role: "user", content: "x")], callerModel: "big-model").model == "big-model")

            // A local task stays local; only a notes prompt sent through it
            // (the template preview) follows "Meeting notes" to the cloud.
            let quick = makeLLMClient(settings: settings, taskType: .chat)
            if let quick = quick as? TaskRoutedClient {
                #expect(!quick.primary.isCloud)
                #expect(!quick.target(for: [LLMChatMessage(role: "user", content: "polish this")], callerModel: "apple").target.isCloud)
            }
            #expect(resolvedProvider(settings: settings, taskType: .chat) == .appleOnDevice)
        }
    }

    @Test("Outside Hybrid, a client with no differing sub-routes is the plain provider client")
    func noWrapperByDefault() async {
        await withHybridSettings { settings in
            let client = makeLLMClient(settings: settings, taskType: .summarization)
            #expect(client is AppleFoundationClient)
        }
    }
}
}

// Local-only forcing lives in the serialized Local-only suite (it flips the same global).
extension LocalOnlyModeTests {
    @Test("Hybrid + Local-only: every task resolves to this Mac")
    func hybridLocalOnly() async {
        await withLocalOnly(true) {
            await withHybridSettings { settings in
                settings.llm.hybridEnabled = true
                settings.localOnlyMode = true
                defer { settings.localOnlyMode = false }
                for task in LLMTaskType.allCases {
                    let route = resolveRoute(settings: settings, taskType: task)
                    #expect(route.provider == .appleOnDevice, "\(task)")
                }
                #expect(resolveRoute(settings: settings, taskType: .summarization).source == .localOnlyForced)
                // Even an explicit cloud flip.
                setHybridPlacement(.cloud, for: .chat, settings: settings)
                #expect(resolvedProvider(settings: settings, taskType: .chat) == .appleOnDevice)
                #expect(!(makeLLMClient(settings: settings, taskType: .summarization) is TaskRoutedClient))
            }
        }
    }

    @Test("Subscription CLIs refuse to run in Local-only mode")
    func cliLocalOnly() async {
        await withLocalOnly(true) {
            let client = CLIChatClient(vendor: .codex, executable: URL(fileURLWithPath: "/usr/bin/false"))
            do {
                _ = try await client.chat(messages: [LLMChatMessage(role: "user", content: "x")], model: "default", format: nil)
                Issue.record("Expected cloudBlocked")
            } catch let error as LLMError {
                guard case .cloudBlocked = error else {
                    Issue.record("Wrong error \(error)")
                    return
                }
            } catch {
                Issue.record("Wrong error type \(error)")
            }
        }
    }
}

// MARK: - Fallback

private struct StubClient: LLMClient {
    let reply: String
    var error: Error?
    var streamChunks: [String] = []

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        if let error { throw error }
        return "\(reply)|\(model)"
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        let error = self.error
        let chunks = streamChunks.isEmpty ? [reply] : streamChunks
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { [] }
}

@Suite("Hybrid fallback")
struct HybridFallbackTests {
    private func routed(
        task: LLMTaskType = .summarization,
        cloudError: Error?,
        notices: OSAllocatedUnfairLock<[HybridFallbackNotice]>
    ) -> TaskRoutedClient {
        TaskRoutedClient(
            declaredTask: task,
            primary: RoutedTarget(task: task, providerName: "Anthropic", client: StubClient(reply: "cloud", error: cloudError), model: "claude-sonnet-5-5", isCloud: true),
            subRoutes: [:],
            localFallback: RoutedTarget(task: task, providerName: "Apple Intelligence", client: StubClient(reply: "local"), model: "apple", isCloud: false),
            onFallback: { notice in notices.withLock { $0.append(notice) } }
        )
    }

    @Test("A failing cloud call falls back to the local model, with a note")
    func fallsBack() async throws {
        let notices = OSAllocatedUnfairLock(initialState: [HybridFallbackNotice]())
        let client = routed(cloudError: URLError(.notConnectedToInternet), notices: notices)
        let reply = try await client.chat(messages: [LLMChatMessage(role: "user", content: "x")], model: "claude-sonnet-5-5", format: nil)
        #expect(reply == "local|apple")
        let recorded = notices.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.task == .summarization)
        #expect(recorded.first?.reason == "this Mac is offline")
        #expect(recorded.first?.message.contains("Meeting notes ran on this Mac") == true)
    }

    @Test("A working cloud call doesn't fall back")
    func noFallbackOnSuccess() async throws {
        let notices = OSAllocatedUnfairLock(initialState: [HybridFallbackNotice]())
        let client = routed(cloudError: nil, notices: notices)
        let reply = try await client.chat(messages: [LLMChatMessage(role: "user", content: "x")], model: "claude-sonnet-5-5", format: nil)
        #expect(reply == "cloud|claude-sonnet-5-5")
        #expect(notices.withLock { $0 }.isEmpty)
    }

    @Test("Cancelling never falls back")
    func noFallbackOnCancel() async {
        let notices = OSAllocatedUnfairLock(initialState: [HybridFallbackNotice]())
        let client = routed(cloudError: CancellationError(), notices: notices)
        await #expect(throws: CancellationError.self) {
            _ = try await client.chat(messages: [], model: "m", format: nil)
        }
        #expect(notices.withLock { $0 }.isEmpty)
    }

    @Test("Streams fall back before the first token; Ask says so in the answer")
    func streamFallback() async throws {
        let notices = OSAllocatedUnfairLock(initialState: [HybridFallbackNotice]())
        let client = routed(task: .ask, cloudError: CLIClientError.notSignedIn(.codex), notices: notices)
        var text = ""
        for try await chunk in await client.chatStream(messages: [LLMChatMessage(role: "user", content: "x")], model: "m") {
            text += chunk
        }
        #expect(text.hasPrefix("_Answered on this Mac"))
        #expect(text.hasSuffix("local"))
        #expect(notices.withLock { $0 }.count == 1)
    }

    @Test("A local target that fails is reported as is (no fallback the other way)")
    func localFailureSurfaces() async {
        let notices = OSAllocatedUnfairLock(initialState: [HybridFallbackNotice]())
        let client = TaskRoutedClient(
            declaredTask: .chat,
            primary: RoutedTarget(task: .chat, providerName: "Apple Intelligence", client: StubClient(reply: "", error: LLMError.setupRequired("no model")), model: "apple", isCloud: false),
            subRoutes: [:],
            localFallback: nil,
            onFallback: { notice in notices.withLock { $0.append(notice) } }
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.chat(messages: [], model: "apple", format: nil)
        }
        #expect(notices.withLock { $0 }.isEmpty)
    }
}

@Suite("Model display names")
struct ModelDisplayNameTests {
    @Test func pretty() {
        #expect(ModelDisplayName.pretty("claude-sonnet-5-5") == "Claude Sonnet 5.5")
        #expect(ModelDisplayName.pretty("claude-opus-5-20261001") == "Claude Opus 5")
        #expect(ModelDisplayName.pretty("gpt-6.1-sol") == "GPT 6.1 Sol")
    }
}
