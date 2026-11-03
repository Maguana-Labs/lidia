import SwiftData
import SwiftUI

/// Sections of the meeting document that shortcuts can jump to.
enum MeetingDocumentSection: String, Sendable {
    case summary
    case actionItems
    case notes
}

/// A one-shot request to scroll the document to a section.
struct MeetingDocumentScrollRequest: Equatable {
    var section: MeetingDocumentSection
    var nonce = UUID()
}

/// The meeting page body. AI Notes: the summary (merged with your notes),
/// action items and a feedback bar; while processing, the summary as it is
/// written. My Notes: your own notes, editable.
struct MeetingDocumentView<Top: View, Feedback: View>: View {
    @Bindable var meeting: Meeting
    var mode: MeetingNotesMode
    /// Non-nil while the pipeline is writing the summary.
    var streamingText: String?
    /// "Written by AI with the General template", shown under the summary.
    var summaryCaption: String?
    var isResummarizing: Bool
    var scrollRequest: MeetingDocumentScrollRequest?
    var notesFocused: FocusState<Bool>.Binding
    /// The meeting is being transcribed or summarised (notes are on their way).
    var isProcessing = false
    var onEditSummary: () -> Void
    /// Writes notes from the transcript; nil when that isn't possible now.
    var onGenerateNotes: (() -> Void)? = nil
    @ViewBuilder var top: () -> Top
    @ViewBuilder var feedback: () -> Feedback

    @Environment(\.modelContext) private var modelContext

    @State private var structured: StructuredSummary?
    @State private var newActionItemTitle = ""
    @FocusState private var addItemFocused: Bool

    static var columnWidth: CGFloat { 720 }

    private var editedSummary: String? {
        let edited = meeting.userEditedSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? nil : edited
    }

    private var hasSummary: Bool {
        editedSummary != nil || structured != nil || !meeting.summary.isEmpty
    }

    private var liveItems: [ActionItem] {
        meeting.actionItems.filter { !$0.isDeleted }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    top()

                    switch mode {
                    case .ai:
                        aiNotes
                    case .mine:
                        notesSection.id(MeetingDocumentSection.notes)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 96)
                .frame(maxWidth: Self.columnWidth + 64, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(request.section, anchor: .top)
                    }
                }
            }
        }
        .onChange(of: meeting.structuredSummary, initial: true) { _, data in
            structured = data.flatMap { try? JSONDecoder().decode(StructuredSummary.self, from: $0) }
        }
    }

    // MARK: - AI notes

    @ViewBuilder
    private var aiNotes: some View {
        if let streamingText {
            StreamingSummaryView(text: streamingText)
                .id(MeetingDocumentSection.summary)
        } else if hasSummary {
            summarySection.id(MeetingDocumentSection.summary)
        } else {
            noSummary.id(MeetingDocumentSection.summary)
        }
        actionItemsSection.id(MeetingDocumentSection.actionItems)
        if streamingText == nil && hasSummary {
            feedback()
        }
    }

    @ViewBuilder
    private var noSummary: some View {
        if isProcessing {
            // Just stopped: the transcript is in the inspector; notes stream in here.
            VStack(alignment: .leading, spacing: 10) {
                WritingIndicator(title: "Getting the transcript ready…")
                Text("The notes appear here as they're written. The transcript is on the right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let onGenerateNotes {
            VStack(alignment: .leading, spacing: 12) {
                Text("No AI notes yet")
                    .font(.headline)
                Text("Write notes from the transcript, merged with anything you typed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(action: onGenerateNotes) {
                    Label("Generate Notes", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Writes AI notes from this meeting's transcript")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No AI notes yet")
                    .font(.headline)
                Text(meeting.rawTranscript.isEmpty && meeting.refinedTranscript.isEmpty
                     ? "Record the meeting, or write your notes in My Notes."
                     : "Generate notes from the transcript with More › Regenerate Notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let editedSummary {
                MarkdownBlockView(text: editedSummary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let structured {
                StructuredSummaryDocument(
                    summary: structured,
                    onCreateActionItem: { item in
                        item.meeting = meeting
                        meeting.actionItems.append(item)
                        try? modelContext.save()
                    }
                )
            } else {
                MarkdownBlockView(text: meeting.summary, textStyle: .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("AI-written summary")
            }
            captionRow
        }
        .opacity(isResummarizing ? 0.45 : 1)
        .overlay(alignment: .top) {
            if isResummarizing {
                WritingIndicator(title: "Rewriting with the new template…")
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            if editedSummary != nil {
                Label("Edited by you", systemImage: "person.crop.circle.badge.checkmark")
            } else {
                Label(summaryCaption ?? "Written by AI", systemImage: "sparkle")
                    .help("Grey text with a sparkle was written by AI. Text in your normal colour came from your notes.")
            }
            Text("·")
            Button("Edit", action: onEditSummary)
                .buttonStyle(.accentLink)
                .accessibilityLabel("Edit AI notes")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Action items

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Action Items")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !liveItems.isEmpty {
                    let done = liveItems.filter(\.isCompleted).count
                    Text("\(done) of \(liveItems.count) done")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(liveItems) { item in
                    EditableActionItemRow(item: item, meetingTitle: nil, onDelete: {
                        deleteActionItem(item)
                    })
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(addItemFocused ? Color.accentColor : .secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                TextField("Add an action item", text: $newActionItemTitle)
                    .textFieldStyle(.plain)
                    .focused($addItemFocused)
                    .onSubmit(addActionItem)
                    .accessibilityLabel("Add action item")
            }
            .padding(.vertical, 4)
        }
    }

    private func addActionItem() {
        let trimmed = newActionItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = ActionItem(title: trimmed)
        item.meeting = meeting
        meeting.actionItems.append(item)
        try? modelContext.save()
        newActionItemTitle = ""
    }

    private func deleteActionItem(_ item: ActionItem) {
        meeting.actionItems.removeAll { $0.id == item.id }
        modelContext.delete(item)
        try? modelContext.save()
    }

    // MARK: - My notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeetingNotesEditor(
                text: $meeting.notes,
                placeholder: "Write your notes. LidIA folds them into the AI notes when the meeting is processed.",
                isFocused: notesFocused,
                minHeight: 320,
                growsWithContent: true
            )
            .padding(.horizontal, -5)
        }
    }
}

/// Structured summary where items from your notes read as yours and
/// AI-written items are secondary with a sparkle marker.
struct StructuredSummaryDocument: View {
    let summary: StructuredSummary
    var onCreateActionItem: ((ActionItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(summary.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.heading)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.bullets) { bullet in
                        SummaryItemRow(text: bullet.text, fromUserNotes: bullet.fromUserNotes)
                            .contextMenu {
                                if let onCreateActionItem {
                                    Button("Create Action Item") {
                                        let item = ActionItem(title: bullet.text)
                                        item.sourceQuote = bullet.sourceQuote
                                        onCreateActionItem(item)
                                    }
                                }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(bullet.text, forType: .string)
                                }
                            }
                    }
                }
            }

            if !summary.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Decisions")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(summary.decisions, id: \.self) { decision in
                        SummaryItemRow(text: decision, fromUserNotes: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One summary line. Yours: primary text with a bullet. AI: secondary text with a sparkle.
struct SummaryItemRow: View {
    let text: String
    let fromUserNotes: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if fromUserNotes {
                Text("\u{2022}")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 12)
            } else {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            Text(inlineMarkdown)
                .font(.body)
                .lineSpacing(2)
                .foregroundStyle(fromUserNotes ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fromUserNotes ? text : "AI: \(text)")
    }

    private var inlineMarkdown: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
