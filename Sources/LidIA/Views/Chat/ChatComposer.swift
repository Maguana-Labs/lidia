import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The prompt bar: @ mentions (meetings, people, projects) that scope the
/// agent, / commands, attachments, dictation, the model picker, and ⌘↩ to send.
struct ChatComposer: View {
    enum Chrome {
        /// Floating Liquid Glass bar (Chats, meeting inspector).
        case floating
        /// Inside another surface (the ⌘K palette): no own background.
        case embedded
    }

    @Bindable var viewModel: ChatBarViewModel
    var placeholder = "Ask about your meetings"
    var chrome: Chrome = .floating
    var autoFocus = false
    /// Open the @ / list below the composer (when it sits high, e.g. the welcome).
    var suggestionsBelow = false
    /// Runs instead of `viewModel.send()` (e.g. the palette starts a thread first).
    var onSend: (() -> Void)?

    @Environment(\.chatDensity) private var density
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @FocusState private var focused: Bool
    @State private var candidates: [ChatMention]?
    @State private var highlighted = 0
    @State private var dismissedTrigger: String.Index?
    @State private var importing = false
    @State private var panelHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0

    private var trigger: ChatMentions.Trigger? {
        guard let trigger = ChatMentions.activeTrigger(in: viewModel.inputText), trigger.start != dismissedTrigger else { return nil }
        return trigger
    }

    private var suggestions: [ChatSuggestion] {
        guard let trigger else { return [] }
        if trigger.symbol == "/" {
            return ChatCommand.matching(trigger.query).map { .command($0) }
        }
        return ChatMentions.filter(candidates ?? [], query: trigger.query, limit: 6).map { .mention($0) }
    }

    private var hasInput: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: chrome == .embedded ? 8 : 10) {
            if !viewModel.pendingMentions.isEmpty || !viewModel.pendingAttachments.isEmpty {
                contextChips
            }
            field
            controls
        }
        .padding(.horizontal, chrome == .embedded ? 0 : 14)
        .padding(.top, chrome == .embedded ? 0 : 12)
        .padding(.bottom, chrome == .embedded ? 0 : 10)
        .background {
            if chrome == .floating {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .shadow(color: .black.opacity(focused ? 0.12 : 0.07), radius: focused ? 18 : 12, y: 4)
            }
        }
        .overlay {
            if chrome == .floating {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.35) : ChatStyle.cardStroke, lineWidth: focused ? 1 : 0.5)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .overlay(alignment: .topLeading) {
            // Floating composers open the list above (they sit low); the
            // palette's opens below, over its answer area.
            if !suggestions.isEmpty {
                ChatSuggestionPanel(suggestions: suggestions, highlighted: highlighted) { pick($0) }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    .offset(y: chrome == .floating && !suggestionsBelow ? -(panelHeight + 8) : composerHeight + 8)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.snappy(duration: 0.18), value: suggestions.count)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .json, .commaSeparatedText, .pdf, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                viewModel.addAttachment(url: url)
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
        .onAppear { if autoFocus { focused = true } }
        .onChange(of: viewModel.inputText) { _, text in
            highlighted = 0
            if let dismissed = dismissedTrigger, dismissed >= text.endIndex || ChatMentions.activeTrigger(in: text)?.start != dismissed {
                dismissedTrigger = nil
            }
            if trigger?.symbol == "@", candidates == nil { candidates = ChatMentionCatalog.candidates(in: modelContext, userName: settings.displayName) }
            // A mention whose "@Label" was deleted no longer scopes the question.
            viewModel.pendingMentions.removeAll { !text.contains("@" + $0.label) }
        }
    }

    // MARK: Field

    private var field: some View {
        TextField(placeholder, text: $viewModel.inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: chrome == .embedded ? 17 : density.bodySize + 0.5))
            .lineLimit(1...(chrome == .embedded ? 4 : 8))
            .focused($focused)
            .onSubmit(submit)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.tab) { pickHighlighted() }
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.command) { submit(); return .handled }
                return suggestions.isEmpty ? .ignored : pickHighlighted()
            }
            .onKeyPress(.escape) {
                guard let trigger else { return .ignored }
                dismissedTrigger = trigger.start
                return .handled
            }
            .accessibilityLabel("Message")
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func pickHighlighted() -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        pick(suggestions[min(highlighted, suggestions.count - 1)])
        return .handled
    }

    private func pick(_ suggestion: ChatSuggestion) {
        guard let trigger else { return }
        switch suggestion {
        case .command(let command):
            viewModel.inputText = ChatMentions.complete(viewModel.inputText, trigger: trigger, with: command.rawValue)
        case .mention(let mention):
            viewModel.inputText = ChatMentions.complete(viewModel.inputText, trigger: trigger, with: mention.label)
            if !viewModel.pendingMentions.contains(mention) { viewModel.pendingMentions.append(mention) }
        }
        focused = true
    }

    private func submit() {
        guard hasInput, !viewModel.isStreaming else { return }
        if let onSend { onSend() } else { viewModel.send() }
    }

    // MARK: Chips

    private var contextChips: some View {
        ChatFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(viewModel.pendingMentions) { mention in
                chip(icon: mention.kind.icon, text: mention.label, tint: .accentColor) {
                    viewModel.pendingMentions.removeAll { $0 == mention }
                    viewModel.inputText = viewModel.inputText.replacingOccurrences(of: "@" + mention.label + " ", with: "")
                        .replacingOccurrences(of: "@" + mention.label, with: "")
                }
            }
            ForEach(viewModel.pendingAttachments) { attachment in
                chip(icon: "doc", text: attachment.name, tint: .secondary) {
                    viewModel.removeAttachment(attachment)
                }
            }
        }
    }

    private func chip(icon: String, text: String, tint: Color, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .font(.system(size: density.smallSize))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.1), in: Capsule())
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 4) {
            composerButton("paperclip", help: "Attach a file") { importing = true }
            composerButton("at", help: "Mention a meeting, person or project") { insertTrigger("@") }
            composerButton("slash.circle", help: "Commands: /summarize, /follow-up, /actions, /prep") { insertTrigger("/") }
            ChatModelPicker(viewModel: viewModel)
                .padding(.leading, 2)
            Spacer(minLength: 6)
            ChatDictationButton(viewModel: viewModel) { focused = true }
            sendButton
        }
    }

    private func composerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        ChatIconButton(systemImage: symbol, help: help, action: action)
    }

    private func insertTrigger(_ symbol: String) {
        if symbol == "/" {
            guard viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            viewModel.inputText = "/"
        } else {
            let text = viewModel.inputText
            viewModel.inputText = text + (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@"
        }
        focused = true
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isStreaming {
            Button {
                viewModel.stopStreaming()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.85), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop")
            .accessibilityLabel("Stop answering")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hasInput ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(hasInput ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
                    .animation(.easeOut(duration: 0.15), value: hasInput)
            }
            .buttonStyle(.plain)
            .disabled(!hasInput)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
            .accessibilityLabel("Send")
        }
    }
}

