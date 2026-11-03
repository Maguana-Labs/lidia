import LidIAIntelligence
import LidIAKit
import SwiftData
import SwiftUI

/// A conversation turn with the meetings it drew on.
struct AskMessage: Identifiable, Equatable {
    let id = UUID()
    var isUser: Bool
    var text: String
    var sources: [AskSource] = []
    var isStreaming = false
    var failed = false
}

/// Ask your meetings. Runs on this iPhone by default; cites its sources.
@MainActor
@Observable
final class AskModel {
    var messages: [AskMessage] = []
    var input = ""
    private(set) var isAnswering = false
    private var task: Task<Void, Never>?

    func send(_ question: String, documents: [MeetingDocument], scope: UUID?, userName: String, intelligence: Intelligence) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        let history = messages.map { AskEngine.Turn(isUser: $0.isUser, text: $0.text) }
        messages.append(AskMessage(isUser: true, text: trimmed))
        messages.append(AskMessage(isUser: false, text: "", isStreaming: true))
        input = ""
        isAnswering = true
        Haptics.tap()

        task = Task {
            let index = messages.count - 1
            do {
                let engine = AskEngine(generator: try intelligence.generator())
                let (sources, stream) = try await engine.answer(
                    question: trimmed,
                    history: history,
                    documents: documents,
                    userName: userName,
                    scope: scope
                )
                messages[index].sources = sources
                for try await delta in stream {
                    messages[index].text += delta
                }
                // Keep only the sources the answer actually cited, when it cited any.
                let cited = sources.filter { messages[index].text.contains("[\($0.label)]") }
                if !cited.isEmpty { messages[index].sources = cited }
            } catch {
                messages[index].text = error.localizedDescription
                messages[index].failed = true
            }
            messages[index].isStreaming = false
            isAnswering = false
        }
    }

    func stop() {
        task?.cancel()
        isAnswering = false
        if let last = messages.indices.last { messages[last].isStreaming = false }
    }
}

struct AskView: View {
    let scope: AppRouter.AskScope?

    @Environment(Intelligence.self) private var intelligence
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var model = AskModel()
    @FocusState private var focused: Bool

    private var isSheet: Bool { scope != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.messages) { message in
                            MessageView(message: message) { source in
                                open(source)
                            }
                            .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.last?.text) { _, _ in
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Surface.background)
        .safeAreaInset(edge: .bottom) { composer }
        .task {
            guard !isSheet, let question = router.pendingAskQuestion else { return }
            router.pendingAskQuestion = nil
            send(question)
        }
        .navigationTitle(scope?.meetingTitle ?? "Ask")
        .navigationBarTitleDisplayMode(isSheet ? .inline : .large)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            if !model.messages.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.stop()
                        withAnimation(.snappy) { model.messages = [] }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background { HeroBackground() }
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                Text(scope?.meetingID != nil ? "Ask about this meeting" : "Ask your meetings")
                    .font(.title2.weight(.bold))
                Text(scope?.meetingID != nil ? "Decisions, who said what, what to send next." : "Anything you discussed, decided or promised. Answers cite the meetings they come from.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, isSheet ? 8 : 0)

            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        send(suggestion)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text(suggestion)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Surface.card, in: .rect(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            Label(intelligence.engineLabel, systemImage: intelligence.isOnDevice ? "lock.fill" : "cloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var suggestions: [String] {
        if scope?.meetingID != nil {
            return ["What was decided?", "What do I owe people?", "Draft a follow-up email"]
        }
        if let title = scope?.meetingTitle {
            return ["What happened last time in \(title)?", "What’s still open with these people?"]
        }
        return ["What did I promise this week?", "Summarise yesterday’s meetings", "What’s open with Northwind?"]
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask anything about your meetings", text: $model.input, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send(model.input) }
                .padding(.leading, 18)
                .padding(.vertical, 14)
            Button {
                model.isAnswering ? model.stop() : send(model.input)
            } label: {
                Image(systemName: model.isAnswering ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend || model.isAnswering ? Color.accentColor : Color.secondary.opacity(0.4), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !model.isAnswering)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
            .accessibilityLabel(model.isAnswering ? "Stop" : "Send")
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String) {
        let documents = meetings.filter { $0.status == .complete }.prefix(200).map { meeting in
            MeetingDocument(
                id: meeting.id,
                title: meeting.displayTitle,
                date: meeting.date,
                summary: meeting.summaryText,
                notes: meeting.notes,
                transcript: meeting.transcriptText,
                openActionItems: meeting.openItems.map { ($0.assignee.map { "\($0): " } ?? "") + $0.title },
                attendees: meeting.attendeeNames
            )
        }
        model.send(text, documents: Array(documents), scope: scope?.meetingID, userName: settings.firstName, intelligence: intelligence)
    }

    private func open(_ source: AskSource) {
        if isSheet {
            dismiss()
        }
        router.open(source.meetingID)
    }
}

// MARK: - Message

private struct MessageView: View {
    let message: AskMessage
    let onSource: (AskSource) -> Void

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color(hex: Brand.Hex.red).gradient, in: .rect(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background { HeroBackground() }
                        .clipShape(.circle)
                    Text("LidIA")
                        .font(.subheadline.weight(.semibold))
                    if message.isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                }
                if message.text.isEmpty && message.isStreaming {
                    ShimmerLines().frame(maxWidth: 260)
                } else {
                    Text(rendered)
                        .font(.body)
                        .foregroundStyle(message.failed ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.sources.isEmpty && !message.isStreaming {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(message.sources) { source in
                                    Button {
                                        onSource(source)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text("\(source.label)")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 18, height: 18)
                                                .background(Tint.color(for: source.title), in: .circle)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(source.title)
                                                    .font(.footnote.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(Format.day(source.date))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.leading, 8)
                                        .padding(.trailing, 12)
                                        .padding(.vertical, 8)
                                        .background(Surface.card, in: .capsule)
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Markdown inline styling, with citation markers ("[2]") set small and tinted.
    private var rendered: AttributedString {
        // Inline markdown only (block parsing would drop line breaks while streaming); bullets by hand.
        let source = message.text
            .components(separatedBy: "\n")
            .map { line in
                for marker in ["- ", "* "] where line.hasPrefix(marker) { return "•  " + line.dropFirst(2) }
                return line
            }
            .joined(separator: "\n")
        var text = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for source in message.sources {
            let marker = " [\(source.label)]"
            while let range = text.range(of: marker) ?? text.range(of: "[\(source.label)]") {
                var replacement = AttributedString("\u{2009}\(source.label)")
                replacement.font = .caption2.weight(.bold)
                replacement.foregroundColor = Tint.color(for: source.title)
                replacement.baselineOffset = 3
                text.replaceSubrange(range, with: replacement)
            }
        }
        return text
    }
}
