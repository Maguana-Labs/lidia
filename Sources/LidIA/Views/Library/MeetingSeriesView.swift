import SwiftUI

/// A recurring meeting as one thread: who attends, a cross-meeting digest
/// entry point (Ask), open action items, and a timeline of every meeting.
struct MeetingSeriesView: View {
    let series: MeetingSeries<Meeting>
    /// Everyone across the series, the user first.
    let everyone: [MeetingAttendee]
    var onBack: () -> Void
    var onOpen: (Meeting) -> Void
    var onAsk: (String) -> Void

    private var openItems: [ActionItem] {
        series.items.flatMap { meeting in
            meeting.actionItems.filter { !$0.isDeleted && !$0.isCompleted }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                digestCard
                if !openItems.isEmpty { actionItems }
                timeline
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("Meetings", systemImage: "chevron.left")
                }
                .help("Back to Meetings")
                .keyboardShortcut("[", modifiers: .command)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Series")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(series.title)
                .font(.system(size: 26, weight: .bold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if everyone.count > 1 {
                    AttendeeStackButton(attendees: everyone)
                }
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(series.count) meetings"]
        if let cadence = series.cadence { parts.append(cadence) }
        if let first = series.items.last?.date {
            parts.append("Since \(first.formatted(.dateTime.month(.abbreviated).day().year()))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Digest

    private var digestCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Catch up on this series")
                    .font(.headline)
                Text("What changed across all \(series.count) meetings: decisions, open questions and who owes what.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                onAsk(digestQuestion)
            } label: {
                Text("Write Digest")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .help("Ask LidIA for a digest of every meeting in this series")
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    private var digestQuestion: String {
        "Across all \(series.count) “\(series.title)” meetings, summarise what changed over time, the decisions made, open questions, and open action items with owners."
    }

    // MARK: - Action items

    private var actionItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Open Action Items", count: openItems.count)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(openItems.prefix(8)) { item in
                    SeriesActionItemRow(item: item)
                }
                if openItems.count > 8 {
                    Text("\(openItems.count - 8) more in Action Items")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Timeline", count: nil)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(series.items.enumerated()), id: \.element.id) { index, meeting in
                    SeriesTimelineRow(
                        meeting: meeting,
                        isFirst: index == 0,
                        isLast: index == series.items.count - 1,
                        onOpen: { onOpen(meeting) }
                    )
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SeriesActionItemRow: View {
    @Bindable var item: ActionItem

    var body: some View {
        Toggle(isOn: $item.isCompleted) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(2)
                if let meta = meta {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var meta: String? {
        var parts: [String] = []
        if let assignee = item.assignee, !assignee.isEmpty { parts.append(assignee) }
        if let deadline = item.displayDeadline { parts.append("Due \(deadline)") }
        if let date = item.meeting?.date { parts.append(date.formatted(.dateTime.month(.abbreviated).day())) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct SeriesTimelineRow: View {
    let meeting: Meeting
    let isFirst: Bool
    let isLast: Bool
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(meeting.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.callout.weight(.semibold))
                    if !Calendar.current.isDate(meeting.date, equalTo: .now, toGranularity: .year) {
                        Text(meeting.date.formatted(.dateTime.year()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, alignment: .trailing)
                .padding(.top, 12)

                rail

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(meeting.date.formatted(.dateTime.weekday(.wide).hour().minute()))
                            .font(.callout.weight(.medium))
                        MeetingStatusBadge(status: meeting.status)
                        Spacer(minLength: 0)
                        let items = meeting.actionItems.filter { !$0.isDeleted }
                        if !items.isEmpty {
                            Label("\(items.filter(\.isCompleted).count)/\(items.count)", systemImage: "checklist")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help("Action items done")
                        }
                    }
                    let preview = SummaryPreview.lines(from: meeting.userEditedSummary ?? meeting.summary, limit: 3)
                    if preview.isEmpty {
                        Text(meeting.notes.isEmpty ? "No notes" : String(meeting.notes.prefix(200)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(preview, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Circle().fill(.tertiary).frame(width: 4, height: 4).offset(y: -2)
                                    Text(line)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(hovering ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, isLast ? 0 : 10)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the meeting")
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(isFirst ? Color.clear : Color(nsColor: .separatorColor)).frame(width: 1.5, height: 14)
            Circle()
                .fill(isFirst ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 9, height: 9)
            Rectangle().fill(isLast ? Color.clear : Color(nsColor: .separatorColor)).frame(width: 1.5)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 10)
        .accessibilityHidden(true)
    }
}

/// Plain preview lines from a markdown summary: bullets without headings,
/// escapes or emphasis markers.
enum SummaryPreview {
    static func lines(from markdown: String, limit: Int) -> [String] {
        var result: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("---") else { continue }
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            line = line.replacingOccurrences(of: "\\", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard line.count > 2 else { continue }
            result.append(line)
            if result.count == limit { break }
        }
        return result
    }
}