// MARK: - Suggestions

enum ChatSuggestion: Identifiable, Hashable {
    case command(ChatCommand)
    case mention(ChatMention)

    var id: String {
        switch self {
        case .command(let command): "cmd:" + command.rawValue
        case .mention(let mention): mention.id
        }
    }
}

struct ChatSuggestionPanel: View {
    let suggestions: [ChatSuggestion]
    let highlighted: Int
    var onPick: (ChatSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onPick(suggestion) } label: {
                    row(suggestion, isHighlighted: index == highlighted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 340, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
    }

    private var header: String {
        if case .command = suggestions.first { return "COMMANDS" }
        return "MENTION"
    }

    private func row(_ suggestion: ChatSuggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(suggestion))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                .frame(width: 24, height: 24)
                .background(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title(suggestion)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let subtitle = subtitle(suggestion) {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHighlighted ? ChatStyle.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
    }

    private func icon(_ suggestion: ChatSuggestion) -> String {
        switch suggestion {
        case .command(let command): command.icon
        case .mention(let mention): mention.kind.icon
        }
    }

    private func title(_ suggestion: ChatSuggestion) -> String {
        switch suggestion {
        case .command(let command): "/" + command.rawValue
        case .mention(let mention): mention.label
        }
    }

    private func subtitle(_ suggestion: ChatSuggestion) -> String? {
        switch suggestion {
        case .command(let command): command.detail
        case .mention(let mention):
            switch mention.kind {
            case .meeting: mention.date.map { "Meeting · " + ChatSources.shortDate($0) } ?? "Meeting"
            case .person: "Person"
            case .project: "Project"
            }
        }
    }
}

/// What can be @-mentioned: recent meetings, the people in them, projects.
@MainActor
enum ChatMentionCatalog {
    static func candidates(in context: ModelContext, userName: String) -> [ChatMention] {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 200
        let meetings = ((try? context.fetch(descriptor)) ?? []).filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }

        var result: [ChatMention] = []
        var seenTitles = Set<String>()
        for meeting in meetings {
            // Recurring meetings: the latest one by title, older ones by date.
            let key = ChatSources.fold(meeting.title) + (seenTitles.contains(ChatSources.fold(meeting.title)) ? AgentDates.day(meeting.date) : "")
            guard seenTitles.insert(key).inserted else { continue }
            result.append(ChatMention(kind: .meeting, key: meeting.id.uuidString, label: meeting.title, date: meeting.date))
        }

        var projects: [String] = []
        for meeting in meetings {
            if let project = ProjectCatalog.project(ofFolder: meeting.folder), !projects.contains(where: { ProjectCatalog.fold($0) == ProjectCatalog.fold(project) }) {
                projects.append(project)
            }
        }
        for name in IntelligenceStore.shared.state.knownProjects where !projects.contains(where: { ProjectCatalog.fold($0) == ProjectCatalog.fold(name) }) {
            projects.append(name)
        }
        result += projects.map { ChatMention(kind: .project, key: $0, label: $0) }

        var people: [String] = []
        let me = AttendeeParser.fold(userName)
        for meeting in meetings.prefix(120) {
            for attendee in AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: userName) where !attendee.isCurrentUser {
                let name = attendee.name.trimmingCharacters(in: .whitespaces)
                guard name.count > 1, !name.contains("@"), AttendeeParser.fold(name) != me,
                      !people.contains(where: { AttendeeParser.fold($0) == AttendeeParser.fold(name) }) else { continue }
                people.append(name)
            }
        }
        result += people.prefix(150).map { ChatMention(kind: .person, key: $0, label: $0) }
        return result
    }
}

