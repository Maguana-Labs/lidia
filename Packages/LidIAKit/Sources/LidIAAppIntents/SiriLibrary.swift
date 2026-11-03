import Foundation
import LidIAKit

// The lookup logic behind the intents and entity queries, over plain value
// copies of the library (`SiriMeetingRecord`, `SiriActionItemRecord`). Copies,
// not models: a SwiftData model must not outlive its context or cross actors
// (the same reason `SpotlightIndexer.Entry` exists on the Mac), and plain
// values make every rule here testable without a store.

/// A person in a meeting, parsed from a raw attendee string.
public struct SiriPerson: Sendable, Hashable {
    public var name: String
    public var email: String?
    public var isCurrentUser: Bool

    public init(name: String, email: String? = nil, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
    }

    /// Stable identity: the email when known, else the folded name.
    public var key: String { email?.lowercased() ?? "name:" + SiriText.fold(name) }

    /// The name to show; the email's local part when there's no name.
    public var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        guard let email else { return "" }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.split(whereSeparator: { ".-_".contains($0) }).map { $0.capitalized }.joined(separator: " ")
    }
}

/// Where a meeting is, in words Siri can say.
public enum SiriMeetingState: String, Sendable, Hashable, CaseIterable {
    case recording, processing, ready, failed

    public init(_ status: MeetingStatus) {
        switch status {
        case .recording: self = .recording
        case .processing, .queued: self = .processing
        case .complete: self = .ready
        case .failed: self = .failed
        }
    }
}

/// A meeting as the intents see it.
public struct SiriMeetingRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    public var people: [SiriPerson]
    public var project: String?
    public var state: SiriMeetingState
    public var openItemCount: Int
    /// Summary and notes, used only to match keywords. Never shown to Siri
    /// unless `SiriContentPolicy` allows content.
    public var searchableText: String

    public init(
        id: UUID, title: String, date: Date, duration: TimeInterval = 0, people: [SiriPerson] = [],
        project: String? = nil, state: SiriMeetingState = .ready, openItemCount: Int = 0, searchableText: String = ""
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.people = people
        self.project = project
        self.state = state
        self.openItemCount = openItemCount
        self.searchableText = searchableText
    }

    /// Everyone but the user.
    public var others: [SiriPerson] { people.filter { !$0.isCurrentUser } }

    /// "Title" or "Untitled meeting".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }
}

/// An action item as the intents see it.
public struct SiriActionItemRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var owner: String?
    public var dueDate: Date?
    /// The deadline as said in the meeting ("by Friday") when there's no date.
    public var dueText: String?
    public var status: ActionItemStatus
    public var priority: String
    public var meetingID: UUID?
    public var meetingTitle: String?
    public var meetingDate: Date?
    public var project: String?

    public init(
        id: UUID, title: String, owner: String? = nil, dueDate: Date? = nil, dueText: String? = nil,
        status: ActionItemStatus = .todo, priority: String = "none", meetingID: UUID? = nil,
        meetingTitle: String? = nil, meetingDate: Date? = nil, project: String? = nil
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.dueDate = dueDate
        self.dueText = dueText
        self.status = status
        self.priority = priority
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.project = project
    }

    public var isOpen: Bool { status != .done }
}

/// Text helpers shared by the rules.
public enum SiriText {
    /// Lowercased, diacritic-free, letters/digits/spaces only, single-spaced.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about", "my", "me", "meeting", "meetings",
        "el", "la", "los", "las", "de", "del", "y", "o", "en", "con", "sobre", "mi", "mis", "reunion", "reuniones",
    ]

    /// Search words: folded, no stopwords, at least two letters.
    public static func terms(_ query: String) -> [String] {
        fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// Words that mean the user in an owner field ("Me", "You", "Yo").
    static let selfWords: Set<String> = ["me", "you", "i", "myself", "yo", "mi", "user", "the user"]

    /// Whether an owner name is the user.
    public static func isUser(_ owner: String?, userName: String) -> Bool {
        guard let owner, !owner.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let folded = fold(owner)
        if selfWords.contains(folded) { return true }
        let user = fold(userName)
        guard !user.isEmpty else { return false }
        if folded == user { return true }
        let first = user.split(separator: " ").first.map(String.init) ?? user
        return folded.split(separator: " ").first.map(String.init) == first
    }
}

