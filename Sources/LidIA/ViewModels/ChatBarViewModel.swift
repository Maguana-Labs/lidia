import SwiftUI
import SwiftData

@MainActor
@Observable
final class ChatBarViewModel {

    // MARK: - Suggestion Type

    struct Suggestion: Identifiable {
        let id = UUID()
        let text: String
        let icon: String
    }

    // MARK: - Context Scope

    enum ContextScope: String, CaseIterable, Codable, Sendable {
        case selectedMeeting = "Selected meeting"
        case allMeetings = "All meetings"
        case myNotes = "My notes"
    }

    // MARK: - Thread (value type for views)

    struct ChatThread: Identifiable, Codable, Sendable {
        let id: UUID
        var title: String
        var scope: ContextScope
        let createdAt: Date
        var updatedAt: Date
        var messages: [ChatBarMessage]

        init(
            id: UUID = UUID(),
            title: String,
            scope: ContextScope,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            messages: [ChatBarMessage] = []
        ) {
            self.id = id
            self.title = title
            self.scope = scope
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.messages = messages
        }
    }

    // MARK: - Recording State

    enum RecordingState {
        case idle
        case recording
        case justFinished
    }

    // MARK: - Services

    let dictationService = DictationService()
    let threadStore = ChatThreadStore()
    let contextBuilder = MeetingContextBuilder()

    // MARK: - Chat State

    var messages: [ChatBarMessage] = []
    var inputText = ""
    var isStreaming = false
    var currentStreamingText = ""
    /// What the agent is doing while it works ("Searching meetings…").
    var agentStatus: String?
    /// The answer being worked on, live (phase, steps, reasoning, streaming
    /// text). It moves onto the answer message when done.
    private(set) var currentRun: AgentRun?
    /// For sending confirmed dispatches to Apple Reminders.
    var eventKitManager: EventKitManager?

    var pendingAttachments: [FileAttachment] = []
    /// Meetings, people and projects @-mentioned in the message being written.
    var pendingMentions: [ChatMention] = []
    /// A provider picked in the composer for the next questions; nil follows
    /// the routing in Settings (Hybrid included).
    var providerOverride: AppSettings.LLMProvider?

    // Empty string = auto (ModelRouter decides)
    var modelOverride = ""
    var contextScope: ContextScope = .allMeetings
    var recordingState: RecordingState = .idle

    // MARK: - Forwarded Properties

    var isDictating: Bool { dictationService.isDictating }

    var threads: [ChatThread] {
        get { threadStore.threads }
        set { threadStore.threads = newValue }
    }

    var activeThreadID: UUID? {
        get { threadStore.activeThreadID }
        set { threadStore.activeThreadID = newValue }
    }

    var recentThreads: [ChatThread] {
        threadStore.recentThreads
    }

    // MARK: - Dependencies

    private var settings: AppSettings?
    private var backgroundContext: ModelContext?
    private var modelContext: ModelContext?
    private var modelManager: ModelManager?
    private var streamTask: Task<Void, Never>?

    // MARK: - Configuration

    func configure(settings: AppSettings, modelContext: ModelContext, modelManager: ModelManager? = nil, backgroundContext: ModelContext? = nil) {
        self.settings = settings
        self.modelManager = modelManager
        self.backgroundContext = backgroundContext
        self.modelContext = modelContext
        contextBuilder.configure(modelContext: modelContext)

        // Use background context for chat thread persistence if available
        threadStore.configure(modelContext: backgroundContext ?? modelContext)

        // Wire dictation callback
        dictationService.onTranscription = { [weak self] transcript in
            guard let self else { return }
            if self.inputText.isEmpty {
                self.inputText = transcript
            } else {
                self.inputText += " " + transcript
            }
        }
    }

    func updateSelectedMeeting(_ meeting: Meeting?) {
        contextBuilder.updateSelectedMeeting(meeting)
    }

    // MARK: - Dictation (forwarded)

    func toggleDictation() {
        dictationService.toggleDictation()
    }

    // MARK: - Thread Operations (forwarded)

    func openThread(_ thread: ChatThread) {
        messages = threadStore.openThread(thread)
        contextScope = thread.scope
        inputText = ""
        pendingAttachments = []
        currentStreamingText = ""
    }

    func openThread(id: UUID) {
        guard let msgs = threadStore.openThread(id: id) else { return }
        if let thread = threadStore.threads.first(where: { $0.id == id }) {
            messages = msgs
            contextScope = thread.scope
            inputText = ""
            pendingAttachments = []
            currentStreamingText = ""
        }
    }

