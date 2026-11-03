import Foundation

/// The bits of a meeting the sidebar needs to sort and badge it.
/// `Meeting` conforms; tests use a lightweight stand-in.
protocol MeetingListItem {
    var status: MeetingStatus { get }
    var date: Date { get }
    var folder: String? { get }
}

extension Meeting: MeetingListItem {}

/// Pure grouping logic for the sidebar's Meetings list.
///
/// Every status is visible: meetings that failed, are queued or still
/// processing go into a "Needs attention" group at the top so Retry is always
/// reachable; everything else is grouped by day.
enum MeetingListModel {
    struct Badge: Equatable, Sendable {
        enum Tone: Sendable { case live, progress, waiting, failure }
        let label: String
        let systemImage: String
        let tone: Tone
    }

    struct Group<Item> {
        let label: String
        let items: [Item]
    }

    static func needsAttention(_ status: MeetingStatus) -> Bool {
        switch status {
        case .failed, .queued, .processing: true
        case .recording, .complete: false
        }
    }

    /// The badge shown next to a meeting, or nil for a finished meeting.
    static func badge(for status: MeetingStatus) -> Badge? {
        switch status {
        case .recording: Badge(label: "Live", systemImage: "record.circle", tone: .live)
        case .processing: Badge(label: "Processing", systemImage: "gearshape.2", tone: .progress)
        case .queued: Badge(label: "Queued", systemImage: "clock.arrow.circlepath", tone: .waiting)
        case .failed: Badge(label: "Failed", systemImage: "exclamationmark.triangle.fill", tone: .failure)
        case .complete: nil
        }
    }

    /// Meetings that need the user's attention, failures first, newest first within a status.
    static func attentionItems<Item: MeetingListItem>(_ items: [Item], folder: String? = nil) -> [Item] {
        let rank: (MeetingStatus) -> Int = { status in
            switch status {
            case .failed: 0
            case .queued: 1
            case .processing: 2
            default: 3
            }
        }
        return filter(items, folder: folder)
            .filter { needsAttention($0.status) }
            .sorted {
                let (a, b) = (rank($0.status), rank($1.status))
                return a != b ? a < b : $0.date > $1.date
            }
    }

    /// All other meetings (complete and recording), grouped by day, newest first.
    static func dateGroups<Item: MeetingListItem>(
        _ items: [Item],
        folder: String? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Group<Item>] {
        let rest = filter(items, folder: folder)
            .filter { !needsAttention($0.status) }
            .sorted { $0.date > $1.date }

        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in rest {
            let label = dayLabel(for: item.date, now: now, calendar: calendar)
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(item)
        }
        return order.map { Group(label: $0, items: buckets[$0] ?? []) }
    }

    static func dayLabel(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekAgo, date <= now {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static func filter<Item: MeetingListItem>(_ items: [Item], folder: String?) -> [Item] {
        guard let folder else { return items }
        return items.filter { $0.folder == folder }
    }
}
