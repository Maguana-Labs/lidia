import SwiftUI

struct AIPane: View {
    @Bindable var settings: AppSettings
    let ai: AISettingsModel
    @Environment(ModelManager.self) private var modelManager

    private var mode: AIRunMode { ai.mode(settings: settings) }

    var body: some View {
        SettingsPage(pane: .ai) {
            if let offer = hybridOfferProvider(settings: settings) {
                hybridOfferSection(offer)
            }
            whereSection
            switch mode {
            case .onThisMac:
                if settings.llmProvider.group != .onThisMac {
                    modelSection
                }
            case .cloud:
                modelSection
            case .hybrid:
                hybridCloudSection
                hybridTasksSection
            }
            Section {
                NavigationLink(value: SettingsSubpage.onDeviceModels) {
                    LabeledContent {
                        Text(downloadedSummary)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("On-device models")
                        Text("Download a model to run AI privately on this Mac.")
                    }
                }
                .settingsAnchor(.onDeviceModels)

                NavigationLink(value: SettingsSubpage.aiAdvanced) {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text("Advanced")
                        Text("Models per task, fallback, subscriptions and other API keys.")
                    }
                }
            }
        }
        .onChange(of: settings.llmProvider) { ai.providerDidChange(settings: settings) }
        .onDisappear { settings.llm.commitPendingAPIKeys() }
    }

    // MARK: Use Hybrid?

    private func hybridOfferSection(_ provider: AppSettings.LLMProvider) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use Hybrid?")
                    .font(.headline)
                Text("Meeting notes, Ask and follow-up drafts go to \(cloudModelLabel(provider, settings: settings)). Dictation, action items, prep briefs and everything else stay on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use Hybrid") {
                        ai.answerHybridOffer(accept: true, provider: provider, settings: settings)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not now") {
                        ai.answerHybridOffer(accept: false, provider: provider, settings: settings)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Where AI runs

    private var whereSection: some View {
        Section {
            Picker(selection: Binding(
                get: { mode },
                set: { ai.setMode($0, settings: settings) }
            )) {
                ForEach(AIRunMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Where AI runs")
                Text(modeDetail)
            }
            .pickerStyle(.segmented)
            .settingsAnchor(.aiLocation)

            Picker(selection: $settings.llmProvider) {
                providerMenu(mode == .cloud ? ai.cloudProviderGroups : ai.localProviderGroups)
            } label: {
                Text(mode == .cloud ? "Provider" : "Engine on this Mac")
                providerDetail(settings.llmProvider)
            }
            .settingsAnchor(.aiProvider)

            providerConfiguration(settings.llmProvider)
        }
    }

    private var modeDetail: String {
        switch mode {
        case .onThisMac: "Private. Your meetings never leave this Mac."
        case .hybrid: "Quick, private tasks run on this Mac. Notes and answers use a cloud model."
        case .cloud: "Faster and smarter models from a provider you pay."
        }
    }

    @ViewBuilder
    private func providerMenu(_ groups: [(title: String?, providers: [AppSettings.LLMProvider])]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let title = group.title {
                Section(title) {
                    ForEach(group.providers, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } else {
                ForEach(group.providers, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
        }
    }

    @ViewBuilder
    private func providerDetail(_ provider: AppSettings.LLMProvider) -> some View {
        let locality = provider.locality(settings: settings)
        switch provider {
        case .automaticLocal:
            Text("Picks the best model on this Mac.")
        case .appleOnDevice:
            Text("Built into macOS. Nothing to download.")
        case .mlx:
            Text("A model you downloaded to this Mac.")
        case .codexCLI, .grokCLI:
            Text("Uses your plan instead of per-token billing. \(provider.privacyNote(settings: settings) ?? "")")
        default:
            HStack(spacing: 6) {
                if let note = provider.privacyNote(settings: settings) {
                    Text("\(locality.label). \(note)")
                } else {
                    Text(locality.label)
                }
                if let badge = provider.dataBadge(settings: settings) {
                    DataBadge(text: badge.text, isWarning: badge.isWarning)
                }
            }
        }
    }

    @ViewBuilder
    private func providerConfiguration(_ provider: AppSettings.LLMProvider) -> some View {
        let llm = Bindable(settings.llm)
        switch provider {
        case .automaticLocal:
            LabeledContent {
                EmptyView()
            } label: {
                Text("Status")
                Text(ai.automaticStatus(settings: settings, modelManager: modelManager))
            }
        case .appleOnDevice:
            LabeledContent {
                EmptyView()
            } label: {
                Text("Status")
                Text(AppleFoundationClient.availability.userMessage)
                    .foregroundStyle(AppleFoundationClient.availability == .available ? Color.secondary : Color.orange)
            }
        case .mlx:
            if modelManager.downloadedEntries.isEmpty {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Model")
                    Text("No models downloaded yet. Get one in On-device models below.")
                }
            } else {
                Picker("Model", selection: $settings.selectedMLXModelID) {
                    Text("Best downloaded").tag("")
                    ForEach(modelManager.downloadedEntries) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
            }
        case .ollama:
            serverField("Server address", text: $settings.ollamaURL, detail: "Where Ollama is running.")
        case .lmStudio:
            serverField("Server address", text: $settings.lmStudioURL,
                        detail: "Start the server in LM Studio's Developer tab. No key needed.")
        case .openai:
            APIKeyRow(provider: .openai, settings: settings, ai: ai)
                .settingsAnchor(.apiKey)
        case .openAICompatible:
            serverField("Server address", text: llm.customBaseURL,
                        detail: "Any server that speaks the OpenAI API, such as vLLM.", prompt: "https://host/v1")
            APIKeyRow(provider: .openAICompatible, settings: settings, ai: ai)
                .settingsAnchor(.apiKey)
        case .openRouter:
            APIKeyRow(provider: .openRouter, settings: settings, ai: ai)
                .settingsAnchor(.apiKey)
            OpenRouterZDRToggle(settings: settings)
        case .anthropic, .cerebras, .deepseek, .nvidiaNIM, .gemini, .groq:
            APIKeyRow(provider: provider, settings: settings, ai: ai)
                .settingsAnchor(.apiKey)
        case .codexCLI:
            CLISubscriptionRow(vendor: .codex, ai: ai)
        case .grokCLI:
            CLISubscriptionRow(vendor: .grok, ai: ai)
        }
    }

    private func serverField(_ title: String, text: Binding<String>, detail: String, prompt: String? = nil) -> some View {
        LabeledContent {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .frame(maxWidth: 260)
        } label: {
            Text(title)
            Text(detail)
        }
    }

    // MARK: Hybrid

    private var hybridCloudSection: some View {
        let cloud = settings.llm.hybridCloudProvider
        let binding = ai.modelBinding(for: cloud, settings: settings)
        return Section("Default cloud model") {
            Picker(selection: Bindable(settings.llm).hybridCloudProvider) {
                providerMenu(ai.cloudProviderGroups)
            } label: {
                Text("Provider")
                providerDetail(cloud)
            }

            providerConfiguration(cloud)

            ModelMenuRow(
                title: "Model",
                detail: "For notes, Ask and follow-ups unless a task below picks another.",
                binding: binding,
                models: ai.cloudModelsForMenu(cloud, selection: binding.wrappedValue, settings: settings),
                emptyLabel: cloud.cliVendor.map { "\($0.toolName) default" } ?? "Automatic (recommended)",
                customKey: "hybridCloud",
                ai: ai
            )

            LabeledContent {
                Button {
                    Task { await ai.fetchCloudModels(cloud, settings: settings, modelManager: modelManager) }
                } label: {
                    if ai.fetchingCloudModels.contains(cloud) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Fetching\u{2026}")
                        }
                    } else {
                        Text("Fetch Models")
                    }
                }
                .disabled(ai.fetchingCloudModels.contains(cloud))
            } label: {
                Text("Model list")
                if let error = ai.cloudModelError[cloud] {
                    Text(error).foregroundStyle(.red)
                } else if let models = ai.cloudModels[cloud], !models.isEmpty {
                    Text("Found \(models.count) model\(models.count == 1 ? "" : "s").").foregroundStyle(.green)
                } else {
                    Text("Ask \(cloud.displayName) which models you can use.")
                }
            }
        }
    }

    private var hybridTasksSection: some View {
        let cloud = settings.llm.hybridCloudProvider
        let cloudReady = isCloudProviderConfigured(cloud, settings: settings)
        let cloudTasks = LLMTaskType.hybridListOrder.filter { hybridPlacement(of: $0, settings: settings) == .cloud }
        return Section {
            if settings.localOnlyMode {
                InlineNote(text: "Local-only mode is on, so every task runs on this Mac.", kind: .info)
            } else if !cloudReady {
                InlineNote(text: cloud.cliVendor != nil
                           ? "Install \(cloud.displayName) to use it. Until then every task runs on this Mac."
                           : "Add your \(cloud.displayName) key above. Until then every task runs on this Mac.",
                           kind: .warning)
            }
            ForEach(LLMTaskType.hybridListOrder, id: \.self) { task in
                hybridTaskRow(task)
            }
            ForEach(AlwaysLocalWork.allCases) { work in
                LabeledContent {
                    Text("On this Mac")
                        .foregroundStyle(.secondary)
                } label: {
                    Text(work.displayName)
                    Text(work.detail)
                }
            }
            if let notice = AIFallbackLog.shared.latest {
                InlineNote(
                    text: "\(notice.message) \(notice.date.formatted(date: .omitted, time: .shortened))",
                    kind: .warning
                )
            }
        } header: {
            Text("Tasks")
                .settingsAnchor(.aiModel)
        } footer: {
            Text(leavesTheMacLine(cloudTasks: cloudTasks, cloud: cloud))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            // Subscriptions are only selectable once signed in.
            for vendor in CLIVendor.allCases where ai.cliStatus[vendor] == nil {
                await ai.refreshCLIStatus(vendor)
            }
        }
    }

    @ViewBuilder
    private func hybridTaskRow(_ task: LLMTaskType) -> some View {
        let route = resolveRoute(settings: settings, taskType: task)
        let provider = Binding<AppSettings.LLMProvider>(
            get: { resolveRoute(settings: settings, taskType: task).provider },
            set: { setTaskRoute(provider: $0, model: "", for: task, settings: settings) }
        )
        let model = Binding<String>(
            get: {
                let current = resolveRoute(settings: settings, taskType: task)
                return current.source == .override ? current.model : ""
            },
            set: { setTaskRoute(provider: route.provider, model: $0, for: task, settings: settings) }
        )
        let models = ai.modelsForRouteProvider(route.provider, settings: settings, modelManager: modelManager)
        let ready = ai.isSelectable(route.provider, settings: settings, modelManager: modelManager)

        LabeledContent {
            HStack(spacing: 8) {
                Picker(task.displayName, selection: provider) {
                    ForEach(taskProviderGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.providers, id: \.self) { option in
                                let selectable = ai.isSelectable(option, settings: settings, modelManager: modelManager)
                                Text(selectable ? option.displayName : "\(option.displayName) (set up\u{2026})")
                                    .tag(option)
                                    .selectionDisabled(!selectable)
                            }
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()

                Picker("\(task.displayName) model", selection: model) {
                    Text(defaultModelLabel(route.provider)).tag("")
                    if !models.isEmpty { Divider() }
                    ForEach(models, id: \.self) { id in
                        Text(id).tag(id)
                    }
                    if !model.wrappedValue.isEmpty, !models.contains(model.wrappedValue) {
                        Text(model.wrappedValue).tag(model.wrappedValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(settings.localOnlyMode)
        } label: {
            HStack(spacing: 6) {
                Text(task.displayName)
                LocalityBadge(locality: route.provider.locality(settings: settings), compact: true)
                if let badge = route.provider.dataBadge(settings: settings) {
                    DataBadge(text: badge.text, isWarning: badge.isWarning)
                }
            }
            if !ready, !settings.localOnlyMode {
                HStack(spacing: 4) {
                    Text("\(route.provider.displayName) isn't set up.")
                        .foregroundStyle(.orange)
                    NavigationLink("Set up\u{2026}", value: SettingsSubpage.aiAdvanced)
                        .buttonStyle(.accentLink)
                }
            } else {
                Text(task.detail)
            }
        }
    }

    /// "Claude Sonnet 5.5", "Codex default", "Automatic": a row's model when none is picked.
    private func defaultModelLabel(_ provider: AppSettings.LLMProvider) -> String {
        switch provider.group {
        case .cloud, .subscription:
            return cloudModelLabel(provider, settings: settings)
        case .onThisMac, .localServer:
            let model = defaultModelForProvider(provider, settings: settings)
            if provider == .appleOnDevice { return "Apple Intelligence" }
            if provider == .automaticLocal {
                switch AutomaticLocalClient.currentBackend(modelManager: modelManager, preferredMLXModelID: settings.selectedMLXModelID) {
                case .mlx(let id): return ModelCatalog.entry(for: id)?.displayName ?? id
                case .appleOnDevice: return "Apple Intelligence"
                case .none: return "Automatic"
                }
            }
            if let entry = ModelCatalog.entry(for: model) { return entry.displayName }
            return model.isEmpty || model == AutomaticLocalClient.modelID ? "Automatic" : model
        }
    }

    /// The one line that says what leaves the Mac.
    private func leavesTheMacLine(cloudTasks: [LLMTaskType], cloud: AppSettings.LLMProvider) -> String {
        guard !cloudTasks.isEmpty, !settings.localOnlyMode else {
            return "Nothing leaves this Mac."
        }
        var names: [String] = []
        for task in cloudTasks {
            let provider = resolvedProvider(settings: settings, taskType: task)
            let name = provider.cliVendor.map { "\($0.planName) (\($0.toolName))" } ?? provider.displayName
            if !names.contains(name) { names.append(name) }
        }
        return "Leaves this Mac: the transcript, your notes and questions for the tasks set to a cloud model, sent to \(names.joined(separator: ", ")). Audio and everything else stay here."
    }

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            ModelMenuRow(
                title: "Model",
                detail: "Used for summaries and answers.",
                binding: ai.defaultModelBinding(settings: settings),
                models: ai.modelsForMenu(selection: ai.defaultModelBinding(settings: settings).wrappedValue, settings: settings),
                emptyLabel: settings.llmProvider.cliVendor.map { "\($0.toolName) default" } ?? "Automatic (recommended)",
                customKey: "default",
                ai: ai
            )
            .settingsAnchor(.aiModel)

            LabeledContent {
                Button {
                    Task { await ai.fetchModels(settings: settings, modelManager: modelManager) }
                } label: {
                    if ai.isFetchingModels {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Fetching\u{2026}")
                        }
                    } else {
                        Text("Fetch Models")
                    }
                }
                .disabled(ai.isFetchingModels)
            } label: {
                Text("Model list")
                if let error = ai.modelFetchError {
                    Text(error).foregroundStyle(.red)
                } else if let success = ai.modelFetchSuccess {
                    Text(success).foregroundStyle(.green)
                } else if let vendor = settings.llmProvider.cliVendor {
                    Text("Ask \(vendor.toolName) which models your plan includes.")
                } else {
                    Text("Ask \(settings.llmProvider.displayName) which models your key can use.")
                }
            }
        }
    }

    private var downloadedSummary: String {
        let count = modelManager.downloadedEntries.count
        guard count > 0 else { return "None" }
        let size = AISettingsModel.byteFormatter.string(fromByteCount: modelManager.modelsDiskUsage)
        return "\(count) · \(size)"
    }
}

// MARK: - On-device models

struct OnDeviceModelsPage: View {
    @Bindable var settings: AppSettings
    let ai: AISettingsModel
    @Environment(ModelManager.self) private var modelManager

    private var memoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    var body: some View {
        SettingsPage(pane: .ai, subpage: .onDeviceModels,
                     subtitle: "Models run on this Mac. This Mac has \(memoryGB) GB of memory.") {
            Section {
                ForEach(ModelCatalog.offered(forPhysicalMemory: ProcessInfo.processInfo.physicalMemory)) { entry in
                    modelRow(entry)
                }
                ForEach(ModelCatalog.legacy.filter { modelManager.isDownloaded($0.id) }) { entry in
                    modelRow(entry)
                }
                if let error = modelManager.downloadError {
                    InlineNote(text: error, kind: .error)
                }
            }

            Section {
                LabeledContent {
                    Text(AISettingsModel.byteFormatter.string(fromByteCount: modelManager.modelsDiskUsage))
                        .monospacedDigit()
                } label: {
                    Text("Storage used")
                    if let freed = ai.lastFreedBytes {
                        Text("Freed \(AISettingsModel.byteFormatter.string(fromByteCount: freed))")
                    } else {
                        Text("Kept in Application Support. Not backed up.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: ModelCatalogEntry) -> some View {
        let fit = ModelCatalog.fitForThisMac(entry)
        let installed = modelManager.isDownloaded(entry.id)
        let status = modelManager.downloadStatus?.modelID == entry.id ? modelManager.downloadStatus : nil

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .fontWeight(fit == .recommended ? .semibold : .regular)
                    if entry.role == .legacy {
                        badge("Installed (legacy)", color: .gray)
                    } else {
                        badge(fit.label, color: fitColor(fit))
                    }
                }
                Text(entry.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("\(String(format: "%.1f", entry.downloadGB)) GB")
                    Text("·")
                    Text("\(entry.contextCap / 1024)K context")
                    Text("·")
                    Link(entry.license, destination: entry.licenseURL)
                    Text("·")
                    Link("Model card", destination: entry.modelCardURL)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.accentLink)

                if let status, status.isActive || status.phase == .paused {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: status.fraction)
                            .frame(maxWidth: 260)
                        Text(status.phase == .verifying ? "Verifying files\u{2026}" : status.phase == .paused ? "Paused · \(status.progressDescription)" : status.progressDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            actions(entry, installed: installed, fit: fit, status: status)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(_ entry: ModelCatalogEntry, installed: Bool, fit: ModelFit, status: ModelDownloadStatus?) -> some View {
        if let status, status.isActive {
            Button("Pause") { modelManager.pauseDownload() }
                .disabled(status.phase == .verifying)
        } else if installed {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Installed")
                    .accessibilityLabel("Installed")
                Button(role: .destructive) {
                    if settings.selectedMLXModelID == entry.id { settings.selectedMLXModelID = "" }
                    ai.lastFreedBytes = modelManager.deleteModel(entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete and free \(String(format: "%.1f", entry.downloadGB)) GB")
                .accessibilityLabel("Delete \(entry.displayName)")
            }
        } else if entry.role != .legacy {
            HStack(spacing: 8) {
                if modelManager.hasPartialDownload(entry.id) {
                    Button("Discard") { modelManager.discardPartialDownload(entry.id) }
                        .buttonStyle(.borderless)
                }
                Button(modelManager.hasPartialDownload(entry.id) ? "Resume" : "Download") {
                    modelManager.downloadModel(entry.id)
                    if settings.selectedMLXModelID.isEmpty, fit == .recommended {
                        settings.selectedMLXModelID = entry.id
                    }
                }
                .disabled(modelManager.isDownloading || fit == .notEnoughMemory)
            }
        }
    }

    private func fitColor(_ fit: ModelFit) -> Color {
        switch fit {
        case .recommended: return .blue
        case .fits: return .green
        case .willBeSlow: return .orange
        case .notEnoughMemory: return .red
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Advanced

struct AIAdvancedPage: View {
    @Bindable var settings: AppSettings
    let ai: AISettingsModel
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        SettingsPage(pane: .ai, subpage: .aiAdvanced,
                     subtitle: "Most people never need these.") {
            if settings.llmProvider.group != .onThisMac {
                Section {
                    ModelMenuRow(
                        title: "Answers",
                        detail: "Model for chat and Ask.",
                        binding: $settings.queryModel,
                        models: ai.modelsForMenu(selection: settings.queryModel, settings: settings),
                        emptyLabel: "Same as main model",
                        customKey: "query",
                        ai: ai
                    )
                    .settingsAnchor(.taskModels)
                    ModelMenuRow(
                        title: "Summaries",
                        detail: "Model for meeting notes.",
                        binding: $settings.summaryModel,
                        models: ai.modelsForMenu(selection: settings.summaryModel, settings: settings),
                        emptyLabel: "Same as main model",
                        customKey: "summary",
                        ai: ai
                    )
                    Toggle(isOn: Bindable(ai).showAllModels) {
                        Text("Show every model")
                        Text("List everything the provider offers, not just the recommended ones.")
                    }
                    .settingsAnchor(.allModels)
                } header: {
                    Text("Models per task")
                }
            }

            Section {
                ForEach(LLMTaskType.hybridListOrder, id: \.self) { taskType in
                    routeRow(for: taskType)
                }
            } header: {
                Text("Model routing")
                    .settingsAnchor(.routing)
            } footer: {
                Text(settings.llm.hybridEnabled
                     ? "Send a task to a different provider. Default follows the Hybrid list on the AI page."
                     : "Send a task to a different provider. Default uses your main one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                CLISubscriptionRow(vendor: .codex, ai: ai, showsName: true)
                CLISubscriptionRow(vendor: .grok, ai: ai, showsName: true)
            } header: {
                Text("Your subscriptions")
            } footer: {
                Text("LidIA runs each vendor's own CLI, signed in as you, in an empty folder with no tools. It never reads their sign-in files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fallback") {
                Picker(selection: $settings.fallbackProvider) {
                    Text("None").tag("")
                    ForEach(AppSettings.LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                } label: {
                    Text("If the main provider fails")
                    Text("Try this one instead.")
                }
                .settingsAnchor(.fallback)

                if let fallback = AppSettings.LLMProvider(storedValue: settings.fallbackProvider) {
                    ModelMenuRow(
                        title: "Fallback model",
                        binding: $settings.fallbackModel,
                        models: ai.modelsForRouteProvider(fallback, settings: settings, modelManager: modelManager),
                        emptyLabel: "Automatic",
                        customKey: "fallback",
                        ai: ai
                    )
                }

                Picker(selection: $settings.cloudFallbackPolicy) {
                    Text("Ask first").tag(CloudFallbackPolicy.ask)
                    Text("Use the cloud").tag(CloudFallbackPolicy.always)
                    Text("Never use the cloud").tag(CloudFallbackPolicy.never)
                } label: {
                    Text("If the on-device model fails")
                    Text("LidIA never sends meetings to the cloud without this.")
                }
                .settingsAnchor(.cloudFallback)
            }

            Section {
                if settings.llmProvider == .openai {
                    LabeledContent {
                        TextField("OpenAI base URL", text: $settings.openaiBaseURL)
                            .labelsHidden()
                            .frame(maxWidth: 260)
                    } label: {
                        Text("OpenAI server")
                        Text("Change only for a proxy or an Azure deployment.")
                    }
                }
                ForEach(AppSettings.LLMProvider.providers(in: .cloud).filter { $0 != settings.llmProvider }, id: \.self) { provider in
                    APIKeyRow(provider: provider, settings: settings, ai: ai, label: provider.displayName)
                    if provider == .openRouter, !settings.llm.openRouterAPIKey.isEmpty {
                        OpenRouterZDRToggle(settings: settings)
                            .padding(.leading, 16)
                    }
                }
            } header: {
                Text("Other API keys")
                    .settingsAnchor(.otherKeys)
            } footer: {
                Text("Used when routing or fallback picks another provider. Stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Bindable(settings.llm).syncKeysViaICloud) {
                    Text("Sync API keys with iCloud Keychain")
                    Text("Use the same keys on your iPhone. Off keeps them on this Mac.")
                }
                .settingsAnchor(.keySync)
            }
        }
        .onDisappear { settings.llm.commitPendingAPIKeys() }
    }

    @ViewBuilder
    private func routeRow(for taskType: LLMTaskType) -> some View {
        let currentConfig = settings.routeConfig(for: taskType)
        let selectedProvider = Binding<String>(
            get: { currentConfig?.provider.rawValue ?? "default" },
            set: { newValue in
                if newValue == "default" {
                    settings.setRouteConfig(nil, for: taskType)
                } else if let provider = AppSettings.LLMProvider(storedValue: newValue) {
                    let autoModel = ModelMenuCatalog.autoModel(
                        for: provider,
                        availableModels: ai.modelsForRouteProvider(provider, settings: settings, modelManager: modelManager)
                    )
                    settings.setRouteConfig(LLMRouteConfig(provider: provider, model: autoModel), for: taskType)
                }
            }
        )
        let selectedModel = Binding<String>(
            get: { currentConfig?.model ?? "" },
            set: { newValue in
                if let provider = currentConfig?.provider {
                    settings.setRouteConfig(LLMRouteConfig(provider: provider, model: newValue), for: taskType)
                }
            }
        )

        Picker(selection: selectedProvider) {
            Text("Default").tag("default")
            Divider()
            ForEach(AppSettings.LLMProvider.allCases, id: \.self) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
        } label: {
            HStack(spacing: 6) {
                Text(taskType.displayName)
                if let provider = currentConfig?.provider {
                    LocalityBadge(locality: provider.locality(settings: settings), compact: true)
                }
            }
        }

        if let config = currentConfig {
            Picker("\(taskType.displayName) model", selection: selectedModel) {
                Text("Automatic").tag("")
                ForEach(ai.modelsForRouteProvider(config.provider, settings: settings, modelManager: modelManager), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .padding(.leading, 16)
        }
    }
}
