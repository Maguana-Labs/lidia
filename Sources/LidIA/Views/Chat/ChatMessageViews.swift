import AppKit
import SwiftUI

// MARK: - User

/// The user's turn: a compact bubble on the right of the reading column.
struct ChatUserBubble: View {
    let message: ChatBarMessage

    @Environment(\.chatDensity) private var density
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        Label(attachment.name, systemImage: "doc")
                            .font(.system(size: density.smallSize))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
            }
            Text(ChatInline.attributed(message.text, size: density.bodySize))
                .font(.system(size: density.bodySize))
                .lineSpacing(density.lineSpacing - 1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        ChatIconButton(systemImage: "doc.on.doc", help: "Copy") {
                            copy(ChatMentions.decode(message.text).plain)
                        }
                        .offset(x: -30, y: 0)
                        .transition(.opacity)
                    }
                }
        }
        .frame(maxWidth: density == .regular ? 520 : 300, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(ChatMentions.decode(message.text).plain)")
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Assistant

/// One answer, no bubble: thinking, the answer with citations, sources,
/// approvals, actions and the model line, then follow-ups.
struct ChatAssistantMessage: View {
    /// The finished message (nil while streaming).
    let message: ChatBarMessage?
    let run: AgentRun?
    var isLatest = false
    var viewModel: ChatBarViewModel

    @Environment(\.chatDensity) private var density
    @Environment(AppSettings.self) private var settings

    private var isStreaming: Bool { message == nil && !(run?.isFinished ?? true) }

    private var text: String { message?.text ?? run?.answer ?? "" }

    private var sources: [AgentMeetingRef] { ChatSources.dedupe(run?.liveSources ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: density.blockSpacing + 2) {
            if let run {
                if isStreaming, run.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ChatWorkingRow(run: run)
                        if !run.steps.isEmpty {
                            ChatFlowLayout {
                                ForEach(run.steps.filter { $0.status != .running }) { ChatToolChip(step: $0) }
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: run.steps.count)
                } else if !run.steps.isEmpty || !run.reasoningSummary.isEmpty {
                    ChatThinkingDisclosure(run: run, startsExpanded: Self.snapshotExpandsThinking)
                }
            }

            if !text.isEmpty {
                ChatRevealingMarkdown(text: text, sources: sources, isStreaming: isStreaming)
                    .textSelection(.enabled)
            }

            if let error = run?.errorMessage, run?.phase == .failed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: density.smallSize))
                    .foregroundStyle(.orange)
            }

            if !isStreaming {
                if !sources.isEmpty {
                    ChatSourcesRow(sources: sources, cited: ChatCitations.link(text, sources: sources).cited)
                } else if let message, run == nil, !message.sourceMeetings.isEmpty {
                    legacySources(message.sourceMeetings)
                }

                if let run, !run.approvals.isEmpty {
                    ChatApprovalCard(run: run, meetingsRead: run.steps.filter { $0.toolName == "get_meeting" }.count)
                } else if let message, run == nil, !message.pendingActions.isEmpty {
                    AgentPendingActionsView(
                        actions: message.pendingActions,
                        onConfirm: { viewModel.confirmPendingAction(messageID: message.id, actionID: $0.id) },
                        onDismiss: { viewModel.dismissPendingAction(messageID: message.id, actionID: $0.id) }
                    )
                }

                if let message {
                    ChatAnswerActions(message: message, run: run, viewModel: viewModel)
                }

                if isLatest, let run, !run.followUps.isEmpty, run.approvals.allSatisfy({ $0.state != .pending }) {
                    ChatFollowUps(followUps: run.followUps) { viewModel.askFollowUp($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legacySources(_ titles: [String]) -> some View {
        ChatFlowLayout {
            ForEach(titles, id: \.self) { title in
                Label(title, systemImage: "doc.text")
                    .font(.system(size: density.smallSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
        }
    }

    #if DEBUG
    @MainActor static var snapshotExpandsThinking = false
    #else
    static let snapshotExpandsThinking = false
    #endif
}

/// Reveals streamed text at a steady pace instead of in bursts. Shows the
/// whole text at once under Reduce Motion or when not streaming.
struct ChatRevealingMarkdown: View {
    let text: String
    let sources: [AgentMeetingRef]
    let isStreaming: Bool

    @State private var shown = 0
    @State private var target = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let smooth = isStreaming && !reduceMotion
        ChatMarkdownView(
            text: smooth ? String(text.prefix(shown)) : text,
            sources: sources,
            isStreaming: isStreaming
        )
        .onChange(of: text.count, initial: true) { _, count in target = count }
        .task(id: smooth) {
            guard smooth else { return }
            while !Task.isCancelled {
                if shown < target {
                    let backlog = target - shown
                    shown = min(target, shown + max(2, backlog / 6))
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}

// MARK: - Actions

/// Copy · Retry · Model · View what was sent, and "Model · where it ran".
struct ChatAnswerActions: View {
    let message: ChatBarMessage
    let run: AgentRun?
    var viewModel: ChatBarViewModel

    @Environment(\.chatDensity) private var density
    @Environment(AppSettings.self) private var settings
    @State private var copied = false
    @State private var showsTranscript = false

    private var modelLine: String? {
        if let run { return ChatModelLabel.line(model: run.modelLabel, locality: run.locality, providerName: run.providerName) }
        return message.modelLabel.map(ChatModelLabel.line(stored:))
    }

    private var locality: DataLocality? { run?.locality ?? message.agentTranscript?.locality }

    var body: some View {
        HStack(spacing: 2) {
            ChatIconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy answer") {
                copy(Self.plainAnswer(message.text))
                withAnimation { copied = true }
                Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
            }
            ChatIconButton(systemImage: "arrow.clockwise", help: "Retry") {
                viewModel.retry(messageID: message.id)
            }
            .disabled(viewModel.isStreaming)
            Menu {
                Section("Retry with") {
                    ForEach(ChatProviderOptions.available(settings: settings), id: \.self) { provider in
                        if let reason = providerMenuDisabledReason(provider, settings: settings) {
                            Button("\(provider.displayName) (\(reason))") {}.disabled(true)
                        } else {
                            Button {
                                viewModel.retryWith(messageID: message.id, provider: provider)
                            } label: {
                                Text("\(provider.displayName) · \(ChatModelLabel.place(locality: provider.locality(settings: settings), providerName: provider.displayName))")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Answer again with another model")
            .disabled(viewModel.isStreaming)

            if let transcript = message.agentTranscript ?? run?.transcript {
                Button {
                    showsTranscript = true
                } label: {
                    Label("What was sent", systemImage: transcript.locality == .cloud ? "eye" : "lock.shield")
                        .font(.system(size: density.smallSize))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("See exactly what was sent to the model and where it ran")
                .sheet(isPresented: $showsTranscript) {
                    ChatTranscriptSheet(transcript: transcript)
                }
            }

            Spacer(minLength: 12)

            if let modelLine {
                HStack(spacing: 5) {
                    if let locality {
                        Image(systemName: locality.systemImage)
                            .font(.system(size: density.smallSize - 1))
                    }
                    Text(modelLine)
                        .lineLimit(1)
                }
                .font(.system(size: density.smallSize))
                .foregroundStyle(.tertiary)
                .help(locality == .cloud ? "Sent to the cloud with your key" : "Nothing left this Mac")
            }
        }
        .padding(.leading, -6)
    }

    /// The answer without tool IDs, for the clipboard.
    static func plainAnswer(_ text: String) -> String {
        text.replacing(/\s?\[[0-9a-fA-F]{8}\]/, with: "")
    }
}

/// Providers the user configured, for "Retry with" and the model picker.
enum ChatProviderOptions {
    @MainActor
    static func available(settings: AppSettings) -> [AppSettings.LLMProvider] {
        var providers: [AppSettings.LLMProvider] = []
        if settings.llmProvider == .ollama || !settings.ollamaURL.isEmpty { providers.append(.ollama) }
        if settings.llmProvider == .lmStudio { providers.append(.lmStudio) }
        providers.append(.mlx)
        if !settings.openaiAPIKey.isEmpty { providers.append(.openai) }
        if !settings.anthropicAPIKey.isEmpty { providers.append(.anthropic) }
        if !settings.cerebrasAPIKey.isEmpty { providers.append(.cerebras) }
        if !settings.deepseekAPIKey.isEmpty { providers.append(.deepseek) }
        if !settings.nvidiaAPIKey.isEmpty { providers.append(.nvidiaNIM) }
        if !settings.openRouterAPIKey.isEmpty { providers.append(.openRouter) }
        if settings.llm.hybridEnabled, !providers.contains(settings.llm.hybridCloudProvider) { providers.append(settings.llm.hybridCloudProvider) }
        if !providers.contains(settings.llmProvider) { providers.insert(settings.llmProvider, at: 0) }
        return providers
    }
}

// MARK: - Follow-ups

struct ChatFollowUps: View {
    let followUps: [String]
    var onAsk: (String) -> Void

    @Environment(\.chatDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(followUps.prefix(3).enumerated()), id: \.offset) { index, question in
                if index > 0 { Divider().opacity(0.5) }
                ChatFollowUpRow(question: question) { onAsk(question) }
            }
        }
        .padding(.top, 2)
    }
}

private struct ChatFollowUpRow: View {
    let question: String
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.chatDensity) private var density

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: density.smallSize - 1, weight: .semibold))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.7))
                Text(ChatSources.prettifyDates(question))
                    .font(.system(size: density.bodySize - 0.5))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: density.smallSize - 1, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, density == .regular ? 9 : 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Ask: \(question)")
    }
}

// MARK: - What was sent

/// The run's transcript in a sheet: where it ran, the model, everything sent.
struct ChatTranscriptSheet: View {
    let transcript: AgentTranscript

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transcript.locality.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(transcript.locality == .cloud ? Color.orange : Color.green)
                    .frame(width: 34, height: 34)
                    .background((transcript.locality == .cloud ? Color.orange : Color.green).opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("What was sent")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(ChatModelLabel.line(model: transcript.model, locality: transcript.locality, providerName: transcript.providerName)) · \(String(format: "%.1f", transcript.seconds))s")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            AgentTranscriptView(transcript: transcript, maxHeight: .infinity)
                .padding(14)
        }
        .frame(width: 680, height: 620)
    }
}
