import AppKit
import SwiftData
import SwiftUI

/// Inline markdown to an `AttributedString`, with citation and mention links
/// styled as small pills.
enum ChatInline {
    static func attributed(_ text: String, size: CGFloat, caret: Bool = false) -> AttributedString {
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)

        // Rebuilt run by run: replacing a run while iterating `runs` would
        // invalidate the remaining ranges.
        var result = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                piece.font = .system(size: size - 1, design: .monospaced)
                piece.backgroundColor = Color.primary.opacity(0.07)
            }
            if let url = run.link, url.scheme == ChatCitations.scheme {
                let number = ChatCitations.number(from: url) ?? 0
                piece = AttributedString("\u{2009}\(number)\u{2009}")
                piece.font = .system(size: size - 3, weight: .semibold).monospacedDigit()
                piece.foregroundColor = Color.accentColor
                piece.backgroundColor = Color.accentColor.opacity(0.13)
                piece.baselineOffset = 2.5
                piece.link = url
            } else if let url = run.link, url.scheme == ChatMentions.scheme {
                piece.foregroundColor = Color.accentColor
                piece.font = .system(size: size, weight: .medium)
                piece.underlineStyle = nil
            }
            result += piece
        }
        if caret {
            var dot = AttributedString(" \u{25CF}")
            dot.foregroundColor = Color.accentColor.opacity(0.8)
            dot.font = .system(size: size - 3)
            result += dot
        }
        return result
    }
}

/// An answer's markdown: blocks, numbered citations, tables, code and
/// interactive action items. Citation clicks open the source meeting.
struct ChatMarkdownView: View {
    let text: String
    var sources: [AgentMeetingRef] = []
    var isStreaming = false
    /// Meeting the action items belong to (the first source), when known.
    var actionMeetingID: UUID?

    @Environment(\.chatDensity) private var density
    @Environment(\.chatOpenMeeting) private var openMeeting

    var body: some View {
        let linked = sources.isEmpty ? text : ChatCitations.link(text, sources: sources).markdown
        let blocks = Self.foldActionHeadings(ChatMarkdown.parse(linked))
        VStack(alignment: .leading, spacing: density.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, item in
                blockView(item.block, title: item.title, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let number = ChatCitations.number(from: url) {
                guard number >= 1, number <= sources.count else { return .discarded }
                let source = sources[number - 1]
                openMeeting(source.id, at: ChatSources.timestamp(in: source.excerpt))
                return .handled
            }
            if url.scheme == ChatMentions.scheme {
                if let mention = ChatMentions.mention(from: url, label: ""), let id = mention.meetingID { openMeeting(id) }
                return .handled
            }
            return .systemAction
        })
    }

    /// A heading right above action items becomes the card's title.
    static func foldActionHeadings(_ blocks: [ChatMarkdown.Block]) -> [(block: ChatMarkdown.Block, title: String?)] {
        var result: [(block: ChatMarkdown.Block, title: String?)] = []
        for block in blocks {
            if case .actionItems = block, let last = result.last, case .heading(_, let text) = last.block {
                result[result.count - 1] = (block, text)
            } else {
                result.append((block, nil))
            }
        }
        return result
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block, title: String? = nil, isLast: Bool) -> some View {
        let caret = isStreaming && isLast
        switch block {
        case .heading(let level, let text):
            Text(ChatInline.attributed(text, size: headingSize(level)))
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            paragraph(text, caret: caret)
        case .list(let ordered, let items):
            ChatListView(ordered: ordered, items: items, caret: caret)
        case .table(let header, let alignments, let rows):
            ChatTableView(header: header, alignments: alignments, rows: rows)
        case .code(let language, let code):
            ChatCodeBlock(language: language, code: code)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.45)).frame(width: 3)
                paragraph(text, caret: caret).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .actionItems(let items):
            ChatActionItemsCard(items: items, title: title ?? "Action items", meetingID: actionMeetingID ?? sources.first?.id)
        }
    }

    private func paragraph(_ text: String, caret: Bool) -> some View {
        Text(ChatInline.attributed(text, size: density.bodySize, caret: caret))
            .font(.system(size: density.bodySize))
            .lineSpacing(density.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: density.bodySize + 4
        case 2: density.bodySize + 2
        case 3: density.bodySize + 0.5
        default: density.bodySize
        }
    }
}

// MARK: - Lists

struct ChatListView: View {
    let ordered: Bool
    let items: [ChatMarkdown.ListItem]
    var caret = false

    @Environment(\.chatDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: density == .regular ? 6 : 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(item, index: index)
                        .frame(minWidth: ordered ? 18 : 10, alignment: ordered ? .trailing : .center)
                    Text(ChatInline.attributed(item.text, size: density.bodySize, caret: caret && index == items.count - 1))
                        .font(.system(size: density.bodySize))
                        .lineSpacing(density.lineSpacing)
                        .strikethrough(item.task == true, color: .secondary)
                        .foregroundStyle(item.task == true ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.indent) * 20)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: ChatMarkdown.ListItem, index: Int) -> some View {
        if let done = item.task {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: density.bodySize - 1))
                .foregroundStyle(done ? Color.accentColor : .secondary)
        } else if ordered && item.indent == 0 {
            Text("\(item.number ?? index + 1).")
                .font(.system(size: density.bodySize).monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Circle()
                .fill(item.indent == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 4.5, height: 4.5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + density.bodySize * 0.28 }
        }
    }
}

// MARK: - Tables

struct ChatTableView: View {
    let header: [String]
    let alignments: [ChatMarkdown.Alignment]
    let rows: [[String]]

