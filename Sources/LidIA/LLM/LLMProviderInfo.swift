import Foundation

// MARK: - Data locality

/// Where meeting data goes when a provider handles a request.
/// Shown as a badge on every provider and model.
enum DataLocality: String, Sendable, CaseIterable, Codable {
    /// Runs on this Mac: MLX, Apple Intelligence on-device, or a loopback server.
    case onDevice
    /// A server on the user's network (an Ollama / LM Studio host that is not loopback).
    case localNetwork
    /// A cloud provider reached with the user's own key.
    case cloud

    var label: String {
        switch self {
        case .onDevice: return "On this Mac"
        case .localNetwork: return "Your network server"
        case .cloud: return "Cloud provider, your key"
        }
    }

    var systemImage: String {
        switch self {
        case .onDevice: return "lock.laptopcomputer"
        case .localNetwork: return "network"
        case .cloud: return "cloud"
        }
    }

    /// True when data leaves the machines the user controls.
    var crossesToCloud: Bool { self == .cloud }
}

// MARK: - Provider grouping

/// How providers are grouped in Settings.
enum LLMProviderGroup: String, CaseIterable, Sendable {
    case onThisMac = "On this Mac"
    case localServer = "Local server (advanced)"
    case cloud = "Cloud — your key"
    /// A paid consumer plan reached through the vendor's own CLI.
    case subscription = "Cloud — your subscription"
}

extension AppSettings.LLMProvider {
    /// User-facing name. Differs from `rawValue` where the stored value is legacy.
    var displayName: String {
        switch self {
        case .automaticLocal: return "Automatic (on this Mac)"
        case .appleOnDevice: return "Apple Intelligence"
        case .mlx: return "Local model (MLX)"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .cerebras: return "Cerebras"
        case .deepseek: return "DeepSeek"
        case .nvidiaNIM: return "NVIDIA NIM"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .openAICompatible: return "Other OpenAI-compatible"
        case .codexCLI: return "ChatGPT plan (via Codex)"
        case .grokCLI: return "SuperGrok plan (via Grok CLI)"
        }
    }

    /// Short name for compact rows ("ChatGPT plan · GPT 6.1 Sol").
    var shortName: String {
        switch self {
        case .codexCLI: return "ChatGPT plan"
        case .grokCLI: return "SuperGrok plan"
        default: return displayName
        }
    }

    /// Training/retention status shown next to the cloud badge.
    @MainActor
    func privacyNote(settings: AppSettings) -> String? {
        switch self {
        case .anthropic:
            // privacy.claude.com, "Is my data used for model training?"
            return "API data isn't used for training by default."
        case .openai:
            // OpenAI API docs, "Your data".
            return "API data isn't used for training by default; abuse-monitoring logs are kept up to 30 days."
        case .openAICompatible:
            return settings.llm.customBaseURL.isEmpty ? nil : "Data handling depends on the server you point it at."
        case .gemini:
            return "Free tier: prompts may be used to improve Google products and seen by reviewers. Paid tier: not used for training."
        case .openRouter:
            return settings.llm.openRouterEnforceZDR
                ? "Zero data retention enforced: only routes to providers that don't store or train on prompts."
                : "Routing may include providers that store or train on prompts."
        case .groq:
            return "Zero data retention if you turn it on in Groq's Data Controls."
        case .deepseek:
            return "Check DeepSeek's privacy policy for where data is stored."
        case .cerebras:
            return "Paid service (the free tier ended in July 2026)."
        case .nvidiaNIM:
            return "Developer endpoint."
        case .codexCLI:
            return "Runs OpenAI's Codex app signed in to your ChatGPT account. Your ChatGPT data controls apply."
        case .grokCLI:
            return "Runs xAI's Grok CLI signed in to your account. Your Grok data settings apply."
        default:
            return nil
        }
    }

    /// A short badge next to the data-handling line, where one is useful.
    /// `isWarning` marks a provider that may keep or train on prompts.
    @MainActor
    func dataBadge(settings: AppSettings) -> (text: String, isWarning: Bool)? {
        switch self {
        case .anthropic, .openai: return ("No training", false)
        case .openRouter: return settings.llm.openRouterEnforceZDR ? ("Zero retention", false) : ("May retain", true)
        case .gemini: return ("Free tier may train", true)
        default: return nil
        }
    }

