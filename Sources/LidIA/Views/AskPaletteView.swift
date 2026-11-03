import SwiftUI

/// The ⌘K "Ask LidIA" palette. It answers inline, over whatever you are
/// looking at, with the same chat engine, components and thread history as
/// Chats (compact). "Open in Chats" continues the conversation there.
struct AskPaletteView: View {
    @Bindable var viewModel: ChatBarViewModel
    /// Text to ask immediately when the palette opens (e.g. from search).
    var initialQuery: String = ""
    var onClose: () -> Void
    var onOpenThread: (UUID) -> Void

    @State private var hasAsked = false
    @State private var starters: [ChatStarter] = []
    private var source = StartersSource()

    init(viewModel: ChatBarViewModel, initialQuery: String = "", onClose: @escaping () -> Void, onOpenThread: @escaping (UUID) -> Void) {
        self.viewModel = viewModel
        self.initialQuery = initialQuery
        self.onClose = onClose
        self.onOpenThread = onOpenThread
    }

    /// The latest question and answer of this palette session.
    private var lastQuestion: ChatBarMessage? {
        guard hasAsked else { return nil }
        return viewModel.messages.last { $0.role == .user }
    }

    private var lastAnswer: ChatBarMessage? {
        guard hasAsked, !viewModel.isStreaming, let last = viewModel.messages.last, last.role == .assistant else { return nil }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ChatPixelLoader(size: 16)
                    .padding(.top, 4)
                ChatComposer(
                    viewModel: viewModel,
                    placeholder: "Ask anything about your meetings…",
                    chrome: .embedded,
                    autoFocus: true,
                    onSend: ask
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            if hasAsked {
                answerArea
            } else {
                idle
            }
        }
        .environment(\.chatDensity, .compact)
        .frame(width: 680)
        // A backing under the glass keeps the palette legible over busy pages.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.78), in: .rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 34, y: 14)
        .onAppear {
            starters = source.starters()
            #if DEBUG
            // Snapshot runs open the palette on a recorded answer.
            if SnapshotRun.isActive, !viewModel.messages.isEmpty || viewModel.isStreaming { hasAsked = true }
            #endif
            let query = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                viewModel.inputText = query
                ask()
            }
        }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask LidIA")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SUGGESTED")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(starters.prefix(4)) { starter in
                PaletteStarterRow(starter: starter) {
                    viewModel.inputText = starter.prompt
                    ask()
                }
            }
            footer(trailing: "esc to close")
                .padding(.top, 6)
        }
        .padding(10)
    }

    // MARK: - Answer

    private var answerArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let lastQuestion {
                        Text(ChatInline.attributed(lastQuestion.text, size: 15))
                            .font(.system(size: 15, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if viewModel.isStreaming, let run = viewModel.currentRun {
                        ChatAssistantMessage(message: nil, run: run, viewModel: viewModel)
                    } else if let answer = lastAnswer {
                        ChatAssistantMessage(message: answer, run: answer.agentRun, isLatest: true, viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 540)
            .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            HStack(spacing: 10) {
                Button {
                    hasAsked = false
                    viewModel.startNewThread(scope: .allMeetings)
                } label: {
                    Label("New question", systemImage: "plus")
                }
                .disabled(viewModel.isStreaming)
                Spacer()
                if let threadID = viewModel.activeThreadID {
                    Button {
                        onOpenThread(threadID)
                    } label: {
                        Label("Open in Chats", systemImage: "arrow.up.right")
                    }
                    .help("Continue this conversation in Chats")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func footer(trailing: String) -> some View {
        HStack(spacing: 14) {
            Text("@  mention")
            Text("/  commands")
            Spacer()
            Text(trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func ask() {
        guard !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !viewModel.isStreaming else { return }
        if !hasAsked {
            // Each palette session starts its own thread so answers never
            // land in whatever chat happened to be open.
            let text = viewModel.inputText
            let mentions = viewModel.pendingMentions
            viewModel.startNewThread(scope: .allMeetings)
            viewModel.inputText = text
            viewModel.pendingMentions = mentions
        }
        hasAsked = true
        viewModel.send()
    }
}

private struct PaletteStarterRow: View {
    let starter: ChatStarter
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: starter.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(starter.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle = starter.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? ChatStyle.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
