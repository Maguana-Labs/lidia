import SwiftData
import SwiftUI

/// A conversation: a centered reading column of turns, the live answer, and a
/// floating composer docked at the bottom. Used by the Chats workspace and
/// the meeting page's Ask; the ⌘K palette uses the same message views.
struct ChatConversationView<Empty: View>: View {
    @Bindable var viewModel: ChatBarViewModel
    var placeholder = "Ask about your meetings"
    var columnWidth: CGFloat = ChatStyle.column
    var horizontalPadding: CGFloat = 32
    @ViewBuilder var emptyState: () -> Empty

    @Environment(\.chatDensity) private var density

    private var isEmpty: Bool { viewModel.messages.isEmpty && !viewModel.isStreaming }

    var body: some View {
        Group {
            if isEmpty {
                emptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
                    .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: density.messageSpacing) {
                    let lastAssistant = viewModel.messages.lastIndex { $0.role == .assistant }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        Group {
                            if message.role == .user {
                                ChatUserBubble(message: message)
                            } else {
                                ChatAssistantMessage(
                                    message: message,
                                    run: message.agentRun,
                                    isLatest: index == lastAssistant && !viewModel.isStreaming,
                                    viewModel: viewModel
                                )
                            }
                        }
                        .id(message.id)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    if viewModel.isStreaming, let run = viewModel.currentRun {
                        ChatAssistantMessage(message: nil, run: run, viewModel: viewModel)
                            .id("live")
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, density == .regular ? 28 : 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .animation(.snappy(duration: 0.25), value: viewModel.messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.messages.count) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var dock: some View {
        ChatComposer(viewModel: viewModel, placeholder: viewModel.messages.isEmpty ? placeholder : "Ask a follow-up")
            .frame(maxWidth: columnWidth + 16)
            .padding(.horizontal, max(horizontalPadding - 8, 12))
            .padding(.bottom, density == .regular ? 18 : 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                // Text fades out behind the composer instead of running under it.
                LinearGradient(
                    stops: [
                        .init(color: Color(nsColor: .textBackgroundColor).opacity(0), location: 0),
                        .init(color: Color(nsColor: .textBackgroundColor).opacity(0.9), location: 0.55),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
    }
}

// MARK: - Empty states

/// The Chats welcome: a greeting, the composer, and starters from the
/// user's own data (the next meeting, the latest one, open items).
struct ChatWelcomeView: View {
    @Bindable var viewModel: ChatBarViewModel

    @Environment(AppSettings.self) private var settings
    @State private var starters: [ChatStarter] = []
    private var source = StartersSource()

    // Explicit: before Swift 6.4 the private `source` made the memberwise init private.
    init(viewModel: ChatBarViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 40)
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 52, height: 52)
                        ChatPixelLoader(size: 20)
                    }
                    Text(greeting)
                        .font(.system(size: 26, weight: .semibold))
                    Text("Ask anything about your meetings. LidIA searches, reads and cites them.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                ChatComposer(viewModel: viewModel, placeholder: "Ask about your meetings, people or projects", autoFocus: true, suggestionsBelow: true)
                    .zIndex(1)
                    .frame(maxWidth: 680)
                ChatStarterGrid(starters: starters) { starter in
                    viewModel.inputText = starter.prompt
                    viewModel.send()
                }
                .frame(maxWidth: 680)
                HStack(spacing: 16) {
                    hint("@", "mention a meeting, person or project")
                    hint("/", "commands")
                    hint("⌘↩", "send")
                }
                .padding(.top, 2)
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .task { starters = source.starters() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = settings.displayName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
}

/// Two columns of starter cards.
struct ChatStarterGrid: View {
    let starters: [ChatStarter]
    var columns = 2
    var onPick: (ChatStarter) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(starters) { starter in
                ChatStarterCard(starter: starter) { onPick(starter) }
            }
        }
    }
}

struct ChatStarterCard: View {
    let starter: ChatStarter
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.chatDensity) private var density

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: starter.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(hovering ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.title)
                        .font(.system(size: density.bodySize - 0.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = starter.subtitle {
                        Text(subtitle)
                            .font(.system(size: density.smallSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(hovering ? AnyShapeStyle(ChatStyle.hoverFill) : AnyShapeStyle(ChatStyle.cardFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .accessibilityLabel(starter.title)
    }
}

/// Reads what the starters are made of: the next calendar event, the latest
/// meeting with notes, and open action items.
@MainActor
struct StartersSource: DynamicProperty {
    @Environment(\.modelContext) private var modelContext
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor


    func starters(now: Date = .now) -> [ChatStarter] {
        let next = AgendaSource.events(eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor)
            .filter { $0.start > now }
            .min { $0.start < $1.start }
            .map { ChatStarters.MeetingInfo(title: $0.title, date: $0.start) }
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 30
        let latest = ((try? modelContext.fetch(descriptor)) ?? [])
            .first { $0.status == .complete && !$0.summary.isEmpty && !$0.title.isEmpty }
            .map { ChatStarters.MeetingInfo(title: $0.title, date: $0.date) }
        let open = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { !$0.isCompleted }))) ?? []
        let overdue = open.filter { ($0.deadlineDate ?? .distantFuture) < now }.count
        return ChatStarters.make(next: next, latest: latest, openItems: open.count, overdueItems: overdue, now: now)
    }
}
