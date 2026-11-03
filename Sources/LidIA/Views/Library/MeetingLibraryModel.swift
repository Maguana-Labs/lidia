import Foundation

/// Where a meeting came from, for the library's Source filter.
enum MeetingSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case recorded
    case imported
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recorded: "Recorded"
        case .imported: "Imported"
        case .note: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .recorded: "waveform"
        case .imported: "square.and.arrow.down"
        case .note: "note.text"
        }
    }

    static func of(externalSourceID: String?, hasAudioOrTranscript: Bool) -> MeetingSource {
        if let externalSourceID, !externalSourceID.isEmpty { return .imported }
        return hasAudioOrTranscript ? .recorded : .note
    }

    /// "Granola" for "granola:62f3…".
    static func importerName(_ externalSourceID: String?) -> String? {
        guard let prefix = externalSourceID?.split(separator: ":").first, !prefix.isEmpty else { return nil }
        return prefix.prefix(1).uppercased() + prefix.dropFirst()
    }
}

/// The fields the library needs from a meeting. `Meeting` conforms; tests use a struct.
protocol MeetingLibraryItem {
    var libraryID: UUID { get }
    var title: String { get }
    var date: Date { get }
    var status: MeetingStatus { get }
    var librarySource: MeetingSource { get }
    var libraryAttendees: [MeetingAttendee] { get }
    /// Text searched besides the title and attendees (notes, summary).
    var librarySearchText: String { get }
}

/// A date window for the Date filter.
enum MeetingDateRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case any, week, month, quarter, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any Time"
        case .week: "Past Week"
        case .month: "Past Month"
        case .quarter: "Past 3 Months"
        case .year: "Past Year"
        }
    }

    func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        let days: Int
        switch self {
        case .any: return true
        case .week: days = 7
        case .month: days = 31
        case .quarter: days = 92
        case .year: days = 366
        }
        guard let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else { return true }
        return date >= start
    }
}

/// The library's search text and filters.
struct MeetingLibraryFilter: Equatable, Sendable {
    var query = ""
    /// Attendee IDs (`MeetingAttendee.id`); a meeting matches if it has any of them.
    var people: Set<String> = []
    var companies: Set<String> = []
    var sources: Set<MeetingSource> = []
    var dateRange: MeetingDateRange = .any

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || hasFilters
    }

    var hasFilters: Bool {
        !people.isEmpty || !companies.isEmpty || !sources.isEmpty || dateRange != .any
    }

    func matches(_ item: some MeetingLibraryItem, now: Date = .now) -> Bool {
        if !sources.isEmpty, !sources.contains(item.librarySource) { return false }
        if !dateRange.contains(item.date, now: now) { return false }
        let attendees = item.libraryAttendees
        if !people.isEmpty, !attendees.contains(where: { people.contains($0.id) }) { return false }
        if !companies.isEmpty, !attendees.contains(where: { $0.company.map(companies.contains) == true }) { return false }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        // Every word must appear somewhere (title, people, notes, summary).
        let words = needle.split(separator: " ").map(String.init)
        let haystacks = [item.title]
            + attendees.flatMap { [$0.name, $0.email ?? "", $0.company ?? ""] }
        return words.allSatisfy { word in
            haystacks.contains { $0.localizedStandardContains(word) }
                || item.librarySearchText.localizedStandardContains(word)
        }
    }
}

/// Meetings with the same (normalised) title, shown as one thread.
struct MeetingSeries<Item: MeetingLibraryItem>: Identifiable {
    let key: String
    /// Newest first.
    let items: [Item]

    var id: String { key }
    var title: String { items.first?.title.trimmingCharacters(in: .whitespaces) ?? "" }
    var latestDate: Date { items.first?.date ?? .distantPast }
    var count: Int { items.count }

    /// "Weekly", "Every 2 weeks", "Monthly", or nil when irregular.
    var cadence: String? { MeetingLibraryModel.cadence(of: items.map(\.date)) }
}

/// One row of the library: a single meeting or a series.
enum MeetingLibraryEntry<Item: MeetingLibraryItem>: Identifiable {
    case meeting(Item)
    case series(MeetingSeries<Item>)

    var id: String {
        switch self {
        case .meeting(let item): "meeting:" + item.libraryID.uuidString
        case .series(let series): "series:" + series.key
        }
    }

    var date: Date {
        switch self {
        case .meeting(let item): item.date
        case .series(let series): series.latestDate
        }
    }
}

/// Pure grouping logic for the Meetings library.
enum MeetingLibraryModel {
    struct Section<Entry> {
        let label: String
        let entries: [Entry]
    }

