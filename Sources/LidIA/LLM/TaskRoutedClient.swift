import Foundation
import Observation
import os
import UserNotifications

// MARK: - Routed client

/// One resolved destination: the client, model and where it runs.
struct RoutedTarget: Sendable {
    let task: LLMTaskType
    let providerName: String
    let client: any LLMClient
    let model: String
    let isCloud: Bool
}

/// A cloud task that ran on this Mac instead.
struct HybridFallbackNotice: Sendable, Equatable, Identifiable {
    let id = UUID()
    let date: Date
    let task: LLMTaskType
    let cloudProvider: String
    let reason: String

    /// "Meeting notes ran on this Mac: Anthropic couldn't be reached (…)".
    var message: String {
        "\(task.displayName) ran on this Mac: \(cloudProvider) couldn't be used (\(reason))."
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The client `makeLLMClient` returns when a task's requests don't all go to
/// one place:
///
/// - Sub-steps inside one client are sent to their own route. The pipeline
///   creates a single "Meeting notes" client, but its facts step (title,
///   decisions, action items) and template choice are separate tasks in the
///   Hybrid list; `LLMRequestClassifier` recognises them by their prompts.
/// - In Hybrid, a cloud request that fails (offline, rate-limited, signed
///   out, key rejected) is retried once on the local engine, and the switch is
///   reported through `onFallback` (a note in Settings → AI and a
///   notification). Never silently; never in the other direction.
final class TaskRoutedClient: LLMClient {
    let declaredTask: LLMTaskType
    let primary: RoutedTarget
    let subRoutes: [LLMTaskType: RoutedTarget]
    let localFallback: RoutedTarget?
    private let onFallback: @Sendable (HybridFallbackNotice) -> Void

    /// The declared task's client, for budget and concurrency decisions.
    var primaryClient: any LLMClient { primary.client }

    init(
        declaredTask: LLMTaskType,
        primary: RoutedTarget,
        subRoutes: [LLMTaskType: RoutedTarget],
        localFallback: RoutedTarget?,
        onFallback: @escaping @Sendable (HybridFallbackNotice) -> Void
    ) {
        self.declaredTask = declaredTask
        self.primary = primary
        self.subRoutes = subRoutes
        self.localFallback = localFallback
        self.onFallback = onFallback
    }

    /// Where `messages` go, and the model to use (the caller's model belongs
    /// to the declared task's provider).
    func target(for messages: [LLMChatMessage], callerModel: String) -> (target: RoutedTarget, model: String) {
        if let task = LLMRequestClassifier.task(for: messages), task != declaredTask, let sub = subRoutes[task] {
            return (sub, sub.model)
        }
        return (primary, callerModel)
    }

    func chat(messages: [LLMChatMessage], model: String, format: LLMResponseFormat?) async throws -> String {
        let (target, targetModel) = target(for: messages, callerModel: model)
        do {
            return try await target.client.chat(messages: messages, model: targetModel, format: format)
        } catch {
            guard let fallback = fallback(after: error, from: target) else { throw error }
            return try await fallback.client.chat(messages: messages, model: fallback.model, format: format)
        }
    }

    func chatStream(messages: [LLMChatMessage], model: String) async -> AsyncThrowingStream<String, Error> {
        let (target, targetModel) = target(for: messages, callerModel: model)
        let primaryStream = await target.client.chatStream(messages: messages, model: targetModel)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var yielded = false
                do {
                    for try await chunk in primaryStream {
                        yielded = true
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                    return
                } catch {
                    // Mid-answer failures are reported, not papered over with
                    // a second, different answer.
                    guard !yielded, let fallback = self.fallback(after: error, from: target) else {
                        continuation.finish(throwing: error)
                        return
                    }
                    if self.declaredTask == .ask {
                        continuation.yield("_Answered on this Mac: \(target.providerName) couldn't be used._\n\n")
                    }
                    do {
                        for try await chunk in await fallback.client.chatStream(messages: messages, model: fallback.model) {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        try await primary.client.listModels()
    }

    /// The local target to retry on, after recording the note; nil when the
    /// error must surface as is.
    private func fallback(after error: Error, from target: RoutedTarget) -> RoutedTarget? {
        guard target.isCloud, let local = localFallback, Self.shouldFallBack(on: error) else { return nil }
        onFallback(HybridFallbackNotice(
            date: Date(),
            task: target.task,
            cloudProvider: target.providerName,
            reason: Self.shortReason(error)
        ))
        return local
    }

    /// Every failure except the user cancelling.
    static func shouldFallBack(on error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }

    static func shortReason(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "this Mac is offline"
            case .timedOut: return "it timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "it couldn't be reached"
            default: break
            }
        }
        if case LLMError.networkError(let underlying) = error, underlying is URLError {
            return shortReason(underlying)
        }
        let text = error.localizedDescription
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }
}

// MARK: - Fallback log

/// Recent Hybrid fallbacks, shown in Settings → AI, plus a notification so a
/// task that quietly ran locally is never a secret.
@MainActor
@Observable
final class AIFallbackLog {
    static let shared = AIFallbackLog()

    private(set) var recent: [HybridFallbackNotice] = []
    @ObservationIgnored private var lastNotified: [LLMTaskType: Date] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "io.lidia.app", category: "HybridFallback")

    var latest: HybridFallbackNotice? { recent.first }

    func record(_ notice: HybridFallbackNotice) {
        logger.info("Hybrid fallback for \(notice.task.rawValue, privacy: .public)")
        recent.insert(notice, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
        notifyIfAppropriate(notice)
    }

    func clear() { recent = [] }

    /// At most one notification per task every ten minutes, and only from
    /// the real app bundle (tests have no notification center).
    private func notifyIfAppropriate(_ notice: HybridFallbackNotice) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if let last = lastNotified[notice.task], notice.date.timeIntervalSince(last) < 600 { return }
        lastNotified[notice.task] = notice.date
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(notice.task.displayName) ran on this Mac")
        content.body = String(localized: "\(notice.cloudProvider) couldn't be used: \(notice.reason).")
        let request = UNNotificationRequest(identifier: "lidia.hybrid-fallback.\(notice.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Factory support

@MainActor
func routedTarget(for route: LLMRoute, task: LLMTaskType, settings: AppSettings, modelManager: ModelManager?) -> RoutedTarget {
    let client = makeGatedClient(for: route.provider, settings: settings, modelManager: modelManager)
        ?? UnavailableLLMClient(.setupRequired("\(route.provider.displayName) isn't ready. Finish AI setup in Settings → AI."))
    let model = effectiveModel(for: task == .summarization ? .summary : .query, settings: settings, taskType: task)
    return RoutedTarget(
        task: task,
        providerName: route.provider.displayName,
        client: client,
        model: model,
        isCloud: route.provider.locality(settings: settings) == .cloud
    )
}

/// The local engine Hybrid falls back to.
@MainActor
func hybridLocalTarget(task: LLMTaskType, settings: AppSettings, modelManager: ModelManager?) -> RoutedTarget {
    let provider = hybridLocalProvider(settings: settings)
    let client = makeGatedClient(for: provider, settings: settings, modelManager: modelManager)
        ?? UnavailableLLMClient(.setupRequired(AutomaticLocalClient.setupMessage))
    let model = provider == settings.llmProvider
        ? effectiveModel(for: .general, settings: settings, taskType: nil)
        : defaultModelForProvider(provider, settings: settings)
    return RoutedTarget(task: task, providerName: provider.displayName, client: client, model: model, isCloud: false)
}

/// Requests inside one client that `LLMRequestClassifier` can tell apart.
let classifiableSubTasks: [LLMTaskType] = [.summarization, .actionItems, .templateDetection, .prepBrief]
