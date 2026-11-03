import Foundation

/// Patterns in the user's own meetings and action items, found on this Mac:
/// action items left open for weeks, and a recurring meeting coming up that
/// is worth reviewing first. (Follow-ups the user usually sends are a reason
/// on the follow-up card; see `FollowUpPlanner.followUpHabit`.)
enum PatternDetector {
    /// Open this long and an item counts as stale.
    static let staleAfterDays = 14

    enum Kind: Hashable, Sendable {
        /// Open items of one project (or meeting group) left alone.
        case staleItems(group: String, itemIDs: [UUID], project: String?)
        /// A series meets again soon: review its recent meetings.
        case seriesReview(seriesKey: String, title: String, eventID: String, meetingIDs: [UUID])
    }

    struct Pattern: Identifiable, Hashable, Sendable {
        var id: String
        var kind: Kind
        var title: String
        var detail: String
        var reasons: [String]
    }

    /// An open action item with what it belongs to.
    struct OpenItem: Hashable, Sendable {
        var id: UUID
        var title: String
        var meetingTitle: String
        var meetingDate: Date
        var project: String?
    }

    // MARK: - Stale action items

    /// Groups of 2+ items open for `staleAfterDays` or more, by project, else
    /// by meeting series. Oldest group first.
    static func staleItems(_ items: [OpenItem], now: Date = .now, calendar: Calendar = .current) -> [Pattern] {
        guard let cutoff = calendar.date(byAdding: .day, value: -staleAfterDays, to: now) else { return [] }
        let stale = items.filter { $0.meetingDate <= cutoff }
        var groups: [String: [OpenItem]] = [:]
        var labels: [String: String] = [:]
        for item in stale {
            let label = item.project ?? item.meetingTitle.trimmingCharacters(in: .whitespaces)
            let key = item.project.map { "project:" + ProjectCatalog.fold($0) }
                ?? "series:" + (MeetingLibraryModel.seriesKey(for: item.meetingTitle) ?? ProjectCatalog.fold(item.meetingTitle))
            groups[key, default: []].append(item)
            labels[key] = label
        }
        return groups
            .filter { $0.value.count >= 2 }
            .map { key, group -> Pattern in
                let oldest = group.map(\.meetingDate).min() ?? now
                let days = calendar.dateComponents([.day], from: oldest, to: now).day ?? staleAfterDays
                let label = labels[key] ?? ""
                let weeks = days / 7
                let age = weeks >= 2 ? "\(weeks) weeks" : "\(days) days"
                return Pattern(
                    id: "stale:\(key):\(group.count)",
                    kind: .staleItems(group: label, itemIDs: group.map(\.id), project: group.first?.project),
                    title: "\(group.count) \(label) items open for \(age)",
                    detail: group.sorted { $0.meetingDate < $1.meetingDate }.prefix(3).map(\.title).joined(separator: " · "),
                    reasons: ["Oldest from \(oldest.formatted(.dateTime.month(.abbreviated).day())), nothing has moved since"]
                )
            }
            .sorted { $0.title < $1.title }
    }

    // MARK: - Series review

    /// A series with 2+ past meetings whose next occurrence is later today
    /// (an hour or more away) or tomorrow.
    static func seriesReviews(
        events: [AgendaEvent],
        meetings: [MeetingSignals],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Pattern] {
        var bySeries: [String: [MeetingSignals]] = [:]
        for meeting in meetings where meeting.isComplete && meeting.date < now {
            if let key = meeting.seriesKey { bySeries[key, default: []].append(meeting) }
        }
        var seen: Set<String> = []
        var result: [Pattern] = []
        for event in events.sorted(by: { $0.start < $1.start }) where !event.isAllDay {
            let isLaterToday = calendar.isDate(event.start, inSameDayAs: now) && event.start.timeIntervalSince(now) >= 3600
            let isTomorrow = calendar.isDateInTomorrow(event.start, relativeTo: now)
            guard isLaterToday || isTomorrow,
                  let key = MeetingLibraryModel.seriesKey(for: event.title),
                  !seen.contains(key),
                  let past = bySeries[key], past.count >= 2 else { continue }
            seen.insert(key)
            let recent = past.sorted { $0.date > $1.date }.prefix(3)
            let when = (isTomorrow ? "Tomorrow" : "Today") + " at " + event.start.formatted(date: .omitted, time: .shortened)
            let openItems = recent.flatMap(\.actionItems).filter { !$0.isCompleted }.count
            var reasons = ["\(past.count) past meetings in this series, last one \(MeetingRowFormat.relativeDay(recent.first?.date ?? now, now: now, calendar: calendar, timeForToday: false))"]
            if openItems > 0 { reasons.append("\(openItems) open action \(openItems == 1 ? "item" : "items") from them") }
            result.append(Pattern(
                id: "review:\(key):\(Int(event.start.timeIntervalSince1970))",
                kind: .seriesReview(seriesKey: key, title: event.title, eventID: event.id, meetingIDs: recent.map(\.id)),
                title: "Review the last \(recent.count) before \(event.title.trimmingCharacters(in: .whitespaces))",
                detail: when,
                reasons: reasons
            ))
        }
        return result
    }
}

private extension Calendar {
    func isDateInTomorrow(_ date: Date, relativeTo now: Date) -> Bool {
        guard let tomorrow = self.date(byAdding: .day, value: 1, to: now) else { return false }
        return isDate(date, inSameDayAs: tomorrow)
    }
}
