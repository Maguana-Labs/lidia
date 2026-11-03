import Foundation

/// Finds the past meetings an upcoming meeting continues, for prep briefs.
///
/// Matching uses every signal the library has, because each one fails somewhere:
/// - **Calendar series**: the same recurring event (Google instance IDs share a base ID).
/// - **Title series**: the same or a similar title ("Northwind x Harborcloud - SaaS
///   Platform on AWS" every week). Works even when attendees are missing or were
///   mis-imported (Granola imports before 074354b joined all participants into one string).
/// - **Attendees**: shared email addresses, parsed out of "Name <email>", bare
///   emails and comma-joined lists, ignoring the user's own address.
/// - **Company**: a shared external email domain, as a weak signal that needs a
///   partly similar title too.
enum MeetingHistoryMatcher {
    struct Upcoming: Sendable {
        var title: String
        var attendees: [String]
        var calendarEventIDs: [String] = []
        var start: Date = .now
    }

    enum Reason: String, Sendable, Hashable, Comparable {
        case calendarSeries = "same recurring event"
        case sameTitle = "same title"
        case similarTitle = "similar title"
        case sharedAttendees = "shared attendees"
        case sharedCompany = "same company"

        static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Match {
        let meeting: Meeting
        let score: Int
        let reasons: Set<Reason>
    }

    static let minimumScore = 5

    /// Past meetings that match, most recent first. Only meetings before
    /// `upcoming.start` (minus a few minutes, so a recording of this very event
    /// that has just started isn't its own history) are considered.
    @MainActor
    static func matches(for upcoming: Upcoming, in meetings: [Meeting], limit: Int = 12) -> [Match] {
        let cutoff = upcoming.start.addingTimeInterval(-15 * 60)
        let past = meetings.filter { $0.date < cutoff }
        guard !past.isEmpty else { return [] }

        let common = commonIdentities(in: meetings)
        let upcomingPeople = identities(from: upcoming.attendees)
        let upcomingEmails = upcomingPeople.emails.subtracting(common.emails)
        let upcomingDomains = Set(upcomingEmails.compactMap(domain(of:))).subtracting(common.domains)
        let upcomingKey = titleKey(upcoming.title)
        let upcomingTokens = titleTokens(upcoming.title)
        let upcomingSeries = Set(upcoming.calendarEventIDs.map(seriesID(of:)))

        var results: [Match] = []
        for meeting in past {
            var score = 0
            var reasons: Set<Reason> = []

            if let id = meeting.calendarEventID, !id.isEmpty, upcomingSeries.contains(seriesID(of: id)) {
                score += 10
                reasons.insert(.calendarSeries)
            }

            let similarity: Double
            if !upcomingKey.isEmpty, titleKey(meeting.title) == upcomingKey {
                similarity = 1
                score += 10
                reasons.insert(.sameTitle)
            } else {
                similarity = jaccard(upcomingTokens, titleTokens(meeting.title))
                if similarity >= 0.6 {
                    score += 6
                    reasons.insert(.similarTitle)
                }
            }

            let people = identities(from: meeting.calendarAttendees ?? [])
            let sharedEmails = upcomingEmails.intersection(people.emails)
            if !sharedEmails.isEmpty {
                // A colleague from the user's own company is a weaker signal than
                // an external guest: alone it doesn't make an internal meeting
                // part of a client meeting's history.
                let weight = sharedEmails.reduce(0) { total, email in
                    total + (domain(of: email).map { common.domains.contains($0) && !personalDomains.contains($0) } == true ? 2 : 5)
                }
                score += min(15, weight)
                reasons.insert(.sharedAttendees)
            } else {
                let domains = Set(people.emails.compactMap(domain(of:)))
                if !upcomingDomains.isDisjoint(with: domains), similarity >= 0.25 {
                    score += 5
                    reasons.insert(.sharedCompany)
                }
            }

            if score >= minimumScore {
                results.append(Match(meeting: meeting, score: score, reasons: reasons))
            }
        }
        return Array(results.sorted { $0.meeting.date > $1.meeting.date }.prefix(limit))
    }

    // MARK: - Attendees

    struct Identities: Equatable {
        var emails: Set<String> = []
        var names: Set<String> = []
    }

    private static var emailPattern: Regex<Substring> { /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/ }

