import SwiftUI

// MARK: - Tool chips

/// "🔍 Searched 6 meetings": one tool call, compact.
struct ChatToolChip: View {
    let step: AgentRun.Step

    @Environment(\.chatDensity) private var density

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if step.status == .running {
                    ChatPixelLoader(size: 9)
                } else {
                    Image(systemName: step.status == .failed ? "exclamationmark.triangle" : ChatStepPresentation.icon(tool: step.toolName))
                        .font(.system(size: density.smallSize - 1, weight: .medium))
                        .foregroundStyle(step.status == .failed ? Color.orange : Color.secondary)
                }
            }
            .frame(width: 12)
            Text(ChatStepPresentation.chipTitle(tool: step.toolName, summary: step.summary, resultCount: step.resultCount))
                .font(.system(size: density.smallSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .help(step.summary)
    }
}

/// Chips wrap onto new lines.
struct ChatFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Thinking

/// "Thought for 4s · 3 steps ›": collapsed above the answer; expands into the
/// steps timeline, the reasoning summary and the context the agent read.
struct ChatThinkingDisclosure: View {
    let run: AgentRun
    var startsExpanded = false

    @State private var expanded: Bool?
    @Environment(\.chatDensity) private var density

    private var isExpanded: Bool { expanded ?? startsExpanded }

