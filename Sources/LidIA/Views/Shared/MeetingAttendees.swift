import Foundation

/// One person in a meeting, parsed from the raw `Meeting.calendarAttendees`
/// strings (calendar emails, "Name <email>", Granola's "Name from Company (email)").
struct MeetingAttendee: Identifiable, Hashable, Sendable {
    var name: String
    var email: String?
    /// Company name, from "… from Company" or the email domain.
    var company: String?
    var isCurrentUser = false

    /// Stable identity: the email when known, else the folded name.
    var id: String { email ?? "name:" + AttendeeParser.fold(name) }

    /// "You" for the current user, otherwise the name.
    var displayName: String { isCurrentUser ? "You" : name }

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var domain: String? {
        email?.split(separator: "@").last.map { String($0).lowercased() }
    }
}

/// Pure parsing of attendee strings. Tolerates the malformed entries older
/// Granola imports stored ("Alex Moreno <daniel.r@northwind.example>", where the
/// name and email belong to different people).
enum AttendeeParser {
    static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "hotmail.com", "outlook.com", "icloud.com",
        "me.com", "mac.com", "live.com", "aol.com", "protonmail.com", "proton.me", "gmx.com",
    ]

    /// Parses every raw entry, merges duplicates, marks the current user and
    /// puts them first.
    static func parse(
        _ raw: [String],
        currentUserName: String = "",
        currentUserEmails: Set<String> = []
    ) -> [MeetingAttendee] {
        var result: [MeetingAttendee] = []
        for entry in raw {
            for attendee in parseEntry(entry) {
                merge(attendee, into: &result)
            }
        }
        let userEmails = Set(currentUserEmails.map { $0.lowercased() })
        for index in result.indices {
            result[index].isCurrentUser = isCurrentUser(result[index], name: currentUserName, emails: userEmails)
        }
        // One "You": other entries that also match the user (a bare email
        // and a full name, say) are the same person.
        if let first = result.firstIndex(where: \.isCurrentUser) {
            var you = result[first]
            for other in result.enumerated() where other.offset != first && other.element.isCurrentUser {
                if you.email == nil { you.email = other.element.email }
                if you.company == nil { you.company = other.element.company }
                if other.element.name.count > you.name.count { you.name = other.element.name }
            }
            result = [you] + result.filter { !$0.isCurrentUser }
        }
        return result
    }

    /// Parses one raw entry into one or more attendees.
    static func parseEntry(_ entry: String) -> [MeetingAttendee] {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // A trailing "<email>" or "(email)".
        var email: String?
        if let match = text.firstMatch(of: /[<(]\s*([^<>()\s]+@[^<>()\s]+)\s*[>)]\s*$/) {
            email = String(match.1).lowercased()
            text = String(text[..<match.range.lowerBound])
        } else if !text.contains(" "), text.contains("@") {
            return [fromEmail(text.lowercased())]
        }

        let names = splitNames(text)
        guard let email else {
            return names.map { MeetingAttendee(name: $0.name, email: nil, company: $0.company) }
        }
        if names.isEmpty { return [fromEmail(email)] }

        // Attach the email to the name it plausibly belongs to.
        var attendees = names.map { MeetingAttendee(name: $0.name, email: nil, company: $0.company) }
        if let owner = attendees.firstIndex(where: { nameMatchesEmail($0.name, email) }) {
            attendees[owner].email = email
            if attendees[owner].company == nil { attendees[owner].company = companyName(forEmail: email) }
        } else {
            attendees.append(fromEmail(email))
        }
        return attendees
    }

    /// "Daniel R" for "daniel.r@northwind.example".
    static func fromEmail(_ email: String) -> MeetingAttendee {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let words = local.split(whereSeparator: { ".-_+".contains($0) })
            .filter { !$0.allSatisfy(\.isNumber) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let name = words.isEmpty ? email : words.joined(separator: " ")
        return MeetingAttendee(name: name, email: email, company: companyName(forEmail: email))
    }

    /// "Northwind" for "x@northwind.example"; nil for personal mail domains.
    static func companyName(forEmail email: String) -> String? {
        guard let domain = email.split(separator: "@").last.map({ String($0).lowercased() }),
              !personalDomains.contains(domain) else { return nil }
        return Company.displayName(from: domain)
    }

    /// Lowercased, diacritic-free, letters and digits only.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    static func nameMatchesEmail(_ name: String, _ email: String) -> Bool {
        let local = fold(email.split(separator: "@").first.map(String.init) ?? "")
            .replacingOccurrences(of: " ", with: "")
        let tokens = fold(name).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !local.isEmpty, !tokens.isEmpty else { return false }
        return tokens.contains { local.hasPrefix($0) || local.contains($0) }
    }

    // MARK: - Private

    private struct NamePart { let name: String; let company: String? }

    /// "Alex Moreno (note creator) from Harborcloud, Ivo" → two names.
    private static func splitNames(_ text: String) -> [NamePart] {
        text.split(separator: ",")
            .compactMap { piece -> NamePart? in
                var part = String(piece)
                // Drop parentheticals such as "(note creator)".
                part = part.replacing(/\([^)]*\)/, with: "")
                var company: String?
                if let range = part.range(of: " from ", options: .caseInsensitive) {
                    company = cleanName(String(part[range.upperBound...]))
                    part = String(part[..<range.lowerBound])
                }
                let name = cleanName(part)
                guard !name.isEmpty else { return nil }
                return NamePart(name: name, company: company?.isEmpty == true ? nil : company)
            }
    }

    /// Trims and removes emoji (flags, symbols) from a display name.
    private static func cleanName(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || (0x1F1E6...0x1F1FF).contains(scalar.value)
              || (scalar.properties.isEmoji && scalar.value > 0x2000))
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\u{200D}", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func merge(_ attendee: MeetingAttendee, into list: inout [MeetingAttendee]) {
        if let email = attendee.email, let index = list.firstIndex(where: { $0.email == email }) {
            // Prefer a real name over one derived from the email.
            if list[index].name == fromEmail(email).name, attendee.name != fromEmail(email).name {
                list[index].name = attendee.name
            }
            if list[index].company == nil { list[index].company = attendee.company }
            return
        }
        let folded = fold(attendee.name)
        if let index = list.firstIndex(where: { fold($0.name) == folded || sameFirstName($0, attendee) }) {
            if list[index].email == nil { list[index].email = attendee.email }
            if list[index].company == nil { list[index].company = attendee.company }
            // Keep the fuller name ("Leo Novak" over "Leo").
            if attendee.name.count > list[index].name.count, attendee.email == nil || list[index].email == attendee.email {
                list[index].name = attendee.name
            }
            return
        }
        list.append(attendee)
    }

    /// "Leo" (no email) and "Leo" from leo@… are one person; two people
    /// who only share a first name and both have emails are not.
    private static func sameFirstName(_ a: MeetingAttendee, _ b: MeetingAttendee) -> Bool {
        guard a.email == nil || b.email == nil else { return false }
        let aTokens = fold(a.name).split(separator: " ")
        let bTokens = fold(b.name).split(separator: " ")
        guard aTokens.count == 1 || bTokens.count == 1, let af = aTokens.first, let bf = bTokens.first else { return false }
        return af == bf
    }

    private static func isCurrentUser(_ attendee: MeetingAttendee, name: String, emails: Set<String>) -> Bool {
        if let email = attendee.email, emails.contains(email) { return true }
        let user = fold(name)
        guard !user.isEmpty else { return false }
        let userTokens = user.split(separator: " ")
        let attendeeTokens = fold(attendee.name).split(separator: " ")
        if userTokens.count > 1 { return attendeeTokens == userTokens || fold(attendee.name).hasPrefix(user) }
        // A single-word display name ("Alex") matches the first name.
        if attendeeTokens.first.map(String.init) == user { return true }
        if let email = attendee.email {
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            return fold(local) == user
        }
        return false
    }
}

