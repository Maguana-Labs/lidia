import LidIAKit
import SwiftData
import SwiftUI

/// A meeting in a card: glyph, title, one detail line, time on the right.
struct MeetingRow: View {
    let meeting: Meeting
    var showsDay = false
    /// Day groups already say the day: show only the time.
    var timeOnly = false

    var body: some View {
        HStack(spacing: 14) {
            MeetingGlyph(symbol: meeting.symbol, tint: meeting.status == .failed ? .orange : meeting.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.displayTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(meeting.detailLine.isEmpty ? Format.day(meeting.date) : meeting.detailLine)
                    .font(.subheadline)
                    .foregroundStyle(meeting.status == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(showsDay ? Format.day(meeting.date) : timeOnly ? Format.time(meeting.date) : meeting.timeLabel)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.primary)
                if showsDay {
                    Text(Format.time(meeting.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// An open action item: a check you can tap, title, owner and source, due chip.
struct ActionItemRow: View {
    @Environment(AppSettings.self) private var settings
    let item: ActionItem
    var showsMeeting = true
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(item.isCompleted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Metrics.rowIcon, height: Metrics.rowIcon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .strikethrough(item.isCompleted, color: .secondary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !item.isCompleted, let due = item.dueLabel {
                Text(due)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(item.dueTint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    static func isMe(_ assignee: String, settings: AppSettings) -> Bool {
        let owner = assignee.lowercased()
        let me = settings.displayName.lowercased()
        return owner == "me" || owner == "you" || (!me.isEmpty && (owner == me || owner == settings.firstName.lowercased()))
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let assignee = item.assignee, !assignee.isEmpty {
            parts.append(Self.isMe(assignee, settings: settings) ? "You" : assignee)
        }
        if showsMeeting, let meeting = item.meeting { parts.append(meeting.displayTitle) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Completing and un-completing items, with a toast, haptics and sync.
@MainActor
enum ActionItemActions {
    static func toggle(_ item: ActionItem, context: ModelContext, toasts: ToastCenter, sync: SyncCoordinator) {
        withAnimation(.snappy) { item.isCompleted.toggle() }
        try? context.save()
        sync.push(item)
        if item.isCompleted {
            toasts.show("Marked done", actionTitle: "Undo") {
                withAnimation(.snappy) { item.isCompleted = false }
                try? context.save()
                sync.push(item)
            }
        } else {
            Haptics.tap()
        }
    }
}