    /// Seconds before the answer started (or the whole run).
    private var thinkingSeconds: TimeInterval { run.elapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: density.smallSize - 1, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(run.isFinished ? ChatStepPresentation.thoughtFor(thinkingSeconds) : "Working")
                        .font(.system(size: density.smallSize + 0.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !run.steps.isEmpty {
                        Text("· \(run.steps.count) step\(run.steps.count == 1 ? "" : "s")")
                            .font(.system(size: density.smallSize + 0.5))
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: density.smallSize - 2, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide steps" : "Show steps")

            if !isExpanded, !run.steps.isEmpty {
                ChatFlowLayout {
                    ForEach(run.steps.prefix(4)) { ChatToolChip(step: $0) }
                    if run.steps.count > 4 {
                        Text("+\(run.steps.count - 4)")
                            .font(.system(size: density.smallSize))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                }
            }

            if isExpanded {
                ChatThinkingPanel(run: run)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// The expanded trace: Steps, Reasoning, Context.
struct ChatThinkingPanel: View {
    let run: AgentRun

    @Environment(\.chatDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !run.steps.isEmpty {
                section("Steps") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                            ChatStepRow(step: step, isLast: index == run.steps.count - 1)
                        }
                    }
                }
            }
            let reasoning = run.reasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoning.isEmpty {
                section("Reasoning") {
                    Text(reasoning)
                        .font(.system(size: density.smallSize + 0.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            let context = ChatSources.dedupe(run.meetingsRead + run.meetingsSeen + run.sources).filter { ChatSources.cleanExcerpt($0.excerpt) != nil }
            if !context.isEmpty {
                section("Context", trailing: "\(context.count) passage\(context.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(context) { ChatContextCard(source: $0) }
                    }
                }
            }
        }
        .padding(14)
        .chatCard()
    }

    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                if let trailing {
                    Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }
}

/// One step on the timeline: icon on a rail, summary, results, duration.
struct ChatStepRow: View {
    let step: AgentRun.Step
    let isLast: Bool

    @Environment(\.chatDensity) private var density

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.06)).frame(width: 22, height: 22)
                    if step.status == .running {
                        ChatPixelLoader(size: 10)
                    } else {
                        Image(systemName: ChatStepPresentation.icon(tool: step.toolName))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                }
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatSources.prettifyDates(step.summary))
                    .font(.system(size: density.smallSize + 0.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let count = step.resultCount {
                        Text("\(count) result\(count == 1 ? "" : "s")")
                    }
                    if let duration = step.duration {
                        Text(ChatStepPresentation.elapsed(duration))
                    }
                    switch step.status {
                    case .failed: Text("failed").foregroundStyle(.orange)
                    case .awaitingApproval: Text("waits for you").foregroundStyle(.orange)
                    default: EmptyView()
                    }
                }
                .font(.system(size: density.smallSize - 0.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .padding(.bottom, isLast ? 0 : 12)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        switch step.status {
        case .failed: .orange
        case .awaitingApproval: .orange
        default: .secondary
        }
    }
}

// MARK: - Context cards

/// A passage the agent retrieved: meeting, date, size, excerpt. Collapsible.
struct ChatContextCard: View {
    let source: AgentMeetingRef

    @State private var expanded = false
    @Environment(\.chatOpenMeeting) private var openMeeting

    var body: some View {
        let excerpt = ChatSources.cleanExcerpt(source.excerpt) ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(source.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(ChatSources.shortDate(source.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(excerpt.count) chars")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Text(excerpt)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if expanded {
                Button {
                    openMeeting(source.id, at: ChatSources.timestamp(in: source.excerpt))
                } label: {
                    Label(ChatSources.timestamp(in: source.excerpt) == nil ? "Open meeting" : "Open at this moment", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.accentLink)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Sources

/// "4 sources": stacked dots that open into cards with title, date and the
/// excerpt on hover. Numbers match the inline citations.
struct ChatSourcesRow: View {
    let sources: [AgentMeetingRef]
    var cited: [Int] = []

    @State private var expanded = ChatSnapshotState.sourcesExpanded
    @Environment(\.chatDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    HStack(spacing: -5) {
                        ForEach(Array(sources.prefix(4).enumerated()), id: \.offset) { index, source in
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
                                .background(Circle().fill(Color.accentColor.opacity(0.14)).padding(-0.01))
                                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.75))
                        }
                    }
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                        .font(.system(size: density.smallSize + 0.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: density.smallSize - 2, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(sources.count) sources")

            if expanded {
                ChatFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        ChatSourceCard(number: index + 1, source: source)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

/// One source: number, title, date; hover shows the excerpt; click opens it.
struct ChatSourceCard: View {
    let number: Int
    let source: AgentMeetingRef

    @State private var hovering = false
    @State private var showExcerpt = false
    @Environment(\.chatOpenMeeting) private var openMeeting
    @Environment(\.chatDensity) private var density

    init(number: Int, source: AgentMeetingRef) {
        self.number = number
        self.source = source
        _showExcerpt = State(initialValue: ChatSnapshotState.previewSource == number)
        _hovering = State(initialValue: ChatSnapshotState.previewSource == number)
    }

    var body: some View {
        Button {
            openMeeting(source.id, at: ChatSources.timestamp(in: source.excerpt))
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(.system(size: density.smallSize + 0.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(ChatSources.shortDate(source.date))
                        if ChatSources.timestamp(in: source.excerpt) != nil {
                            Text("·")
                            Image(systemName: "waveform")
                        }
                    }
                    .font(.system(size: density.smallSize - 0.5))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: density == .regular ? 200 : 180, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? AnyShapeStyle(ChatStyle.hoverFill) : AnyShapeStyle(ChatStyle.cardFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            showExcerpt = inside && ChatSources.cleanExcerpt(source.excerpt) != nil
        }
        .popover(isPresented: $showExcerpt, arrowEdge: .bottom) {
            ChatSourcePreview(number: number, source: source)
        }
        .accessibilityLabel("Source \(number): \(source.title), \(ChatSources.shortDate(source.date))")
        .help("Open “\(source.title)”")
    }
}

/// The hover card: title, full date, the excerpt.
struct ChatSourcePreview: View {
    let number: Int
    let source: AgentMeetingRef

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(source.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            Text(source.date.formatted(date: .complete, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let excerpt = ChatSources.cleanExcerpt(source.excerpt) {
                // "[31:40] Name: text" → a time chip and the quote.
                let stamp = excerpt.firstMatch(of: /^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*/)
                let body = stamp.map { String(excerpt[$0.range.upperBound...]) } ?? excerpt
                Text("“\(body)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                if let stamp {
                    Label("Opens the transcript at \(stamp.1)", systemImage: "play.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// DEBUG snapshot runs open what a user would hover or click.
@MainActor
enum ChatSnapshotState {
    #if DEBUG
    static var sourcesExpanded = false
    static var previewSource: Int?
    #else
    static let sourcesExpanded = false
    static let previewSource: Int? = nil
    #endif
}
