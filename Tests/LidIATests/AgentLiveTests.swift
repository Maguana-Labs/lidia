import Foundation
import SwiftData
import Testing
@testable import LidIA

/// Live agent runs over a COPY of a real library. Off unless
/// `LIDIA_AGENT_LIVE_STORE=<path to a copied LidIA.store>` is set.
///
/// - `LIDIA_AGENT_LIVE_MODEL`: an MLX model ID (default Qwen 3.5 4B). Loaded
///   alone and unloaded after.
/// - `LIDIA_AGENT_LIVE_CLAUDE=1`: also ask one question to Claude with
///   `ANTHROPIC_API_KEY` (claude-sonnet-5-5, effort low, at most 3 calls).
/// - `LIDIA_AGENT_LIVE_OUT=<dir>`: write each transcript there as JSON.
/// - `LIDIA_LIVE_USER`: the library owner's name (default "Alex Moreno").
/// - `LIDIA_AGENT_LIVE_QUESTIONS`: the questions, one per line (default: the
///   three below, written for the fictional cast in docs/fictional-cast.md).
@Suite("Agent live", .serialized)
@MainActor
struct AgentLiveTests {
    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated static var storePath: String? { env["LIDIA_AGENT_LIVE_STORE"] }
    static var userName: String { env["LIDIA_LIVE_USER"] ?? "Alex Moreno" }

    static var questions: [String] {
        let custom = (env["LIDIA_AGENT_LIVE_QUESTIONS"] ?? "").split(separator: "\n").map(String.init)
        return custom.isEmpty ? defaultQuestions : custom
    }

    static let defaultQuestions = [
        "What did we agree with Northwind last time?",
        "What are my open action items?",
        "What came out of the TAPR call with Pinecrest?",
    ]

    private func openCopy() throws -> ModelContainer {
        let url = URL(fileURLWithPath: try #require(Self.storePath))
        try #require(url.standardizedFileURL.path != LibraryLocation.storeURL.standardizedFileURL.path, "Never the real library")
        let schema = Schema(versionedSchema: AppSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    }

    private func report(_ label: String, _ question: String, _ result: AgentHarness.Result) {
        let t = result.transcript
        print("LIVE ===== \(label) · \(question)")
        print("LIVE outcome=\(t.outcome.rawValue) seconds=\(String(format: "%.1f", t.seconds)) model=\(t.model) backend=\(t.backend.rawValue) where=\(t.whereItRan) systemTokens≈\(TokenEstimate.estimate(t.systemPrompt))")
        for entry in t.entries {
            switch entry {
            case .modelCall(let call):
                print("LIVE   step \(call.step): model \(String(format: "%.1f", call.seconds))s tools=\(call.toolsOffered) → \(call.toolCalls.isEmpty ? "answer" : call.toolCalls.map { "\($0.name) \($0.argumentsJSON)" }.joined(separator: "; "))")
            case .toolRun(let run):
                print("LIVE   step \(run.step): \(run.call.name) \(run.status.rawValue) \(String(format: "%.2f", run.seconds))s · \(run.result.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")
            case .repair(let step, let problem, let rejected):
                print("LIVE   step \(step): REPAIR \(problem) · rejected: \(rejected.prefix(200))")
            case .note(let note):
                print("LIVE   note \(note)")
            }
        }
        print("LIVE answer: \(result.answer)")
        if !result.pendingActions.isEmpty { print("LIVE pending: \(result.pendingActions.map(\.summary))") }
        if let dir = Self.env["LIDIA_AGENT_LIVE_OUT"] {
            let name = "\(label)-\(Self.questions.firstIndex(of: question) ?? 0).json"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? Data(t.jsonText.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    @Test(.enabled(if: AgentLiveTests.storePath != nil))
    func localModel() async throws {
        let container = try openCopy()
        let context = container.mainContext
        let modelID = Self.env["LIDIA_AGENT_LIVE_MODEL"] ?? "mlx-community/Qwen3.5-4B-4bit"
        let manager = ModelManager(storage: ModelStorage(hubCacheDirectory: ModelStorage.appModelsDirectory))
        let loadStart = Date()
        try await manager.loadModel(modelID)
        print("LIVE loaded \(modelID) in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")
        defer { manager.unloadModel() }

        let client = MLXLocalClient(modelManager: manager, preferredModelID: modelID)
        let endpoint = AgentEndpoints.endpoint(
            client: client, model: modelID, label: ModelCatalog.entry(for: modelID)?.displayName,
            providerName: "On-device model (MLX)", locality: .onDevice
        )
        let configuration = AgentHarness.Configuration.standard(for: endpoint.family, locality: .onDevice)
        let destinations = AgentDestinations()
        let harness = AgentHarness(endpoint: endpoint, tools: LidIATools.all(destinations: destinations), configuration: configuration)
        let toolContext = AgentToolContext(modelContext: context, settings: nil, destinations: destinations)
        for question in Self.questions {
            let result = await harness.run(
                prompt: AgentPromptContext(task: .ask, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps, userName: Self.userName),
                history: [], userMessage: question, context: toolContext
            )
            report("local", question, result)
            #expect(result.outcome != .failed)
        }
    }

    @Test(.enabled(if: AgentLiveTests.storePath != nil && AgentLiveTests.env["LIDIA_AGENT_LIVE_CLAUDE"] == "1"))
    func claude() async throws {
        let key = try #require(Self.env["ANTHROPIC_API_KEY"], "Set ANTHROPIC_API_KEY")
        let container = try openCopy()
        let client = AnthropicClient(apiKey: key)
        let endpoint = AgentEndpoints.endpoint(client: client, model: "claude-sonnet-5-5", providerName: "Anthropic", locality: .cloud)
        var configuration = AgentHarness.Configuration.standard(for: endpoint.family, locality: .cloud)
        configuration.maxSteps = 3 // At most three API calls.
        let destinations = AgentDestinations()
        let harness = AgentHarness(endpoint: endpoint, tools: LidIATools.all(destinations: destinations), configuration: configuration)
        let question = Self.questions[0]
        let result = await harness.run(
            prompt: AgentPromptContext(task: .ask, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps, userName: Self.userName),
            history: [], userMessage: question,
            context: AgentToolContext(modelContext: container.mainContext, settings: nil, destinations: destinations)
        )
        report("claude", question, result)
        #expect(result.transcript.modelCalls.count <= 3)
    }
}