    func startNewThread(scope: ContextScope? = nil) {
        streamTask?.cancel()
        streamTask = nil
        threadStore.startNewThread()
        messages = []
        inputText = ""
        pendingAttachments = []
        pendingMentions = []
        currentRun = nil
        currentStreamingText = ""
        isStreaming = false

        if let scope {
            contextScope = scope
        }
    }

    func deleteThread(_ thread: ChatThread) {
        threadStore.deleteThread(thread)
        if activeThreadID == nil {
            startNewThread(scope: contextScope)
        }
    }

    static func makeThreadTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "New chat"
        }

        let words = trimmed.split(separator: " ")
        let headline = words.prefix(8).joined(separator: " ")
        return String(headline)
    }

    // MARK: - Suggestions

    var suggestions: [Suggestion] {
        guard messages.isEmpty, !isStreaming else { return [] }

        switch recordingState {
        case .idle:
            let hasMeetings = (try? contextBuilder.fetchMeetings(limit: 1, includeInProgress: false))?.isEmpty == false
            if hasMeetings {
                return [
                    Suggestion(text: "Summarize this week", icon: "calendar"),
                    Suggestion(text: "Open action items", icon: "checklist"),
                    Suggestion(text: "What did I miss?", icon: "questionmark.bubble"),
                    Suggestion(text: "Draft follow-up email", icon: "envelope"),
                ]
            }
            return [Suggestion(text: "Record your first meeting", icon: "mic.fill")]

        case .recording:
            return [
                Suggestion(text: "Summarize so far", icon: "text.badge.star"),
                Suggestion(text: "Key decisions", icon: "lightbulb"),
                Suggestion(text: "What did I miss?", icon: "questionmark.bubble"),
            ]

        case .justFinished:
            return [
                Suggestion(text: "Generate action items", icon: "checklist"),
                Suggestion(text: "Create title", icon: "textformat"),
                Suggestion(text: "Draft meeting recap", icon: "doc.text"),
            ]
        }
    }

    // MARK: - Send Message

    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        guard let settings else { return }

        if recordingState == .justFinished {
            recordingState = .idle
        }

        // Mentions: links already in the text (a retry) plus those picked now.
        let (plain, carried) = ChatMentions.decode(trimmed)
        var mentions = carried
        for mention in pendingMentions where plain.contains("@" + mention.label) && !mentions.contains(mention) {
            mentions.append(mention)
        }
        let stored = ChatMentions.encode(plain, mentions: mentions)
        let question = Self.agentQuestion(plain: plain, mentions: mentions)

        threadStore.ensureActiveThreadExists(initialPrompt: plain, scope: contextScope)

        let userMessage = ChatBarMessage(
            role: .user,
            text: stored,
            attachments: pendingAttachments
        )
        messages.append(userMessage)

        let attachments = pendingAttachments
        inputText = ""
        pendingAttachments = []
        pendingMentions = []

        let history = agentHistory(messages.dropLast())
        threadStore.syncActiveThread(messages: messages, scope: contextScope)
        var provider = providerOverride
        if let chosen = provider, providerBlockedError(chosen, settings: settings) != nil { provider = nil }
        runAgent(question: question, attachments: attachments, history: history, settings: settings, provider: provider, mentions: mentions)
        SiriCues.asked(plain)
    }

    /// What the agent is asked: a slash command expanded, mentions by name,
    /// and a scope line naming the mentioned meetings, people and projects.
    static func agentQuestion(plain: String, mentions: [ChatMention]) -> String {
        var text = plain
        for mention in mentions { text = text.replacingOccurrences(of: "@" + mention.label, with: mention.label) }
        if let (command, argument) = ChatCommand.parse(text) { text = command.prompt(argument: argument) }
        if let scope = ChatMentions.scopeNote(mentions) { text += "\n\n" + scope }
        return text
    }

    /// Stops the answer being written.
    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        currentRun = nil
        agentStatus = nil
    }

    /// What Ask routes to right now, for the composer's model picker.
    struct RouteSummary: Equatable {
        var model: String
        var place: String
        var locality: DataLocality
    }

    func routeSummary(settings: AppSettings, modelManager: ModelManager?) -> RouteSummary {
        var provider = providerOverride
        if let chosen = provider, providerBlockedError(chosen, settings: settings) != nil { provider = nil }
        let endpoint = AgentEndpoints.resolve(settings: settings, modelManager: modelManager, taskType: .ask, provider: provider)
        return RouteSummary(
            model: ChatModelLabel.pretty(endpoint.modelLabel),
            place: ChatModelLabel.place(locality: endpoint.locality, providerName: endpoint.providerName),
            locality: endpoint.locality
        )
    }

    /// Answers with the agent harness: the model gets a short prompt and the
    /// library tools, and fetches what it needs; nothing else is added. The
    /// transcript of what was sent goes on the answer.
    private func runAgent(
        question: String,
        attachments: [FileAttachment],
        history: [AgentMessage],
        settings: AppSettings,
        provider: AppSettings.LLMProvider?,
        mentions: [ChatMention] = []
    ) {
        guard let toolContextStore = modelContext ?? backgroundContext else { return }
        let endpoint = AgentEndpoints.resolve(settings: settings, modelManager: modelManager, taskType: .ask, provider: provider)
        let configuration = AgentHarness.Configuration.standard(for: endpoint.family, locality: endpoint.locality)
        let destinations = AgentEndpoints.destinations(settings: settings)
        let harness = AgentHarness(endpoint: endpoint, tools: LidIATools.all(destinations: destinations), configuration: configuration)

        var userText = question
        for attachment in attachments {
            userText += "\n\nAttached file \(attachment.name):\n\(attachment.content)"
        }
        var focus: String?
        if contextScope == .selectedMeeting, let meeting = contextBuilder.currentSelectedMeeting {
            focus = "[\(LidIATools.shortID(meeting.id))] \(meeting.title), \(AgentDates.day(meeting.date))"
        }
        if focus == nil, let mentioned = mentions.first(where: { $0.kind == .meeting }), let id = mentioned.meetingID {
            focus = "[\(LidIATools.shortID(id))] \(mentioned.label)" + (mentioned.date.map { ", \(AgentDates.day($0))" } ?? "")
        }
        let prompt = AgentPromptContext(
            task: .ask, toolFormat: .native, tools: [], maxSteps: configuration.maxSteps,
            userName: settings.displayName, focusMeeting: focus,
            userInstructions: AgentEndpoints.userInstructions(settings: settings)
        )
        let toolContext = AgentToolContext(modelContext: toolContextStore, settings: settings, destinations: destinations)

        isStreaming = true
        currentStreamingText = ""
        agentStatus = nil
        let run = harness.makeRun(question: question)
        run.onApproval = { [weak self] approval, choice in
            await self?.handleApproval(approval, choice: choice) ?? .failed("Closed")
        }
        currentRun = run

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isStreaming = false
                self.agentStatus = nil
                self.currentRun = nil
            }
            let result = await harness.run(
                prompt: prompt, history: history, userMessage: userText, context: toolContext, live: run
            ) { [weak self] event in
                guard let self else { return }
                switch event {
                case .text(let delta):
                    self.agentStatus = nil
                    self.currentStreamingText += delta
                case .resetText:
                    self.currentStreamingText = ""
                case .status(let status):
                    self.agentStatus = status
                case .reasoning:
                    break
                }
            }
            if Task.isCancelled || result.outcome == .cancelled { return }

            let finalText = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceTitles = Self.sourceLabels(result.sources)
            let confidence = result.outcome == .failed
                ? .low
                : self.contextBuilder.displayedConfidence(answer: finalText, sourceCount: sourceTitles.count)
            let label = "\(endpoint.modelLabel) · \(endpoint.locality.label)"
            var answer = ChatBarMessage(
                role: .assistant,
                text: finalText,
                sourceMeetings: sourceTitles,
                groundingConfidence: confidence,
                modelLabel: provider.map { "\($0.rawValue): \(label)" } ?? label
            )
            answer.agentTranscript = result.transcript
            answer.pendingActions = result.pendingActions
            answer.agentRun = run
            self.messages.append(answer)
            self.threadStore.syncActiveThread(messages: self.messages, scope: self.contextScope)
            self.currentStreamingText = ""
        }
    }

    /// Source chips: titles, with the date when a title repeats (recurring meetings).
    static func sourceLabels(_ sources: [AgentMeetingRef]) -> [String] {
        let counts = Dictionary(sources.map { ($0.title, 1) }, uniquingKeysWith: +)
        return sources.map { counts[$0.title, default: 0] > 1 ? "\($0.title) · \(AgentDates.day($0.date))" : $0.title }
    }

    /// The user's answer to an approval on an agent run.
    private func handleApproval(_ approval: AgentApproval, choice: AgentApproval.Choice) async -> AgentApproval.State {
        guard let settings, let context = modelContext ?? backgroundContext else { return .failed("Not ready") }
        switch (approval.kind, choice) {
        case (.change(let action), .option):
            let tools = LidIATools.all(destinations: AgentEndpoints.destinations(settings: settings))
            let done = await AgentHarness.confirm(action, tools: tools, context: AgentToolContext(modelContext: context, settings: settings))
            syncPendingAction(done)
            return done.state == .confirmed ? .resolved(done.resultMessage ?? "Done") : .failed(done.resultMessage ?? "Failed")
        case (.dispatch(let proposal), .option):
            if proposal.destination == "email" {
                MailComposer.open(to: [], subject: proposal.title, body: proposal.body)
                return .resolved("Opened in Mail")
            }
            guard let itemID = proposal.actionItemID, let eventKitManager else {
                return .failed("Open the action item on the board to send it.")
            }
            do {
                // Sends only here, after the user chose to.
                try await AgentDispatch.confirmAndDispatch(
                    destination: proposal.destination, actionItemID: itemID,
                    meetingTitle: LiveModel.actionItem(itemID, in: context)?.meeting?.title ?? "",
                    title: proposal.title, note: proposal.body,
                    settings: settings, eventKitManager: eventKitManager, modelContext: context
                )
                return .resolved("Sent to \(CommentToAction.displayName(proposal.destination))")
            } catch {
                return .failed(error.localizedDescription)
            }
        case (.clarification, .option(let optionID)):
            let label = approval.options.first { $0.id == optionID }?.label ?? optionID
            askFollowUp(label)
            return .resolved(label)
        case (_, .freeText(let text)):
            askFollowUp(text)
            return .resolved(text)
        }
    }

    /// Sends a follow-up (a chosen option, free text, or a suggested question).
    func askFollowUp(_ text: String) {
        guard !isStreaming else { return }
        inputText = text
        send()
    }

    private func syncPendingAction(_ action: AgentPendingAction) {
        for index in messages.indices {
            if let actionIndex = messages[index].pendingActions.firstIndex(where: { $0.id == action.id }) {
                messages[index].pendingActions[actionIndex] = action
            }
        }
    }

    /// Earlier turns as agent messages (text only; tool traffic isn't replayed).
    private func agentHistory(_ earlier: ArraySlice<ChatBarMessage>) -> [AgentMessage] {
        earlier.suffix(8).map { message in
            AgentMessage(role: message.role == .user ? .user : .assistant, text: ChatMentions.decode(message.text).plain)
        }
    }

    #if DEBUG
    /// Snapshot runs: show a recorded question and answer in a fresh thread.
    func showSnapshotAnswer(question: String, answer: ChatBarMessage) {
        streamTask?.cancel()
        messages = [ChatBarMessage(role: .user, text: question), answer]
        isStreaming = false
        currentStreamingText = ""
    }

    /// Snapshot runs: a thread whose last answer is still being worked on.
    func showSnapshotRun(earlier: [ChatBarMessage] = [], question: String, run: AgentRun) {
        streamTask?.cancel()
        messages = earlier + [ChatBarMessage(role: .user, text: question)]
        currentRun = run
        isStreaming = true
    }

    /// Snapshot runs: a finished conversation.
    func showSnapshotMessages(_ messages: [ChatBarMessage]) {
        streamTask?.cancel()
        self.messages = messages
        currentRun = nil
        isStreaming = false
        currentStreamingText = ""
    }
    #endif

    // MARK: - Pending actions

    /// Runs a change the agent prepared. Only this (the user's Confirm) runs it.
    func confirmPendingAction(messageID: UUID, actionID: UUID) {
        guard let settings, let context = modelContext ?? backgroundContext,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[index].pendingActions.first(where: { $0.id == actionID }),
              action.state == .pending else { return }
        let tools = LidIATools.all(destinations: AgentEndpoints.destinations(settings: settings))
        let toolContext = AgentToolContext(modelContext: context, settings: settings)
        Task { [weak self] in
            let done = await AgentHarness.confirm(action, tools: tools, context: toolContext)
            guard let self, let index = self.messages.firstIndex(where: { $0.id == messageID }),
                  let actionIndex = self.messages[index].pendingActions.firstIndex(where: { $0.id == actionID }) else { return }
            self.messages[index].pendingActions[actionIndex] = done
        }
    }

    func dismissPendingAction(messageID: UUID, actionID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              let actionIndex = messages[index].pendingActions.firstIndex(where: { $0.id == actionID }) else { return }
        messages[index].pendingActions[actionIndex].state = .dismissed
    }

    // MARK: - Attachments

    func addAttachment(url: URL) {
        let name = url.lastPathComponent
        let content: String

        do {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8) {
                content = String(text.prefix(10_000))
            } else {
                content = "[Binary file: \(name), \(data.count) bytes]"
            }
        } catch {
            content = "[Could not read file: \(error.localizedDescription)]"
        }

        pendingAttachments.append(FileAttachment(name: name, content: content))
    }

    func removeAttachment(_ attachment: FileAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - Retry

    /// Retry the last assistant response by removing it and re-sending the preceding user message.
    func retry(messageID: UUID) {
        guard !isStreaming else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].role == .assistant else { return }
        let userIdx = messages[..<idx].lastIndex(where: { $0.role == .user })
        guard let uIdx = userIdx else { return }
        let userText = messages[uIdx].text
        // Remove both the assistant response AND the user message (send() will re-add it)
        messages.remove(at: idx)
        messages.remove(at: uIdx)
        inputText = userText
        send()
    }

    /// Retry using a specific LLM provider.
    func retryWith(messageID: UUID, provider: AppSettings.LLMProvider) {
        guard !isStreaming, let settings else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].role == .assistant else { return }
        let userIdx = messages[..<idx].lastIndex(where: { $0.role == .user })
        guard let uIdx = userIdx else { return }
        let userText = messages[uIdx].text

        // Privacy first: a provider Local-only mode (or the cloud gate) blocks
        // never gets the conversation. Say why and keep the messages.
        if let blocked = providerBlockedError(provider, settings: settings) {
            messages.append(ChatBarMessage(
                role: .assistant,
                text: "[\(blocked.localizedDescription)]",
                groundingConfidence: .low,
                modelLabel: provider.rawValue
            ))
            threadStore.syncActiveThread(messages: messages, scope: contextScope)
            return
        }

        // Remove both messages, then ask again with that provider (gated client).
        messages.remove(at: idx)
        messages.remove(at: uIdx)
        messages.append(ChatBarMessage(role: .user, text: userText))
        threadStore.syncActiveThread(messages: messages, scope: contextScope)
        runAgent(question: userText, attachments: [], history: agentHistory(messages.dropLast()), settings: settings, provider: provider)
    }

    // MARK: - Conversation Management

    func clearConversation() {
        startNewThread(scope: contextScope)
    }

    // MARK: - Private: Chat Stream Factory

    /// Which chat transport the current settings call for.
    enum ChatStreamKind: Equatable {
        /// OpenAI Responses API over a WebSocket (cloud).
        case openAIWebSocket(apiKey: String, model: String)
        /// Any provider through `makeLLMClient` (gated per request).
        case http
    }

    /// The OpenAI WebSocket is used only when OpenAI is the chat provider, has
    /// a key, and the privacy rules allow it. Otherwise chat goes through
    /// `HTTPChatStream`, whose client comes from the gated factory.
    static func chatStreamKind(settings: AppSettings) -> ChatStreamKind {
        let model = settings.openaiModel.isEmpty
            ? ModelMenuCatalog.autoModel(for: .openai, availableModels: settings.availableModels)
            : settings.openaiModel
        return chatStreamKind(
            chatProvider: resolvedProvider(settings: settings, taskType: .ask),
            defaultProvider: settings.llmProvider,
            openAIAPIKey: settings.openaiAPIKey,
            openAIModel: model,
            openAIAllowed: providerBlockedError(.openai, settings: settings) == nil
        )
    }

    /// Pure core of `chatStreamKind(settings:)`, for tests.
    static func chatStreamKind(
        chatProvider: AppSettings.LLMProvider,
        defaultProvider: AppSettings.LLMProvider,
        openAIAPIKey: String,
        openAIModel: String,
        openAIAllowed: Bool
    ) -> ChatStreamKind {
        guard openAIAllowed, chatProvider == .openai, defaultProvider == .openai, !openAIAPIKey.isEmpty else {
            return .http
        }
        return .openAIWebSocket(apiKey: openAIAPIKey, model: openAIModel)
    }
}
