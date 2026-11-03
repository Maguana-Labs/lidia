import AppIntents
import Foundation
import LidIAKit

/// What Siri says back. Short: one or two sentences, the card shows the rest.
public enum SiriSpeech {
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 { return "on " + date.formatted(.dateTime.weekday(.wide)) }
        return "on " + date.formatted(.dateTime.month(.wide).day())
    }

    public static func foundMeetings(_ found: [SiriMeetingRecord], now: Date = .now) -> String {
        guard let latest = found.first else { return "I didn't find any meetings like that in LidIA." }
        let count = found.count == 1 ? "one meeting" : "\(found.count) meetings"
        return "I found \(count). The latest is \u{201C}\(latest.displayTitle)\u{201D} \(day(latest.date, now: now))."
    }

    public static func summary(record: SiriMeetingRecord, content: SiriMeetingContent?, items: [SiriActionItemRecord], blockedMessage: String?) -> String {
        guard let content else {
            return blockedMessage ?? "LidIA can't share that meeting's notes with Siri."
        }
        let points = SiriRecap.plainSummary(content.summary)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("• ") }
            .map { String($0.dropFirst(2)) }
        var parts: [String] = []
        if points.isEmpty {
            parts.append(record.state == .ready ? "\u{201C}\(record.displayTitle)\u{201D} has no summary yet." : "LidIA is still writing the notes for \u{201C}\(record.displayTitle)\u{201D}.")
        } else {
            parts.append("In \u{201C}\(record.displayTitle)\u{201D}: " + points.prefix(3).joined(separator: "; ") + ".")
        }
        if let first = content.decisions.first {
            parts.append(content.decisions.count == 1 ? "Decided: \(SiriRecap.clean(first))." : "\(content.decisions.count) decisions, starting with: \(SiriRecap.clean(first)).")
        }
        let open = items.filter(\.isOpen).count
        if open > 0 { parts.append(open == 1 ? "One action item is open." : "\(open) action items are open.") }
        return parts.joined(separator: " ")
    }

    public static func actionItems(_ items: [SiriActionItemRecord], mine: Bool) -> String {
        guard let first = items.first else {
            return mine ? "You have no open action items in LidIA." : "There are no matching action items in LidIA."
        }
        let count = items.count == 1 ? "one action item" : "\(items.count) action items"
        var line = (mine ? "You have \(count)." : "There are \(count).") + " First: \(first.title)"
        if let due = first.dueDate { line += ", due " + day(due) }
        return line + "."
    }
}

/// Behavioural cues: what the user just did in the app, donated so Siri
/// learns which intent matches which request. Content-bearing donations (a
/// question asked) are skipped when `SiriContentPolicy` keeps content from Siri.
@MainActor
public enum SiriDonations {
    /// Off in tests, demo and snapshot runs.
    public static var isEnabled = true

    public static func donate(_ intent: some AppIntent, carriesContent: Bool = false) {
        guard isEnabled else { return }
        if carriesContent, !SiriContentPolicy.current().allowsMeetingContent { return }
        _ = IntentDonationManager.shared.donate(intent: intent)
    }

    /// The user opened a meeting.
    public static func openedMeeting(_ meeting: Meeting) {
        donate(OpenMeetingIntent(target: MeetingEntity(record: SiriStore.record(meeting, includeSearchText: false))))
    }

    /// The user marked an item done.
    public static func completed(_ item: ActionItem) {
        donate(CompleteActionItemIntent(item: ActionItemEntity.make(item)))
    }
}