    var group: LLMProviderGroup {
        switch self {
        case .automaticLocal, .appleOnDevice, .mlx:
            return .onThisMac
        case .ollama, .lmStudio:
            return .localServer
        case .openai, .anthropic, .cerebras, .deepseek, .nvidiaNIM, .openRouter, .gemini, .groq, .openAICompatible:
            return .cloud
        case .codexCLI, .grokCLI:
            return .subscription
        }
    }

    /// Locality without looking at settings. Local servers are assumed to be
    /// on this Mac; use `locality(settings:)` to account for remote hosts.
    var nominalLocality: DataLocality {
        switch group {
        case .onThisMac, .localServer: return .onDevice
        case .cloud, .subscription: return .cloud
        }
    }

    /// Locality taking the configured server URL into account.
    @MainActor
    func locality(settings: AppSettings) -> DataLocality {
        switch self {
        case .ollama:
            return DataLocality.forServer(urlString: settings.ollamaURL)
        case .lmStudio:
            return DataLocality.forServer(urlString: settings.lmStudioURL)
        case .openAICompatible:
            // A self-hosted endpoint on this Mac or the LAN isn't the cloud.
            let url = settings.llm.customBaseURL
            return url.isEmpty ? .cloud : DataLocality.forServer(urlString: url)
        default:
            return nominalLocality
        }
    }

    /// Whether the provider needs an API key to work. Subscription providers
    /// sign in through their CLI instead.
    var requiresAPIKey: Bool { group == .cloud }

    /// The subscription CLI behind a provider, if any.
    var cliVendor: CLIVendor? {
        switch self {
        case .codexCLI: return .codex
        case .grokCLI: return .grok
        default: return nil
        }
    }

    /// Providers shown in a group, in display order.
    static func providers(in group: LLMProviderGroup) -> [AppSettings.LLMProvider] {
        allCases.filter { $0.group == group }
    }
}

extension DataLocality {
    /// `.onDevice` for loopback hosts, `.localNetwork` for private-network
    /// hosts, `.cloud` for anything else (a "local server" URL that points at
    /// a public host is still data leaving the network).
    static func forServer(urlString: String) -> DataLocality {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else {
            return .onDevice
        }
        return forHost(host)
    }

    /// Classifies a bare host name or IP literal (IPv6 with or without brackets).
    ///
    /// - Loopback (`.onDevice`): `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`
    ///   (and `::ffff:127.x.x.x`).
    /// - Private (`.localNetwork`): RFC 1918 IPv4, IPv4 link-local, CGNAT
    ///   (`100.64.0.0/10`, used by Tailscale), IPv6 unique-local `fc00::/7` and
    ///   link-local `fe80::/10`, mDNS `.local` names, `.lan`, `.home.arpa`,
    ///   `.internal`, and single-label names.
    /// - Everything else, including any other IPv6 literal, is `.cloud`.
    static func forHost(_ rawHost: String) -> DataLocality {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Drop an IPv6 zone ID ("fe80::1%en0", percent-encoded in URLs as %25).
        if let percent = host.firstIndex(of: "%") {
            host = String(host[..<percent])
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return .cloud }

        if let v4 = ipv4Octets(host) {
            return forIPv4(v4)
        }
        if let v6 = ipv6Bytes(host) {
            return forIPv6(v6)
        }
        // Not an IP literal. A colon here means a malformed address: not local.
        if host.contains(":") { return .cloud }

        if host == "localhost" || host.hasSuffix(".localhost") {
            return .onDevice
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") || !host.contains(".") {
            return .localNetwork
        }
        return .cloud
    }

    private static func forIPv4(_ o: [UInt8]) -> DataLocality {
        switch (o[0], o[1]) {
        case (127, _): return .onDevice
        case (10, _): return .localNetwork
        case (172, 16...31): return .localNetwork
        case (192, 168): return .localNetwork
        case (169, 254): return .localNetwork
        case (100, 64...127): return .localNetwork  // CGNAT / Tailscale
        default: return .cloud
        }
    }