// MARK: - Model picker

/// "Qwen 3.5 4B · On this Mac": what Ask routes to (Hybrid included), and a
/// menu to pick another provider for the next questions.
struct ChatModelPicker: View {
    @Bindable var viewModel: ChatBarViewModel

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.chatDensity) private var density
    @State private var route: ChatBarViewModel.RouteSummary?
    @State private var hovering = false

    var body: some View {
        Menu {
            Button {
                viewModel.providerOverride = nil
            } label: {
                ChatHelpers.menuRow(settings.llm.hybridEnabled ? "Automatic (Hybrid)" : "Automatic", selected: viewModel.providerOverride == nil)
            }
            Section("Answer with") {
                ForEach(ChatProviderOptions.available(settings: settings), id: \.self) { provider in
                    let place = ChatModelLabel.place(locality: provider.locality(settings: settings), providerName: provider.displayName)
                    if let reason = providerMenuDisabledReason(provider, settings: settings) {
                        Button("\(provider.displayName) (\(reason))") {}.disabled(true)
                    } else {
                        Button {
                            viewModel.providerOverride = provider
                        } label: {
                            ChatHelpers.menuRow("\(provider.displayName) · \(place)", selected: viewModel.providerOverride == provider)
                        }
                    }
                }
            }
            Divider()
            SettingsLink { Text("AI Settings…") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: (route?.locality ?? .onDevice).systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(route.map { "\($0.model) · \($0.place)" } ?? "Automatic")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: density.smallSize, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(hovering ? AnyShapeStyle(ChatStyle.hoverFill) : AnyShapeStyle(Color.primary.opacity(0.04)), in: Capsule())
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("The model that answers, and where it runs")
        .task(id: refreshKey) { route = viewModel.routeSummary(settings: settings, modelManager: modelManager) }
    }

    private var refreshKey: String {
        "\(viewModel.providerOverride?.rawValue ?? "auto")|\(settings.llmProvider.rawValue)|\(settings.llm.hybridEnabled)|\(settings.llm.hybridCloudProvider.rawValue)|\(settings.localOnlyMode)"
    }
}

// MARK: - Dictation

/// Dictation into the composer: LidIA's system dictation when it's on (types
/// at the cursor, here), else the chat's own speech-to-text.
struct ChatDictationButton: View {
    @Bindable var viewModel: ChatBarViewModel
    var focusComposer: () -> Void

    private var controller: DictationController { DictationController.shared }

    private var usesSystemDictation: Bool { controller.status != .off && controller.status != .needsAccessibility }

    private var isListening: Bool {
        usesSystemDictation ? (controller.status == .listening || controller.status == .finishing) : viewModel.isDictating
    }

    var body: some View {
        Button {
            focusComposer()
            if usesSystemDictation {
                if isListening { controller.finish() } else { controller.start() }
            } else {
                viewModel.toggleDictation()
            }
        } label: {
            Image(systemName: isListening ? "waveform" : "mic")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isListening ? Brand.red : Color.secondary)
                .symbolEffect(.variableColor.iterative, isActive: isListening)
                .frame(width: 28, height: 28)
                .background(isListening ? Brand.red.opacity(0.12) : Color.clear, in: Circle())
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(isListening ? "Stop dictation" : "Dictate")
        .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")
    }
}