    @Environment(\.chatDensity) private var density

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column, isHeader: true)
                    }
                }
                .background(Color.primary.opacity(0.045))
                ForEach(rows.indices, id: \.self) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(column < rows[row].count ? rows[row][column] : "", column: column, isHeader: false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.75))
        }
        .accessibilityLabel("Table with \(rows.count) rows")
    }

    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(ChatInline.attributed(text, size: density.bodySize - 0.5))
            .font(.system(size: density.bodySize - 0.5, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? .primary : .primary)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 70, maxWidth: 280, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, density == .regular ? 8 : 6)
            .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}

// MARK: - Code

struct ChatCodeBlock: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    let lines = code.components(separatedBy: "\n")
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text("\(index + 1)").foregroundStyle(.tertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index].isEmpty ? " " : lines[index])
                        }
                    }
                    .textSelection(.enabled)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.75))
    }
}

// MARK: - Action items

/// Action items in an answer, as rows you can act on: tick (updates the real
/// item when it exists), owner, due date, and Send (add to Action Items, or
/// send an existing item to a configured destination). Nothing runs without
/// a click.
struct ChatActionItemsCard: View {
    let items: [ChatActionItemDraft]
    var title = "Action items"
    var meetingID: UUID?

    @Environment(\.chatDensity) private var density
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .fontWeight(.semibold)
                Text("\(items.count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
            }
            .font(.system(size: density.smallSize + 0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            ForEach(items) { item in
                Divider().opacity(0.6)
                ChatActionItemRow(draft: item, meetingID: meetingID)
            }
        }
        .chatCard()
    }
}

struct ChatActionItemRow: View {
    let draft: ChatActionItemDraft
    var meetingID: UUID?

    @Environment(\.chatDensity) private var density
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager

    @State private var done: Bool?
    @State private var linkedID: UUID?
    @State private var status: String?
    @State private var hovering = false

    private var isDone: Bool { done ?? draft.done }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                toggle()
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: density.bodySize + 2))
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(linkedItem == nil ? "Mark done here" : "Mark done in Action Items")
            .accessibilityLabel(isDone ? "Done" : "Not done")

            VStack(alignment: .leading, spacing: 3) {
                Text(ChatInline.attributed(draft.title, size: density.bodySize))
                    .font(.system(size: density.bodySize))
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.assignee != nil || draft.due != nil || status != nil {
                    HStack(spacing: 8) {
                        if let assignee = draft.assignee {
                            HStack(spacing: 4) {
                                AvatarInitials(name: assignee, size: 15)
                                Text(assignee)
                            }
                        }
                        if let due = draft.due {
                            Label(ChatSources.prettifyDates(due), systemImage: "calendar")
                                .labelStyle(.titleAndIcon)
                        }
                        if let status {
                            Label(status, systemImage: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.system(size: density.smallSize))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            sendMenu
                .opacity(hovering || status != nil ? 1 : 0.55)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, density == .regular ? 9 : 7)
        .background(hovering ? AnyShapeStyle(ChatStyle.hoverFill) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
        .contentShape(.rect)
    }

    private var sendMenu: some View {
        Menu {
            if linkedItem == nil {
                Button("Add to Action Items", systemImage: "plus.circle") { addToActionItems() }
            } else {
                Button("Open in Action Items", systemImage: "checklist") {}
                    .disabled(true)
            }
            Section("Send to") {
                ForEach(AgentDestinations.configured(in: settings).identifiers, id: \.self) { destination in
                    Button(CommentToAction.displayName(destination)) { send(to: destination) }
                }
            }
            Divider()
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.title, forType: .string)
            }
        } label: {
            Label("Send", systemImage: "paperplane")
                .font(.system(size: density.smallSize, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(ChatStyle.hoverFill, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add or send this action item")
    }

    // MARK: Store

    /// The real action item this row names (same title, still in the library).
    private var linkedItem: ActionItem? {
        if let linkedID, let item = LiveModel.actionItem(linkedID, in: modelContext) { return item }
        let wanted = ChatSources.fold(draft.title)
        guard wanted.count >= 6 else { return nil }
        let all = (try? modelContext.fetch(FetchDescriptor<ActionItem>())) ?? []
        return all.first { ChatSources.fold($0.title) == wanted }
    }

    private func toggle() {
        let newValue = !isDone
        withAnimation(.easeOut(duration: 0.15)) { done = newValue }
        if let item = linkedItem {
            item.boardStatus = newValue ? .done : .todo
            try? modelContext.save()
        }
    }

    @discardableResult
    private func addToActionItems() -> ActionItem {
        if let existing = linkedItem { return existing }
        let item = ActionItem(title: draft.title, assignee: draft.assignee)
        item.deadline = draft.due
        if let meetingID, let meeting = (try? modelContext.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })))?.first {
            item.meeting = meeting
            meeting.actionItems.append(item)
        }
        modelContext.insert(item)
        try? modelContext.save()
        linkedID = item.id
        withAnimation { status = "Added" }
        return item
    }

    private func send(to destination: String) {
        let item = addToActionItems()
        if destination == "email" {
            MailComposer.open(to: [], subject: draft.title, body: draft.title)
            withAnimation { status = "Opened in Mail" }
            return
        }
        Task {
            do {
                try await AgentDispatch.confirmAndDispatch(
                    destination: destination, actionItemID: item.id,
                    meetingTitle: item.meeting?.title ?? "", title: draft.title, note: "",
                    settings: settings, eventKitManager: eventKitManager, modelContext: modelContext
                )
                withAnimation { status = "Sent to \(CommentToAction.displayName(destination))" }
            } catch {
                withAnimation { status = error.localizedDescription }
            }
        }
    }
}

/// Initials in a tinted circle.
struct AvatarInitials: View {
    let name: String
    var size: CGFloat = 18

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var tint: Color {
        let palette = Brand.avatarPalette
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
            .accessibilityHidden(true)
    }
}