    private static func forIPv6(_ b: [UInt8]) -> DataLocality {
        // ::1
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return .onDevice }
        // IPv4-mapped ::ffff:a.b.c.d follows the IPv4 rules.
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
            return forIPv4(Array(b[12..<16]))
        }
        if b[0] & 0xfe == 0xfc { return .localNetwork }                 // fc00::/7
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .localNetwork }   // fe80::/10
        return .cloud
    }

    /// Strict dotted-quad parse: four decimal parts, each 0–255.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Parses an IPv6 literal into 16 bytes with `inet_pton`.
    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        guard host.contains(":") else { return nil }
        var addr = in6_addr()
        let ok = host.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
        guard ok else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}

// MARK: - OpenAI-compatible presets

/// Hosted providers reached through `OpenAIClient` with a fixed base URL.
enum OpenAICompatiblePreset: String, CaseIterable, Sendable {
    case gemini
    case groq

    var baseURL: URL {
        switch self {
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
        case .groq: return URL(string: "https://api.groq.com/openai/v1")!
        }
    }
}

// MARK: - Cloud gate

/// Why a request wants to reach a cloud provider. Lets a future privacy
/// setting allow some purposes and not others.
enum LLMCloudPurpose: String, Sendable, CaseIterable {
    /// The user picked a cloud provider as the primary/routed provider.
    case primary
    /// A local provider failed and the fallback provider is in the cloud.
    case fallback
    /// Checking an API key or listing models (no meeting content is sent).
    case keyValidation
}

/// What to do when a local provider fails and the fallback is a cloud provider.
enum CloudFallbackPolicy: String, CaseIterable, Sendable {
    /// Don't send; surface `LLMError.cloudBlocked` so the UI can ask.
    case ask = "Ask"
    /// Send to the cloud fallback.
    case always = "Always"
    /// Never send to the cloud fallback.
    case never = "Never"
}

/// The single decision point for whether meeting data may go to a cloud
/// provider. Every cloud-crossing path in `LLM/` calls this.
///
/// Local-only mode also blocks servers on the network; that wider rule lives
/// in `allowsMeetingData(to:for:settings:)` and `providerBlockedError`, which
/// the factories (`makeLLMClient`, `makeGatedClient`) use.
@MainActor
func allowsCloud(for purpose: LLMCloudPurpose, settings: AppSettings) -> Bool {
    // Local-only mode blocks every cloud call, including key checks.
    if settings.localOnlyMode { return false }
    switch purpose {
    case .primary, .keyValidation:
        return true
    case .fallback:
        return settings.cloudFallbackPolicy == .always
    }
}

/// Whether meeting data may go to a destination with `locality`.
///
/// Local-only mode allows only this Mac: on-device models and loopback
/// servers. It blocks the cloud and servers on other computers on the
/// network. With Local-only off, only the cloud needs the cloud gate.
@MainActor
func allowsMeetingData(to locality: DataLocality, for purpose: LLMCloudPurpose, settings: AppSettings) -> Bool {
    switch locality {
    case .onDevice: return true
    case .localNetwork: return !settings.localOnlyMode
    case .cloud: return allowsCloud(for: purpose, settings: settings)
    }
}

/// Why `provider` can't be used for meeting data right now, or nil when it can.
/// The one check every provider factory and provider menu goes through.
@MainActor
func providerBlockedError(
    _ provider: AppSettings.LLMProvider,
    for purpose: LLMCloudPurpose = .primary,
    settings: AppSettings
) -> LLMError? {
    let locality = provider.locality(settings: settings)
    guard !allowsMeetingData(to: locality, for: purpose, settings: settings) else { return nil }
    let reason: String
    if settings.localOnlyMode {
        reason = locality == .localNetwork
            ? "Local-only mode is on, and this server is on another computer. Meeting data stays on this Mac."
            : "Local-only mode is on, so meeting data stays on this Mac."
    } else {
        reason = "cloud AI is turned off, so meeting data stays on this Mac."
    }
    return .cloudBlocked(provider: provider.displayName, reason: reason)
}