    /// Emails and display names in attendee strings, including comma-joined
    /// lists ("A, B, C <c@x.com>") from older imports.
    static func identities(from attendees: [String]) -> Identities {
        var result = Identities()
        for raw in attendees {
            for match in raw.matches(of: emailPattern) {
                result.emails.insert(String(match.output).lowercased())
            }
            for piece in raw.split(separator: ",") {
                var name = String(piece)
                if let angle = name.firstIndex(of: "<") { name = String(name[..<angle]) }
                if name.contains("@") { continue }
                if let from = name.range(of: " from ") { name = String(name[..<from.lowerBound]) }
                let cleaned = name.unicodeScalars
                    .filter { $0.properties.isAlphabetic || $0 == " " || $0 == "-" || $0 == "'" }
                    .map(String.init).joined()
                    .split(separator: " ").joined(separator: " ")
                    .lowercased()
                if cleaned.count >= 2 { result.names.insert(cleaned) }
            }
        }
        return result
    }

    /// The user's own identity, inferred from the library (LidIA has no "me"
    /// account): names and emails present in most meetings, plus emails whose
    /// local part is the user's name ("alex@…" for "Alex Moreno"). Sharing the
    /// user's own address says nothing about who a meeting is with. `domains`
    /// are only ignored for the weak company signal: the user's own company and
    /// personal mail providers.
    @MainActor
    static func commonIdentities(in meetings: [Meeting]) -> (emails: Set<String>, domains: Set<String>) {
        let withAttendees = meetings.compactMap(\.calendarAttendees).filter { !$0.isEmpty }
        guard withAttendees.count >= 4 else { return ([], personalDomains) }
        var emailCounts: [String: Int] = [:]
        var nameCounts: [String: Int] = [:]
        var allEmails: Set<String> = []
        for attendees in withAttendees {
            let people = identities(from: attendees)
            allEmails.formUnion(people.emails)
            for email in people.emails { emailCounts[email, default: 0] += 1 }
            for name in people.names { nameCounts[name, default: 0] += 1 }
        }
        let threshold = Double(withAttendees.count) * 0.5
        var selfEmails = Set(emailCounts.filter { Double($0.value) > threshold }.keys)
        let selfNames = nameCounts.filter { Double($0.value) > threshold }.keys
        let selfNameTokens = selfNames.map { Set($0.split(separator: " ").map(String.init)) }
        for email in allEmails {
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            let parts = Set(local.split { $0 == "." || $0 == "_" || $0 == "-" }.map(String.init))
            guard !parts.isEmpty else { continue }
            if selfNameTokens.contains(where: { parts.isSubset(of: $0) }) {
                selfEmails.insert(email)
            }
        }
        let ownDomains = Set(selfEmails.compactMap(domain(of:)))
        return (selfEmails, ownDomains.union(personalDomains))
    }

    static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "hotmail.com", "outlook.com",
        "icloud.com", "me.com", "live.com", "aol.com", "protonmail.com", "proton.me",
    ]

    static func domain(of email: String) -> String? {
        email.split(separator: "@").last.map { String($0).lowercased() }
    }

    // MARK: - Titles

    private static let stopwords: Set<String> = [
        "x", "and", "the", "with", "on", "of", "for", "a", "an", "to", "in", "at", "vs",
        "de", "y", "la", "el", "con", "en", "del", "meeting", "call", "sync", "reunion", "reunión",
    ]

    /// Normalised title for "same series" checks: lower-cased, dates and
    /// numbering removed, punctuation collapsed.
    static func titleKey(_ title: String) -> String {
        var text = title.lowercased()
        let datePatterns = [
            #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,
            #"\b\d{1,2}[/.]\d{1,2}([/.]\d{2,4})?\b"#,
            #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}(st|nd|rd|th)?\b"#,
            #"\b\d{1,2} (jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#,
            #"#\d+"#,
            #"\b(week|wk|w|sprint|session|part) ?\d+\b"#,
        ]
        for pattern in datePatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let words = text.split { !$0.isLetter && !$0.isNumber }
        return words.joined(separator: " ")
    }

    static func titleTokens(_ title: String) -> Set<String> {
        Set(titleKey(title).split(separator: " ").map(String.init).filter { $0.count > 1 && !stopwords.contains($0) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Recurring Google events have instance IDs "<base>_<timestamp>".
    static func seriesID(of eventID: String) -> String {
        let id = eventID.hasPrefix("google:") || eventID.hasPrefix("apple:")
            ? String(eventID.drop(while: { $0 != ":" }).dropFirst())
            : eventID
        if let underscore = id.lastIndex(of: "_") {
            let suffix = id[id.index(after: underscore)...]
            if suffix.count >= 8, suffix.first?.isNumber == true {
                return String(id[..<underscore])
            }
        }
        return id
    }
}
