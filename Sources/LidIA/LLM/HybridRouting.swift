import Foundation

// MARK: - Where AI runs

/// The three answers to "Where AI runs" in Settings → AI.
///
/// - `onThisMac`: every task uses the local engine (`llmProvider` is local).
/// - `hybrid`: the local engine is the base; tasks whose hybrid placement is
///   `.cloud` go to `hybridCloudProvider`. Per-task flips are ordinary route
///   overrides (the same ones Settings → AI → Advanced edits).
/// - `cloud`: `llmProvider` is a cloud or subscription provider.
///
/// Stored as `LLMSettings.hybridEnabled` plus the provider, so users who never
/// touch Hybrid keep exactly the behaviour they had.
enum AIRunMode: String, CaseIterable, Identifiable, Sendable {
    case onThisMac
    case hybrid
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onThisMac: "On this Mac"
        case .hybrid: "Hybrid"
        case .cloud: "Cloud"
        }
    }
}

/// Where one task runs in Hybrid mode.
enum TaskPlacement: String, Sendable, Equatable {
    case onThisMac
    case cloud
}

// MARK: - Task metadata

extension LLMTaskType {
    /// Name in the Hybrid list and the Advanced routing list.
    var displayName: String {
        switch self {
        case .summarization: "Meeting notes"
        case .ask: "Ask and chat answers"
        case .followUp: "Follow-up drafts"
        case .actionItems: "Action items, decisions and titles"
        case .prepBrief: "Prep briefs"
        case .transcriptRefinement: "Transcript cleanup"
        case .templateDetection: "Template choice"
        case .chat: "Dictation and quick tasks"
        }
    }

    /// One line under the name: what the task is, in the user's words.
    var detail: String {
        switch self {
        case .summarization: "The notes written after each meeting."
        case .ask: "Answers in Ask (⌘K) and the chat bar."
        case .followUp: "Suggested messages and tickets after a meeting."
        case .actionItems: "Finds what was decided and who does what."
        case .prepBrief: "The brief before a meeting."
        case .transcriptRefinement: "Optional cleanup pass before notes."
        case .templateDetection: "Picks the notes template for a meeting."
        case .chat: "Dictation polish, project and vocabulary suggestions, voice answers, recipes."
        }
    }

    /// Hybrid default. Long, high-value writing goes to the cloud; quick,
    /// frequent and private steps stay on this Mac.
    var hybridDefault: TaskPlacement {
        switch self {
        case .summarization, .ask, .followUp:
            return .cloud
        case .actionItems, .prepBrief, .transcriptRefinement, .templateDetection, .chat:
            return .onThisMac
        }
    }

    /// The task whose route override this one used before it existed, so a
    /// "Chat → Anthropic" override set by an older build still covers Ask.
    /// Only consulted outside Hybrid mode.
    var legacyParent: LLMTaskType? {
        switch self {
        case .ask, .followUp: return .chat
        case .prepBrief, .actionItems: return .summarization
        case .summarization, .chat, .transcriptRefinement, .templateDetection: return nil
        }
    }

    /// Order of the Hybrid list: cloud-default tasks first.
    static let hybridListOrder: [LLMTaskType] = [
        .summarization, .ask, .followUp,
        .actionItems, .prepBrief, .chat, .templateDetection, .transcriptRefinement,
    ]
}

/// Work that never uses a language model and always stays on this Mac. Shown
/// in the Hybrid list so the whole picture is on one page.
enum AlwaysLocalWork: String, CaseIterable, Identifiable, Sendable {
    case liveTranscript
    case memory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveTranscript: "Live transcript and audio"
        case .memory: "Search memory (embeddings)"
        }
    }

    var detail: String {
        switch self {
        case .liveTranscript: "Speech recognition runs on this Mac. Audio never leaves it."
        case .memory: "The index behind search and related meetings."
        }
    }
}

// MARK: - Route resolution

/// The provider and model a task resolves to, and why.
struct LLMRoute: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// An explicit per-task override (Advanced routing, or a Hybrid flip).
        case override
        /// The override of the task's `legacyParent` (outside Hybrid).
        case inheritedOverride
        /// Hybrid default placement: cloud.
        case hybridCloud
        /// Hybrid default placement: this Mac (or the cloud provider isn't set up).
        case hybridLocal
        /// The main provider, outside Hybrid.
        case base
        /// Hybrid with Local-only mode on: a cloud task forced onto this Mac.
        case localOnlyForced
    }

    let provider: AppSettings.LLMProvider
    /// Empty means "the provider's default model" (`defaultModelForProvider`).
    let model: String
    let source: Source
}