/// Default people and project rules, used by the iPhone. The Mac plugs in
/// its own richer parser (`AttendeeParser`) through `LidIASiri`.
public enum SiriDefaults {
    /// "Name <email>", a bare email, or a bare name.
    public static func parsePeople(_ raw: [String], userName: String) -> [SiriPerson] {
        var seen = Set<String>()
        var result: [SiriPerson] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var person: SiriPerson
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
                let email = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
                person = SiriPerson(name: name, email: email.isEmpty ? nil : email)
            } else if trimmed.contains("@"), !trimmed.contains(" ") {
                person = SiriPerson(name: "", email: trimmed.lowercased())
            } else {
                person = SiriPerson(name: trimmed)
            }
            person.isCurrentUser = SiriText.isUser(person.displayName, userName: userName) && !userName.isEmpty
            guard seen.insert(person.key).inserted else { continue }
            result.append(person)
        }
        return result
    }

    /// The meeting's folder, trimmed; nil when empty.
    public static func project(ofFolder folder: String?) -> String? {
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Finding meetings

/// What "find my meetings with…" asks for. Every part is optional.
public struct SiriMeetingSearch: Sendable, Equatable {
    public var person: String?
    public var project: String?
    public var keyword: String?
    public var from: Date?
    /// Inclusive: the whole day counts.
    public var to: Date?
    public var limit: Int

    public init(person: String? = nil, project: String? = nil, keyword: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 10) {
        self.person = person
        self.project = project
        self.keyword = keyword
        self.from = from
        self.to = to
        self.limit = limit
    }

    var isEmpty: Bool {
        [person, project, keyword].allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty } && from == nil && to == nil
    }
}

public enum SiriLibrary {
    /// Meetings matching `search`, newest first. Keywords match the title,
    /// people and project first, then the summary and notes, and only when
    /// those find too little, the transcript (`transcript` reads it on demand).
    public static func findMeetings(
        _ records: [SiriMeetingRecord],
        _ search: SiriMeetingSearch,
        calendar: Calendar = .current,
        transcript: (UUID) -> String = { _ in "" }
    ) -> [SiriMeetingRecord] {
        let limit = max(1, min(search.limit, 50))
        let end = search.to.map { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) ?? $0 }
        let start = search.from.map { calendar.startOfDay(for: $0) }
        let person = search.person.map(SiriText.fold).flatMap { $0.isEmpty ? nil : $0 }
        let project = search.project.map(SiriText.fold).flatMap { $0.isEmpty ? nil : $0 }

        let filtered = records.filter { record in
            if let start, record.date < start { return false }
            if let end, record.date >= end { return false }
            if let person, !matchesPerson(record, person) { return false }
            if let project {
                guard let name = record.project.map(SiriText.fold), name == project || name.contains(project) else { return false }
            }
            return true
        }
        .sorted { $0.date > $1.date }

        let terms = SiriText.terms(search.keyword ?? "")
        guard !terms.isEmpty else { return Array(filtered.prefix(limit)) }

        var scored: [(SiriMeetingRecord, Int)] = filtered.compactMap { record in
            let score = metadataScore(record, terms: terms)
            return score > 0 ? (record, score) : nil
        }
        if scored.count < limit {
            let found = Set(scored.map(\.0.id))
            for record in filtered where !found.contains(record.id) {
                let text = SiriText.fold(transcript(record.id))
                let hits = terms.filter { text.contains($0) }.count
                if hits > 0 { scored.append((record, hits)) }
                if scored.count >= limit * 2 { break }
            }
        }
        // Strong matches only (at least half the best score), newest first.
        let best = scored.map(\.1).max() ?? 0
        return scored
            .filter { $0.1 * 2 >= best }
            .map(\.0)
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    static func matchesPerson(_ record: SiriMeetingRecord, _ folded: String) -> Bool {
        let haystack = SiriText.fold(record.people.map { "\($0.name) \($0.email ?? "")" }.joined(separator: " ") + " " + record.title)
        return haystack.contains(folded)
    }

    static func metadataScore(_ record: SiriMeetingRecord, terms: [String]) -> Int {
        let title = SiriText.fold(record.title)
        let people = SiriText.fold(record.people.map { "\($0.name) \($0.email ?? "")" }.joined(separator: " ") + " " + (record.project ?? ""))
        let text = SiriText.fold(record.searchableText)
        var score = 0
        for term in terms {
            if title.contains(term) { score += 3 }
            if people.contains(term) { score += 2 }
            if text.contains(term) { score += 1 }
        }
        return score
    }