/// Attendees grouped by company for the attendee popover.
enum AttendeeGrouping {
    struct Group: Identifiable, Equatable, Sendable {
        var company: String?
        var attendees: [MeetingAttendee]
        var id: String { company ?? "" }
        var title: String { company ?? "Others" }
    }

    /// Largest company first; the current user's company after the outside
    /// ones; people without a company last.
    static func byCompany(_ attendees: [MeetingAttendee]) -> [Group] {
        var order: [String?] = []
        var buckets: [String?: [MeetingAttendee]] = [:]
        for attendee in attendees {
            let key = attendee.company
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(attendee)
        }
        let userCompany = attendees.first(where: \.isCurrentUser)?.company
        return order
            .map { Group(company: $0, attendees: buckets[$0] ?? []) }
            .sorted { lhs, rhs in
                func rank(_ group: Group) -> Int {
                    if group.company == nil { return 2 }
                    if group.company == userCompany { return 1 }
                    return 0
                }
                let (l, r) = (rank(lhs), rank(rhs))
                if l != r { return l < r }
                return lhs.attendees.count > rhs.attendees.count
            }
    }

    /// The companies other than the user's own, for compact labels ("Northwind").
    static func externalCompanies(_ attendees: [MeetingAttendee]) -> [String] {
        let userCompany = attendees.first(where: \.isCurrentUser)?.company
        var seen: [String] = []
        for company in attendees.compactMap(\.company) where company != userCompany && !seen.contains(company) {
            seen.append(company)
        }
        return seen
    }
}