@MainActor
func runMode(settings: AppSettings) -> AIRunMode {
    if settings.llm.hybridEnabled { return .hybrid }
    return settings.llmProvider.nominalLocality == .cloud ? .cloud : .onThisMac
}

/// The local engine Hybrid uses: the main provider when it is local,
/// otherwise automatic on-device.
@MainActor
func hybridLocalProvider(settings: AppSettings) -> AppSettings.LLMProvider {
    let base = settings.llmProvider
    return base.nominalLocality == .cloud ? .automaticLocal : base
}

/// Whether a cloud provider can be tried at all (key entered, endpoint set,
/// CLI installed). Sign-in and network problems surface at request time and
/// fall back with a note.
@MainActor
func isCloudProviderConfigured(_ provider: AppSettings.LLMProvider, settings: AppSettings) -> Bool {
    switch provider {
    case .codexCLI:
        return CLIVendor.codex.resolveExecutable() != nil
    case .grokCLI:
        return CLIVendor.grok.resolveExecutable() != nil
    case .openAICompatible:
        return !settings.llm.customBaseURL.isEmpty
    default:
        guard provider.requiresAPIKey else { return true }
        return !settings.llm.apiKey(for: provider).trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The one place a task's provider is decided. `resolvedProvider` and
/// `effectiveModel` both read it, so the client and the model always agree.
@MainActor
func resolveRoute(settings: AppSettings, taskType: LLMTaskType?) -> LLMRoute {
    let mode = runMode(settings: settings)
    let route = unforcedRoute(settings: settings, taskType: taskType, mode: mode)

    // Local-only forces Hybrid's cloud tasks back onto this Mac instead of
    // failing them. (Outside Hybrid the gate blocks the cloud provider with a
    // clear message, as before.)
    if mode == .hybrid, settings.localOnlyMode,
       route.provider.locality(settings: settings) != .onDevice {
        return LLMRoute(provider: hybridLocalProvider(settings: settings), model: "", source: .localOnlyForced)
    }
    return route
}

@MainActor
private func unforcedRoute(settings: AppSettings, taskType: LLMTaskType?, mode: AIRunMode) -> LLMRoute {
    guard let taskType else {
        let base = mode == .hybrid ? hybridLocalProvider(settings: settings) : settings.llmProvider
        return LLMRoute(provider: base, model: "", source: mode == .hybrid ? .hybridLocal : .base)
    }
    if let override = settings.routeConfig(for: taskType) {
        return LLMRoute(provider: override.provider, model: override.model, source: .override)
    }
    switch mode {
    case .hybrid:
        let cloud = settings.llm.hybridCloudProvider
        if taskType.hybridDefault == .cloud, isCloudProviderConfigured(cloud, settings: settings) {
            return LLMRoute(provider: cloud, model: "", source: .hybridCloud)
        }
        return LLMRoute(provider: hybridLocalProvider(settings: settings), model: "", source: .hybridLocal)
    case .onThisMac, .cloud:
        if let parent = taskType.legacyParent, let override = settings.routeConfig(for: parent) {
            return LLMRoute(provider: override.provider, model: override.model, source: .inheritedOverride)
        }
        return LLMRoute(provider: settings.llmProvider, model: "", source: .base)
    }
}

/// Where a task runs in Hybrid, as the Hybrid list shows it.
@MainActor
func hybridPlacement(of taskType: LLMTaskType, settings: AppSettings) -> TaskPlacement {
    let route = resolveRoute(settings: settings, taskType: taskType)
    return route.provider.locality(settings: settings) == .cloud ? .cloud : .onThisMac
}

/// Flips one task in the Hybrid list. Choosing the task's default removes the
/// override; anything else is stored as an ordinary route override, so the
/// Advanced routing list shows the same thing.
@MainActor
func setHybridPlacement(_ placement: TaskPlacement, for taskType: LLMTaskType, settings: AppSettings) {
    if placement == taskType.hybridDefault {
        settings.setRouteConfig(nil, for: taskType)
        return
    }
    let provider = placement == .cloud ? settings.llm.hybridCloudProvider : hybridLocalProvider(settings: settings)
    // Empty model: follow the provider's chosen model.
    settings.setRouteConfig(LLMRouteConfig(provider: provider, model: ""), for: taskType)
}

/// The provider a task uses in Hybrid when nothing is overridden.
@MainActor
func hybridDefaultProvider(for taskType: LLMTaskType, settings: AppSettings) -> AppSettings.LLMProvider {
    taskType.hybridDefault == .cloud ? settings.llm.hybridCloudProvider : hybridLocalProvider(settings: settings)
}

/// Sets one Hybrid row to any provider + model pair (any cloud provider, a
/// subscription, or a model on this Mac). The task's default pair with no
/// model removes the override.
@MainActor
func setTaskRoute(provider: AppSettings.LLMProvider, model: String, for taskType: LLMTaskType, settings: AppSettings) {
    if provider == hybridDefaultProvider(for: taskType, settings: settings), model.isEmpty {
        settings.setRouteConfig(nil, for: taskType)
    } else {
        settings.setRouteConfig(LLMRouteConfig(provider: provider, model: model), for: taskType)
    }
}

/// Providers a Hybrid row can pick, grouped: this Mac, API keys, subscriptions.
let taskProviderGroups: [(title: String, providers: [AppSettings.LLMProvider])] = [
    ("On this Mac", AppSettings.LLMProvider.providers(in: .onThisMac) + AppSettings.LLMProvider.providers(in: .localServer)),
    ("Your API key", AppSettings.LLMProvider.providers(in: .cloud)),
    ("Your subscription", AppSettings.LLMProvider.providers(in: .subscription)),
]

/// Whether a provider can be chosen for a task right now: a key is entered,
/// the subscription CLI is signed in, the local model is there. The rest
/// show "Set up…".
@MainActor
func isProviderSelectable(
    _ provider: AppSettings.LLMProvider,
    settings: AppSettings,
    cliReady: (CLIVendor) -> Bool,
    hasDownloadedModel: Bool
) -> Bool {
    switch provider {
    case .automaticLocal, .ollama, .lmStudio:
        return true
    case .appleOnDevice:
        return AppleFoundationClient.availability == .available
    case .mlx:
        return hasDownloadedModel
    case .codexCLI, .grokCLI:
        return provider.cliVendor.map(cliReady) ?? false
    default:
        return isCloudProviderConfigured(provider, settings: settings)
    }
}

/// Switches "Where AI runs". Moving out of Hybrid drops the overrides that
/// contradict the new mode (a Hybrid "cloud" flip must not survive a switch
/// to On this Mac), so each mode means what it says.
@MainActor
func setRunMode(_ mode: AIRunMode, settings: AppSettings) {
    let current = runMode(settings: settings)
    guard mode != current else { return }
    let llm = settings.llm
    switch mode {
    case .hybrid:
        if settings.llmProvider.nominalLocality == .cloud {
            llm.hybridCloudProvider = settings.llmProvider
            llm.llmProvider = llm.lastLocalProvider ?? .automaticLocal
        } else if let configured = bestConfiguredCloudProvider(settings: settings) {
            llm.hybridCloudProvider = configured
        }
        llm.hybridEnabled = true
        llm.hybridOfferHandled = true
    case .onThisMac:
        if settings.llmProvider.nominalLocality == .cloud {
            llm.llmProvider = llm.lastLocalProvider ?? .automaticLocal
        }
        llm.hybridEnabled = false
        dropOverrides(settings: settings) { $0.locality(settings: settings) == .cloud }
    case .cloud:
        if settings.llmProvider.nominalLocality != .cloud {
            llm.lastLocalProvider = settings.llmProvider
        }
        if current == .hybrid {
            llm.llmProvider = llm.hybridCloudProvider
        } else if settings.llmProvider.nominalLocality != .cloud {
            llm.llmProvider = llm.lastCloudProvider ?? bestConfiguredCloudProvider(settings: settings) ?? .anthropic
        }
        llm.hybridEnabled = false
        dropOverrides(settings: settings) { $0.locality(settings: settings) != .cloud }
    }
}

@MainActor
private func dropOverrides(settings: AppSettings, where shouldDrop: (AppSettings.LLMProvider) -> Bool) {
    for task in LLMTaskType.allCases {
        if let config = settings.routeConfig(for: task), shouldDrop(config.provider) {
            settings.setRouteConfig(nil, for: task)
        }
    }
}

/// The cloud provider to suggest: Anthropic when it has a key, then any
/// other provider with a key, then an installed subscription CLI.
@MainActor
func bestConfiguredCloudProvider(settings: AppSettings) -> AppSettings.LLMProvider? {
    var candidates: [AppSettings.LLMProvider] = [.anthropic]
    candidates += AppSettings.LLMProvider.providers(in: .cloud).filter { $0 != .anthropic && $0 != .openAICompatible }
    if let match = candidates.first(where: { !settings.llm.apiKey(for: $0).isEmpty }) {
        return match
    }
    return AppSettings.LLMProvider.providers(in: .subscription).first {
        isCloudProviderConfigured($0, settings: settings)
    }
}

/// The provider to name in "Use Hybrid?", or nil when the offer shouldn't
/// show: already Hybrid, already answered, Local-only on, or no cloud
/// provider has a key yet. Offered once (`hybridOfferHandled`).
@MainActor
func hybridOfferProvider(
    settings: AppSettings,
    hasKey: ((AppSettings.LLMProvider) -> Bool)? = nil
) -> AppSettings.LLMProvider? {
    guard !settings.llm.hybridOfferHandled, !settings.localOnlyMode,
          runMode(settings: settings) == .onThisMac else { return nil }
    let hasKey = hasKey ?? { !settings.llm.apiKey(for: $0).isEmpty }
    let keyed: [AppSettings.LLMProvider] = [.anthropic] + AppSettings.LLMProvider.providers(in: .cloud).filter { $0 != .anthropic }
    return keyed.first { $0.requiresAPIKey && hasKey($0) }
}

// MARK: - Request classification

/// Recognises the pipeline's sub-steps inside a request, so a client created
/// for "Meeting notes" can still send "Action items" to its own route. The
/// pipeline (Recording/, Pipeline/) creates one client per meeting; this keeps
/// Hybrid's per-task choice honest without changing every caller.
enum LLMRequestClassifier {
    static func task(for messages: [LLMChatMessage]) -> LLMTaskType? {
        let system = messages.first { $0.role == "system" }?.content ?? ""
        let first = messages.first?.content ?? ""
        if system.hasPrefix(SummaryPrompts.factsMarker) || system.hasPrefix(ActionRouting.systemPrompt.prefix(40))
            || system.hasPrefix(ActionItemVerifier.marker) {
            return .actionItems
        }
        if first.hasPrefix(AppSettings.templateDetectionMarker) {
            return .templateDetection
        }
        if first.hasPrefix("You are a meeting prep assistant") || system.hasPrefix("You are a meeting prep assistant") {
            return .prepBrief
        }
        if system.hasPrefix(SummaryPrompts.markdownSummaryMarker) || system.contains("You are condensing part") {
            return .summarization
        }
        return nil
    }
}

// MARK: - Display

enum ModelDisplayName {
    /// "claude-sonnet-5-5" → "Claude Sonnet 5.5"; "gpt-6.1-sol" → "GPT 6.1 Sol".
    static func pretty(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return id }
        var words: [String] = []
        for part in parts {
            if part.allSatisfy(\.isNumber) && part.count >= 8 {
                continue // a date snapshot suffix
            } else if part.allSatisfy(\.isNumber), let last = words.last, last.last?.isNumber == true {
                words[words.count - 1] = last + "." + part
            } else if part.lowercased() == "gpt" {
                words.append("GPT")
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }
}

/// "Claude Sonnet 5.5", "ChatGPT plan · Codex default": what a Hybrid cloud row shows.
@MainActor
func hybridCloudLabel(settings: AppSettings) -> String {
    cloudModelLabel(settings.llm.hybridCloudProvider, settings: settings)
}

/// "Claude Sonnet 5.5", "ChatGPT plan", "OpenAI · gpt-5.1" for a cloud provider's chosen model.
@MainActor
func cloudModelLabel(_ provider: AppSettings.LLMProvider, settings: AppSettings) -> String {
    let model = defaultModelForProvider(provider, settings: settings)
    switch provider {
    case .codexCLI, .grokCLI:
        return CLIVendor.isDefaultModel(model) ? provider.shortName : "\(provider.shortName) · \(ModelDisplayName.pretty(model))"
    case .anthropic:
        return ModelDisplayName.pretty(model.isEmpty ? LLMSettings.defaultAnthropicModel : model)
    default:
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }
}