    /// Titles too generic to group into a series.
    static let genericTitles: Set<String> = [
        "", "new note", "untitled", "meeting", "call", "recording", "note", "notes", "sync", "1:1",
    ]

    /// Normalised title used to group a series, or nil for generic titles.
    /// Case, spacing, dash style and trailing dates are ignored.
    static func seriesKey(for title: String) -> String? {
        var text = title.lowercased()
        for dash in ["–", "—", "−"] { text = text.replacingOccurrences(of: dash, with: "-") }
        // Trailing dates: "(Oct 28)", "- 2026-10-28", "28/10".
        text = text.replacing(/[\s\-–(]*\(?\d{4}-\d{2}-\d{2}\)?\s*$/, with: "")
        text = text.replacing(/[\s\-(]*\(?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\)?\s*$/, with: "")
        text = text.replacing(/[\s\-(]*\(?\d{1,2}\/\d{1,2}(\/\d{2,4})?\)?\s*$/, with: "")
        let collapsed = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-/&")))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: " - ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return genericTitles.contains(collapsed) ? nil : collapsed
    }

    /// Groups meetings with a shared series key (2 or more) into series.
    /// Entries come back newest first.
    static func entries<Item: MeetingLibraryItem>(_ items: [Item], groupSeries: Bool) -> [MeetingLibraryEntry<Item>] {
        let sorted = items.sorted { $0.date > $1.date }
        guard groupSeries else { return sorted.map { .meeting($0) } }

        var buckets: [String: [Item]] = [:]
        for item in sorted {
            if let key = seriesKey(for: item.title) { buckets[key, default: []].append(item) }
        }
        var emitted: Set<String> = []
        var result: [MeetingLibraryEntry<Item>] = []
        for item in sorted {
            if let key = seriesKey(for: item.title), let group = buckets[key], group.count > 1 {
                guard !emitted.contains(key) else { continue }
                emitted.insert(key)
                result.append(.series(MeetingSeries(key: key, items: group)))
            } else {
                result.append(.meeting(item))
            }
        }
        return result
    }

    /// All series (2+ meetings) among `items`, newest first.
    static func series<Item: MeetingLibraryItem>(_ items: [Item]) -> [MeetingSeries<Item>] {
        entries(items, groupSeries: true).compactMap {
            if case .series(let series) = $0 { return series }
            return nil
        }
    }

    /// Splits entries into Today / Yesterday / This Week / month sections.
    static func sections<Entry>(
        _ entries: [Entry],
        date: (Entry) -> Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Section<Entry>] {
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        for entry in entries {
            let label = sectionLabel(for: date(entry), now: now, calendar: calendar)
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(entry)
        }
        return order.map { Section(label: $0, entries: buckets[$0] ?? []) }
    }

    static func sectionLabel(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if date > now, !calendar.isDate(date, inSameDayAs: now) { return "Upcoming" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekStart { return "Previous 7 Days" }
        var formatStyle = Date.FormatStyle.dateTime.month(.wide)
        formatStyle.calendar = calendar
        formatStyle.timeZone = calendar.timeZone
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(formatStyle)
        }
        return date.formatted(formatStyle.year())
    }

    /// A human cadence when the gaps between meetings are regular.
    static func cadence(of dates: [Date]) -> String? {
        let sorted = dates.sorted()
        guard sorted.count >= 3 else { return nil }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.timeIntervalSince($1) / 86_400 }
        let median = gaps.sorted()[gaps.count / 2]
        let regular = gaps.filter { abs($0 - median) <= max(1.5, median * 0.25) }.count * 3 >= gaps.count * 2
        guard regular else { return nil }
        switch median {
        case 0.5..<1.5: return "Daily"
        case 5.5..<8.5: return "Weekly"
        case 12.5..<16: return "Every 2 weeks"
        case 26..<35: return "Monthly"
        default: return nil
        }
    }
}

// MARK: - Meeting conformance

extension Meeting: MeetingLibraryItem {
    var libraryID: UUID { id }

    var librarySource: MeetingSource {
        MeetingSource.of(
            externalSourceID: externalSourceID,
            hasAudioOrTranscript: audioFilePath != nil || !rawTranscript.isEmpty || duration > 0
        )
    }

    var libraryAttendees: [MeetingAttendee] {
        AttendeeParser.parse(calendarAttendees ?? [], currentUserName: MeetingAttendeeContext.currentUserName)
    }

    var librarySearchText: String {
        notes + "\n" + summary
    }
}

/// Who "You" is when parsing attendees outside a view (set from settings).
enum MeetingAttendeeContext {
    /// Written on the main actor when settings load or change; read while parsing.
    nonisolated(unsafe) static var currentUserName = ""
}
