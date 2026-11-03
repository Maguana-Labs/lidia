import SwiftUI

/// The Chats workspace: a thread list (titles, dates, search) beside the open
/// conversation, which reads as a centered column with a floating composer.
struct ChatHomeView: View {
    @Bindable var viewModel: ChatBarViewModel
    /// When set, opens this thread on appear.
    var navigateToThreadID: UUID?
    /// Kept for callers that still push thread IDs.
    @Binding var path: NavigationPath

    @AppStorage("chats.showsThreadList") private var showsThreadList = true

    var body: some View {
        HStack(spacing: 0) {
            if showsThreadList {
                ChatThreadList(viewModel: viewModel)
                    .frame(width: 256)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            ChatConversationView(viewModel: viewModel) {
                ChatWelcomeView(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { showsThreadList.toggle() }
                } label: {
                    Label("Chats", systemImage: "list.bullet.rectangle")
                }
                .help(showsThreadList ? "Hide chats" : "Show chats")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.startNewThread(scope: .allMeetings)
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New chat")
            }
        }
        .onAppear {
            if let navigateToThreadID { viewModel.openThread(id: navigateToThreadID) }
        }
        .onChange(of: navigateToThreadID) { _, id in
            if let id { viewModel.openThread(id: id) }
        }
    }

    private var title: String {
        guard !viewModel.messages.isEmpty, let id = viewModel.activeThreadID,
              let thread = viewModel.threads.first(where: { $0.id == id }) else { return "Chats" }
        return thread.title
    }
}

/// A pushed thread (older entry points): the same workspace on that thread.
struct ChatThreadView: View {
    @Bindable var viewModel: ChatBarViewModel
    let threadID: UUID
    let availableModels: [String]

    var body: some View {
        ChatHomeView(viewModel: viewModel, navigateToThreadID: threadID, path: .constant(NavigationPath()))
    }
}

// MARK: - Thread list

struct ChatThreadList: View {
    @Bindable var viewModel: ChatBarViewModel

    @State private var query = ""
    @State private var hovered: UUID?

    private var filtered: [ChatBarViewModel.ChatThread] {
        let threads = viewModel.threads.sorted { $0.updatedAt > $1.updatedAt }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return threads }
        return threads.filter { thread in
            thread.title.localizedStandardContains(needle)
                || thread.messages.contains { ChatMentions.decode($0.text).plain.localizedStandardContains(needle) }
        }
    }

    private var groups: [(String, [ChatBarViewModel.ChatThread])] {
        let calendar = Calendar.current
        let now = Date.now
        var buckets: [(String, [ChatBarViewModel.ChatThread])] = [("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Earlier", [])]
        for thread in filtered {
            let index: Int
            if calendar.isDateInToday(thread.updatedAt) { index = 0 }
            else if calendar.isDateInYesterday(thread.updatedAt) { index = 1 }
            else if now.timeIntervalSince(thread.updatedAt) < 7 * 86_400 { index = 2 }
            else { index = 3 }
            buckets[index].1.append(thread)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("Search chats", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                ChatIconButton(systemImage: "square.and.pencil", help: "New chat") {
                    viewModel.startNewThread(scope: .allMeetings)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: query.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "Your chats appear here" : "No chats match “\(query)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(groups, id: \.0) { group in
                            Text(group.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(group.1) { thread in
                                row(thread)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.primary.opacity(0.015))
    }

    private func row(_ thread: ChatBarViewModel.ChatThread) -> some View {
        let selected = viewModel.activeThreadID == thread.id && !viewModel.messages.isEmpty
        let preview = thread.messages.last { $0.role == .assistant }.map { ChatMarkdownPreview.line($0.text) }
        return Button {
            viewModel.openThread(thread)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if thread.scope == .selectedMeeting {
                        Image(systemName: "calendar")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Text(thread.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.time(thread.updatedAt))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : hovered == thread.id ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? thread.id : (hovered == thread.id ? nil : hovered) }
        .contextMenu {
            Button("Delete Chat", role: .destructive) { viewModel.deleteThread(thread) }
        }
        .accessibilityLabel("\(thread.title), \(Self.time(thread.updatedAt))")
    }

    static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Date.now.timeIntervalSince(date) < 7 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return ChatSources.shortDate(date)
    }
}

/// One line of an answer for a list preview: markdown and IDs stripped.
enum ChatMarkdownPreview {
    static func line(_ text: String) -> String {
        var plain = ChatMentions.decode(text).plain
        plain = plain.replacing(/\[[0-9a-fA-F]{8}\]/, with: "")
        plain = plain.replacing(/[#*_`>|]/, with: "")
        plain = plain.replacing(/^\s*[-•]\s+/.anchorsMatchLineEndings(), with: "")
        return plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}
