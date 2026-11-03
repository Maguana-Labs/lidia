import SwiftUI

/// A provider's API key with Test and the validation result.
struct APIKeyRow: View {
    let provider: AppSettings.LLMProvider
    @Bindable var settings: AppSettings
    let ai: AISettingsModel
    @Environment(ModelManager.self) private var modelManager
    /// "API key" on the main page, the provider's name in the Advanced list.
    var label: String?

    var body: some View {
        let key = ai.keyBinding(for: provider, settings: settings)
        let account = LLMSettings.KeyAccount.account(for: provider) ?? ""

        LabeledContent {
            HStack(spacing: 8) {
                SecureField("\(provider.displayName) API key", text: key, prompt: Text("Paste your key"))
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .onSubmit { settings.llm.commitAPIKey(for: provider) }
                statusControl(hasKey: !key.wrappedValue.isEmpty)
                    .frame(minWidth: 36, alignment: .leading)
            }
        } label: {
            Text(label ?? "API key")
            detailText(hasKey: !key.wrappedValue.isEmpty, account: account)
        }
        .onChange(of: key.wrappedValue) {
            ai.keyStatus[provider] = nil
        }
    }

    @ViewBuilder
    private func statusControl(hasKey: Bool) -> some View {
        if hasKey {
            switch ai.keyStatus[provider] {
            case .none:
                Button("Test") {
                    Task { await ai.validateKey(for: provider, settings: settings, modelManager: modelManager) }
                }
            case .testing:
                ProgressView().controlSize(.small)
            case .result(let result):
                Image(systemName: AISettingsModel.symbol(for: result))
                    .foregroundStyle(AISettingsModel.color(for: result))
                    .help(result.message)
                    .accessibilityLabel(result.message)
            }
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private func detailText(hasKey: Bool, account: String) -> some View {
        if let error = settings.llm.keychainErrors[account] {
            Text(error).foregroundStyle(.red)
        } else if hasKey, case .result(let result) = ai.keyStatus[provider] {
            Text(result.message).foregroundStyle(AISettingsModel.color(for: result))
        } else if provider == .gemini {
            Text("Free-tier keys may be used to train Google's models. Use a paid key for meetings.")
                .foregroundStyle(.orange)
        } else if !hasKey, label == nil {
            Text("Stored in your Keychain on this Mac.")
        }
    }
}

/// A model menu with the known models and "Custom…", which shows a text field.
struct ModelMenuRow: View {
    let title: String
    var detail: String?
    let binding: Binding<String>
    let models: [String]
    let emptyLabel: String
    /// Key for the text typed after "Custom…".
    let customKey: String
    let ai: AISettingsModel

    var body: some View {
        let sentinel = AISettingsModel.customSentinel
        let isCustom = binding.wrappedValue == sentinel
        let isUnknownModel = !binding.wrappedValue.isEmpty && !isCustom && !models.contains(binding.wrappedValue)
        let customText = Binding<String>(
            get: { ai.customModelText[customKey] ?? "" },
            set: { ai.customModelText[customKey] = $0 }
        )

        let pickerSelection = Binding<String>(
            get: { (isCustom || isUnknownModel) ? sentinel : binding.wrappedValue },
            set: { newValue in
                if newValue == sentinel {
                    if !binding.wrappedValue.isEmpty && binding.wrappedValue != sentinel {
                        customText.wrappedValue = binding.wrappedValue
                    }
                    binding.wrappedValue = sentinel
                } else {
                    customText.wrappedValue = ""
                    binding.wrappedValue = newValue
                }
            }
        )

        Picker(selection: pickerSelection) {
            Text(emptyLabel).tag("")
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            Divider()
            Text("Custom\u{2026}").tag(sentinel)
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }

        if isCustom || isUnknownModel {
            LabeledContent("Model ID") {
                TextField("Model ID", text: customText, prompt: Text("e.g. claude-sonnet-4-5"))
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .onAppear {
                        if isUnknownModel && customText.wrappedValue.isEmpty {
                            customText.wrappedValue = binding.wrappedValue
                        }
                    }
                    .onChange(of: customText.wrappedValue) { _, newText in
                        if !newText.isEmpty { binding.wrappedValue = newText }
                    }
            }
        }
    }
}

// MARK: - Subscription CLI

/// A subscription CLI: installed, signed in, and a Sign in… button that
/// opens Terminal with the vendor's own login.
struct CLISubscriptionRow: View {
    let vendor: CLIVendor
    let ai: AISettingsModel
    /// "ChatGPT plan" as the title (Advanced list) instead of "Status".
    var showsName = false

    var body: some View {
        let status = ai.cliStatus[vendor]
        LabeledContent {
            HStack(spacing: 8) {
                if ai.cliChecking.contains(vendor) {
                    ProgressView().controlSize(.small)
                } else if let status {
                    if status.isInstalled && status.signIn != .signedIn {
                        Button("Sign in\u{2026}") { ai.signIn(vendor) }
                    }
                    Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(status.isReady ? Color.green : Color.orange)
                        .accessibilityLabel(status.isReady ? "Ready" : "Not ready")
                    Button("Check") { Task { await ai.refreshCLIStatus(vendor) } }
                        .buttonStyle(.borderless)
                }
            }
        } label: {
            Text(showsName ? vendor.provider.shortName : "Status")
            Text(Self.detail(for: status, vendor: vendor))
                .foregroundStyle(status.map { $0.isReady ? Color.secondary : Color.orange } ?? Color.secondary)
        }
        .task {
            if ai.cliStatus[vendor] == nil { await ai.refreshCLIStatus(vendor) }
        }
    }

    static func detail(for status: CLIStatus?, vendor: CLIVendor) -> String {
        guard let status else { return "Checking \(vendor.toolName)\u{2026}" }
        guard status.isInstalled else {
            return vendor == .codex
                ? "Codex isn't installed. It comes with the ChatGPT app, or install the Codex CLI."
                : "The Grok CLI isn't installed. Install it from x.ai, then sign in."
        }
        // "grok 1.0.70 (f509…) [stable]" → "grok 1.0.70"
        let shortVersion = status.version.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        let via = status.transport.map { " · via \($0)" } ?? ""
        let version = shortVersion.map { "\($0)\(via) · " } ?? ""
        switch status.signIn {
        case .signedIn:
            return "\(version)Signed in. Uses your \(vendor.planName) plan, not an API key."
        case .apiKey:
            return "\(version)Signed in with an API key, so calls bill that key. Sign in with \(vendor.planName) to use your plan."
        case .notSignedIn:
            return "\(version)Not signed in. Sign in opens Terminal and runs \u{201C}\(vendor.binaryName) login\u{201D}."
        case .unknown(let message):
            return "\(version)\(message.isEmpty ? "Couldn't check the sign-in." : message)"
        }
    }
}

// MARK: - Data handling

/// "Only route to providers with zero data retention" for OpenRouter. Sends
/// OpenRouter's documented provider-routing preferences
/// (`provider.zdr: true`, `provider.data_collection: "deny"`). On by default.
struct OpenRouterZDRToggle: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle(isOn: Bindable(settings.llm).openRouterEnforceZDR) {
            Text("Only route to providers with zero data retention")
            Text("OpenRouter skips providers that store or train on prompts.")
        }
    }
}

/// A small data-handling badge ("No training", "Zero retention").
struct DataBadge: View {
    let text: String
    var isWarning = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isWarning ? Color.orange : Color.green).opacity(0.15))
            .foregroundStyle(isWarning ? Color.orange : Color.green)
            .clipShape(Capsule())
    }
}

// MARK: - Locality badge

/// "On this Mac" / "Your network server" / "Cloud provider, your key".
struct LocalityBadge: View {
    let locality: DataLocality
    var compact = false

    var body: some View {
        Label(compact ? "" : locality.label, systemImage: locality.systemImage)
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .help(locality.label)
    }

    private var color: Color {
        switch locality {
        case .onDevice: return .green
        case .localNetwork: return .blue
        case .cloud: return .orange
        }
    }
}

/// Type-erased label style so the badge can switch styles.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