    /// Meetings whose title, people or project contain `text` (entity string queries).
    public static func meetings(matching text: String, in records: [SiriMeetingRecord], limit: Int = 20) -> [SiriMeetingRecord] {
        let folded = SiriText.fold(text)
        guard !folded.isEmpty else { return Array(records.sorted { $0.date > $1.date }.prefix(limit)) }
        let terms = folded.split(separator: " ").map(String.init)
        return records
            .filter { record in
                let haystack = SiriText.fold(record.title + " " + (record.project ?? "") + " " + record.people.map(\.displayName).joined(separator: " "))
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Action items

/// Whose action items.
public enum SiriItemOwner: Sendable, Equatable {
    case anyone
    case mine
    case person(String)
}

/// What "list my open action items…" asks for.
public struct SiriActionItemSearch: Sendable, Equatable {
    public var owner: SiriItemOwner
    public var includeDone: Bool
    public var project: String?
    public var meetingID: UUID?
    /// Due on or before this day (inclusive). Items without a date are left out.
    public var dueBy: Date?
    public var limit: Int

    public init(owner: SiriItemOwner = .anyone, includeDone: Bool = false, project: String? = nil, meetingID: UUID? = nil, dueBy: Date? = nil, limit: Int = 15) {
        self.owner = owner
        self.includeDone = includeDone
        self.project = project
        self.meetingID = meetingID
        self.dueBy = dueBy
        self.limit = limit
    }
}

extension SiriLibrary {
    /// Matching items: soonest due first, then the newest meeting first.
    public static func findActionItems(
        _ records: [SiriActionItemRecord],
        _ search: SiriActionItemSearch,
        userName: String,
        calendar: Calendar = .current
    ) -> [SiriActionItemRecord] {
        let dueEnd = search.dueBy.map { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) ?? $0 }
        let project = search.project.map(SiriText.fold).flatMap { $0.isEmpty ? nil : $0 }
        return records
            .filter { item in
                if !search.includeDone, !item.isOpen { return false }
                switch search.owner {
                case .anyone: break
                case .mine: if !SiriText.isUser(item.owner, userName: userName) { return false }
                case .person(let name):
                    let wanted = SiriText.fold(name)
                    let owner = SiriText.fold(item.owner ?? "")
                    if wanted.isEmpty || owner.isEmpty || !(owner.contains(wanted) || wanted.contains(owner)) { return false }
                }
                if let meetingID = search.meetingID, item.meetingID != meetingID { return false }
                if let project {
                    guard let name = item.project.map(SiriText.fold), name == project || name.contains(project) else { return false }
                }
                if let dueEnd {
                    guard let due = item.dueDate, due < dueEnd else { return false }
                }
                return true
            }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?) where l != r: return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (lhs.meetingDate ?? .distantPast) > (rhs.meetingDate ?? .distantPast)
                }
            }
            .prefix(max(1, min(search.limit, 50)))
            .map { $0 }
    }

    /// Items whose title, owner or meeting contain `text`; open ones first.
    public static func actionItems(matching text: String, in records: [SiriActionItemRecord], limit: Int = 20) -> [SiriActionItemRecord] {
        let terms = SiriText.fold(text).split(separator: " ").map(String.init)
        return records
            .filter { item in
                guard !terms.isEmpty else { return item.isOpen }
                let haystack = SiriText.fold(item.title + " " + (item.owner ?? "") + " " + (item.meetingTitle ?? ""))
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { ($0.isOpen ? 0 : 1, -($0.meetingDate ?? .distantPast).timeIntervalSince1970) < ($1.isOpen ? 0 : 1, -($1.meetingDate ?? .distantPast).timeIntervalSince1970) }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - People and projects

/// Someone the user has met, across the library.
public struct SiriPersonSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var email: String?
    public var meetingCount: Int
    public var lastMet: Date?
}

/// A project (a meeting folder that names one), across the library.
public struct SiriProjectSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var meetingCount: Int
    public var lastMeeting: Date?
}

extension SiriLibrary {
    /// Everyone but the user, most recently met first. A name seen without an
    /// email joins the person with that email and the same name.
    public static func people(from records: [SiriMeetingRecord]) -> [SiriPersonSummary] {
        var byKey: [String: SiriPersonSummary] = [:]
        var keyForName: [String: String] = [:]
        for record in records.sorted(by: { $0.date > $1.date }) {
            for person in record.others {
                let foldedName = SiriText.fold(person.displayName)
                var key = person.key
                if person.email == nil, let existing = keyForName[foldedName] { key = existing }
                var summary = byKey[key] ?? SiriPersonSummary(id: key, name: person.displayName, email: person.email, meetingCount: 0, lastMet: nil)
                if summary.name.count < person.displayName.count, person.email != nil || summary.email == nil { summary.name = person.displayName }
                summary.meetingCount += 1
                if summary.lastMet.map({ record.date > $0 }) ?? true { summary.lastMet = record.date }
                byKey[key] = summary
                if !foldedName.isEmpty, person.email != nil || keyForName[foldedName] == nil { keyForName[foldedName] = key }
            }
        }
        // Name-only entries that later got an email: fold them in.
        for (key, summary) in byKey where key.hasPrefix("name:") {
            if let target = keyForName[SiriText.fold(summary.name)], target != key, var merged = byKey[target] {
                merged.meetingCount += summary.meetingCount
                if let last = summary.lastMet, merged.lastMet.map({ last > $0 }) ?? true { merged.lastMet = last }
                byKey[target] = merged
                byKey[key] = nil
            }
        }
        return byKey.values.sorted { ($0.lastMet ?? .distantPast, $1.name) > ($1.lastMet ?? .distantPast, $0.name) }
    }

    /// Every project, newest activity first.
    public static func projects(from records: [SiriMeetingRecord]) -> [SiriProjectSummary] {
        var byKey: [String: SiriProjectSummary] = [:]
        for record in records {
            guard let name = record.project else { continue }
            let key = SiriText.fold(name)
            guard !key.isEmpty else { continue }
            var summary = byKey[key] ?? SiriProjectSummary(id: key, name: name, meetingCount: 0, lastMeeting: nil)
            summary.meetingCount += 1
            if summary.lastMeeting.map({ record.date > $0 }) ?? true { summary.lastMeeting = record.date }
            byKey[key] = summary
        }
        return byKey.values.sorted { ($0.lastMeeting ?? .distantPast, $1.name) > ($1.lastMeeting ?? .distantPast, $0.name) }
    }
}
