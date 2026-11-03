import Foundation
import os

// MARK: - UnavailableLLMClient

/// A client that always fails with a clear, user-facing reason. Returned by
/// the factory instead of silently substituting a different provider.
struct UnavailableLLMClient: LLMClient {
    enum Reason: Sendable, Equatable {
        case setupRequired(String)
        case cloudBlocked(provider: String, reason: String)
    }

    let reason: Reason

    init(_ error: LLMError) {
        switch error {
        case .cloudBlocked(let provider, let reason):
            self.reason = .cloudBlocked(provider: provider, reason: reason)
        default:
            self.reason = .setupRequired(error.localizedDescription)
        }
    }

    var error: LLMError {
        switch reason {
        case .setupRequired(let message):
            return .setupRequired(message)
        case .cloudBlocked(let provider, let reason):
            return .cloudBlocked(provider: provider, reason: reason)
        }
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        throw error
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }

    func listModels() async throws -> [String] {
        throw error
    }
}

// MARK: - AutomaticLocalClient

/// The default provider for new users. Picks the best on-device option at
/// request time, so a model that finishes downloading takes over without a
/// settings change:
///
/// 1. A downloaded MLX model (the selected one, else any downloaded one).
/// 2. Apple Intelligence on-device, when available.
/// 3. Otherwise fails with `LLMError.setupRequired`.
///
/// It never routes to a server or a cloud provider.
final class AutomaticLocalClient: LLMClient {
    /// Model string used when no MLX model is selected; callers treat an empty
    /// model as "not configured", so this keeps them running.
    static let modelID = "automatic"

    private static let logger = Logger(subsystem: "io.lidia.app", category: "AutomaticLocalClient")

    private let modelManager: ModelManager?
    private let preferredMLXModelID: String

    init(modelManager: ModelManager?, preferredMLXModelID: String) {
        self.modelManager = modelManager
        self.preferredMLXModelID = preferredMLXModelID
    }

    /// Which local backend automatic mode will use right now.
    enum Backend: Equatable, Sendable {
        case mlx(modelID: String)
        case appleOnDevice
        case none
    }

    @MainActor
    static func currentBackend(modelManager: ModelManager?, preferredMLXModelID: String) -> Backend {
        // Only this Mac's recommended model, fully downloaded and verified.
        // Whatever else sits in the models folder is ignored (a partial or
        // oversized download must never be picked up silently).
        if let modelManager,
           let modelID = ModelCatalog.automaticModelID(
               physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
               isVerified: { modelManager.isVerified($0.id) }
           ) {
            return .mlx(modelID: modelID)
        }
        if AppleFoundationClient.availability == .available {
            return .appleOnDevice
        }
        return .none
    }

    /// The backend this client resolves to right now.
    @MainActor
    var backend: Backend {
        Self.currentBackend(modelManager: modelManager, preferredMLXModelID: preferredMLXModelID)
    }

    static let setupMessage = "AI isn't set up yet. Download an on-device model in Settings → AI, or connect a provider there."

    private func resolve() async throws -> (any LLMClient, Backend) {
        let modelManager = self.modelManager
        let preferred = preferredMLXModelID
        let backend = await MainActor.run {
            Self.currentBackend(modelManager: modelManager, preferredMLXModelID: preferred)
        }
        switch backend {
        case .mlx(let modelID):
            guard let modelManager else { throw LLMError.setupRequired(Self.setupMessage) }
            let client = await MainActor.run {
                MLXLocalClient(modelManager: modelManager, preferredModelID: modelID)
            }
            return (client, backend)
        case .appleOnDevice:
            return (AppleFoundationClient(), backend)
        case .none:
            throw LLMError.setupRequired(Self.setupMessage)
        }
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        let (client, backend) = try await resolve()
        Self.logger.debug("Automatic local routing to \(String(describing: backend), privacy: .public)")
        return try await client.chat(messages: messages, model: model, format: format)
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        do {
            let (client, _) = try await resolve()
            return await client.chatStream(messages: messages, model: model)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func listModels() async throws -> [String] {
        let (client, _) = try await resolve()
        return try await client.listModels()
    }
}