/// Short reason for a disabled provider in a "… with" menu, or nil when usable.
@MainActor
func providerMenuDisabledReason(_ provider: AppSettings.LLMProvider, settings: AppSettings) -> String? {
    guard providerBlockedError(provider, settings: settings) != nil else { return nil }
    return settings.localOnlyMode ? "off in Local-only mode" : "cloud AI is off"
}

/// Outcome of asking whether a provider fallback may run.
enum FallbackDecision {
    case allow
    /// Don't run the fallback. Throw the error if present, else the
    /// primary provider's original error.
    case block(LLMError?)
}

/// Pure core of the fallback rule, separated for tests.
/// - Local → local and cloud → cloud fallbacks are allowed as long as the
///   cloud gate allows the destination.
/// - Local → cloud needs the `.fallback` cloud permission (policy "Always").
enum FallbackRule {
    enum Outcome: Equatable {
        case allow
        /// Ask the user; nothing was sent.
        case needsConsent
        /// Blocked; report the original failure.
        case blockedSilently
    }

    static func evaluate(
        primary: DataLocality,
        fallback: DataLocality,
        policy: CloudFallbackPolicy,
        cloudAllowedForPrimary: Bool,
        cloudAllowedForFallback: Bool
    ) -> Outcome {
        guard fallback.crossesToCloud else { return .allow }
        if primary.crossesToCloud {
            return cloudAllowedForPrimary ? .allow : .blockedSilently
        }
        if cloudAllowedForFallback { return .allow }
        return policy == .ask ? .needsConsent : .blockedSilently
    }
}

/// Decides whether a fallback from `primary` to `fallback` may run.
/// Crossing from local to cloud is never silent: it needs the cloud gate's
/// `.fallback` permission (`CloudFallbackPolicy.always`).
@MainActor
func fallbackDecision(
    from primary: AppSettings.LLMProvider,
    to fallback: AppSettings.LLMProvider,
    settings: AppSettings
) -> FallbackDecision {
    // Local-only mode: never fall back to anything off this Mac. Report the
    // primary provider's own error; there is nothing for the user to approve.
    if settings.localOnlyMode, fallback.locality(settings: settings) != .onDevice {
        return .block(nil)
    }
    let outcome = FallbackRule.evaluate(
        primary: primary.locality(settings: settings),
        fallback: fallback.locality(settings: settings),
        policy: settings.cloudFallbackPolicy,
        cloudAllowedForPrimary: allowsCloud(for: .primary, settings: settings),
        cloudAllowedForFallback: allowsCloud(for: .fallback, settings: settings)
    )
    switch outcome {
    case .allow:
        return .allow
    case .blockedSilently:
        return .block(nil)
    case .needsConsent:
        return .block(.cloudBlocked(
            provider: fallback.displayName,
            reason: "\(primary.displayName) failed, and sending this meeting to the cloud needs your OK. Set \"If the on-device model fails\" in Settings → AI to allow it."
        ))
    }
}

// MARK: - Provenance

/// Which provider and model produced an output, for "Summarised on this Mac ·
/// Gemma 4 E4B" lines. Pipeline hook: call `LLMProvenance.current(...)` where
/// the summary is generated and store it on the meeting.
struct LLMProvenance: Sendable, Equatable {
    let provider: String
    let model: String
    let locality: DataLocality

    @MainActor
    static func current(settings: AppSettings, taskType: LLMTaskType? = nil, model: String) -> LLMProvenance {
        let provider = resolvedProvider(settings: settings, taskType: taskType)
        return LLMProvenance(
            provider: provider.displayName,
            model: model,
            locality: provider.locality(settings: settings)
        )
    }
}

/// The provider a task resolves to after route overrides.
@MainActor
func resolvedProvider(settings: AppSettings, taskType: LLMTaskType?) -> AppSettings.LLMProvider {
    resolveRoute(settings: settings, taskType: taskType).provider
}
