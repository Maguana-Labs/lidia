import Foundation

/// Correlates meetings with projects on this Mac, with plain deterministic
/// scoring (no AI). Signals: attendee email domains and companies, recurring
/// titles (the library's series key), names in the title, mentions in the
/// notes, and which meetings are already in a project.
///
/// Scores combine independent evidence as `1 - Π(1 - weight)`, so two medium
/// signals beat one, and every suggestion carries the reasons that produced it.
enum ProjectSuggester {
    /// Below this a meeting gets no suggestion.
    static let suggestThreshold = 0.6
    /// Auto-assign (when the user opted in) needs this score…
    static let autoAssignThreshold = 0.95
    /// …and at least this many strong signals (weight ≥ 0.5).
    static let autoAssignStrongSignals = 2

    // MARK: - Types

    /// One suggestion: put `meetingIDs` in `project`.
    struct Suggestion: Identifiable, Hashable, Sendable {
        var meetingID: UUID
        var project: String
        var confidence: Double
        var reasons: [String]
        var strongSignals: Int

        var id: UUID { meetingID }

        var isAutoAssignable: Bool {
            confidence >= ProjectSuggester.autoAssignThreshold && strongSignals >= ProjectSuggester.autoAssignStrongSignals
        }
    }

    /// "Create project Northwind?": unassigned meetings that belong together.
    struct Cluster: Identifiable, Hashable, Sendable {
        var name: String
        var meetingIDs: [UUID]
        var confidence: Double
        var reasons: [String]
        var id: String { ProjectCatalog.fold(name) }
    }

    /// Who "we" are: companies and domains that are the user's own, and
    /// people's names (never project names).
    struct Context: Sendable {
        var homeCompanies: Set<String> = []
        var homeDomains: Set<String> = []
        var personTokens: Set<String> = []

        static func build(_ meetings: [MeetingSignals]) -> Context {
            var context = Context()
            var userCompanyCounts: [String: Int] = [:]
            var companyMeetingCounts: [String: Int] = [:]
            var withAttendees = 0
            for meeting in meetings {
                if !meeting.attendees.isEmpty { withAttendees += 1 }
                var companiesHere: Set<String> = []
                for attendee in meeting.attendees {
                    if let company = attendee.company {
                        let folded = ProjectCatalog.fold(company)
                        companiesHere.insert(folded)
                        if attendee.isCurrentUser { userCompanyCounts[folded, default: 0] += 1 }
                    }
                    for token in ProjectCatalog.fold(attendee.name).split(separator: " ") where token.count >= 3 {
                        context.personTokens.insert(String(token))
                    }
                }
                for company in companiesHere { companyMeetingCounts[company, default: 0] += 1 }
            }
            if let top = userCompanyCounts.max(by: { $0.value < $1.value })?.key {
                context.homeCompanies.insert(top)
            }
            // Without a known "You", a company in most meetings is the user's own.
            if context.homeCompanies.isEmpty, withAttendees >= 3 {
                for (company, count) in companyMeetingCounts where Double(count) >= Double(withAttendees) * 0.6 {
                    context.homeCompanies.insert(company)
                }
            }
            for meeting in meetings {
                for attendee in meeting.attendees {
                    guard let domain = attendee.domain, let company = attendee.company else { continue }
                    if context.homeCompanies.contains(ProjectCatalog.fold(company)) { context.homeDomains.insert(domain) }
                }
            }
            return context
        }
    }

    /// The parts of a meeting that scoring compares.
    struct Features: Sendable {
        var id: UUID
        var seriesKey: String?
        /// Outside companies' email domains.
        var domains: Set<String>
        /// Folded outside company name → display name.
        var companies: [String: String]
        /// Folded significant title words → as written.
        var titleEntities: [String: String]
        var foldedTitle: String
        var foldedText: String

        init(_ meeting: MeetingSignals, context: Context) {
            id = meeting.id
            seriesKey = meeting.seriesKey
            var domains: Set<String> = []
            var companies: [String: String] = [:]
            for attendee in meeting.attendees where !attendee.isCurrentUser {
                if let company = attendee.company {
                    let folded = ProjectCatalog.fold(company)
                    guard !context.homeCompanies.contains(folded) else { continue }
                    companies[folded] = companies[folded] ?? company
                }
                if let domain = attendee.domain, !context.homeDomains.contains(domain),
                   !AttendeeParser.personalDomains.contains(domain) {
                    domains.insert(domain)
                }
            }
            self.domains = domains
            self.companies = companies
            titleEntities = ProjectSuggester.titleEntities(meeting.title, context: context)
            foldedTitle = " " + ProjectCatalog.fold(meeting.title) + " "
            foldedText = " " + ProjectCatalog.fold(meeting.summary + " " + meeting.notes) + " "
        }
    }

    /// What a project's meetings have in common.
    struct Profile: Sendable {
        var name: String
        var folded: String
        var memberCount = 0
        var domains: [String: Int] = [:]
        var companies: [String: Int] = [:]
        var series: [String: Int] = [:]
        var entities: [String: Int] = [:]

        init(name: String) {
            self.name = name
            folded = ProjectCatalog.fold(name)
        }

        mutating func add(_ features: Features) {
            memberCount += 1
            for domain in features.domains { domains[domain, default: 0] += 1 }
            for company in features.companies.keys { companies[company, default: 0] += 1 }
            if let key = features.seriesKey { series[key, default: 0] += 1 }
            for entity in features.titleEntities.keys { entities[entity, default: 0] += 1 }
        }
    }

    // MARK: - Title entities

    /// Words too common to name a project.
    static let genericWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "about", "our", "your", "you", "new", "old", "pre", "post",
        "call", "calls", "meeting", "meetings", "sync", "catch", "catchup", "check", "checkin", "standup", "stand",
        "daily", "weekly", "monthly", "quarterly", "review", "demo", "session", "sessions", "workshop", "kickoff",
        "kick", "off", "final", "handover", "onboarding", "approach", "exercise", "strategy", "planning", "plan",
        "team", "capacity", "project", "projects", "platform", "update", "updates", "intro", "introduction",
        "discussion", "chat", "interview", "follow", "followup", "retro", "retrospective", "notes", "note",
        "untitled", "recording", "office", "hours", "lunch", "coffee", "all", "hands", "townhall", "one",
        "closeout", "scope", "clarification", "routine", "close", "down", "agenda", "prep", "brief", "debrief",
        "status", "next", "steps", "via", "per", "and/or", "tbd", "misc", "general", "internal", "external",
    ]

    /// Significant words in a title: capitalised or all-caps, three letters or
    /// more, not generic, not a person's name and not the user's own company.
    static func titleEntities(_ title: String, context: Context) -> [String: String] {
        var result: [String: String] = [:]
        let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for word in words where word.count >= 3 {
            guard let first = word.first, first.isUppercase || word.allSatisfy({ $0.isUppercase || $0.isNumber }) else { continue }
            guard !word.allSatisfy(\.isNumber) else { continue }
            let folded = ProjectCatalog.fold(word)
            guard !folded.isEmpty,
                  !genericWords.contains(folded),
                  !context.homeCompanies.contains(folded),
                  !context.personTokens.contains(folded) else { continue }
            result[folded] = result[folded] ?? word
        }
        return result
    }

    // MARK: - Suggestions for meetings

    /// Builds each project's profile from its meetings.
    static func profiles(_ meetings: [MeetingSignals], context: Context, extraProjects: [String] = []) -> [Profile] {
        var byKey: [String: Profile] = [:]
        for meeting in meetings {
            guard let project = meeting.project else { continue }
            let key = ProjectCatalog.fold(project)
            var profile = byKey[key] ?? Profile(name: project)
            profile.add(Features(meeting, context: context))
            byKey[key] = profile
        }
        for name in extraProjects where byKey[ProjectCatalog.fold(name)] == nil {
            byKey[ProjectCatalog.fold(name)] = Profile(name: name)
        }
        return Array(byKey.values)
    }

    /// The best project for a meeting, or nil when nothing is confident enough.
    static func score(_ features: Features, against profile: Profile) -> Suggestion? {
        var weights: [Double] = []
        var reasons: [String] = []
        let name = profile.name

        // The project's name is in the title.
        if !profile.folded.isEmpty, features.foldedTitle.contains(" \(profile.folded) ") {
            weights.append(0.9)
            reasons.append("“\(name)” is in the title")
        }

        // Same recurring meeting as the project's meetings.
        if let key = features.seriesKey, let count = profile.series[key], count > 0 {
            weights.append(0.85)
            reasons.append("Same series as \(count) \(count == 1 ? "meeting" : "meetings") in \(name)")
        }

        // People from the same outside company.
        var bestDomain: (domain: String, weight: Double, count: Int)?
        for domain in features.domains {
            let count = profile.domains[domain] ?? 0
            let nameMatches = Company.displayName(from: domain).lowercased() == profile.folded
            guard count > 0 || nameMatches else { continue }
            let share = profile.memberCount > 0 ? Double(count) / Double(profile.memberCount) : 0
            let weight = nameMatches ? 0.85 : (share >= 0.5 ? 0.8 : (share >= 0.2 ? 0.55 : 0.35))
            if weight > (bestDomain?.weight ?? 0) { bestDomain = (domain, weight, count) }
        }
        if let bestDomain {
            weights.append(bestDomain.weight)
            reasons.append(bestDomain.count > 0
                ? "People from \(bestDomain.domain), like \(bestDomain.count) \(name) \(bestDomain.count == 1 ? "meeting" : "meetings")"
                : "People from \(bestDomain.domain)")
        } else {
            // Companies known only by name ("Omar from Pinecrest").
            for (company, display) in features.companies {
                let count = profile.companies[company] ?? 0
                if count > 0 || company == profile.folded {
                    weights.append(0.6)
                    reasons.append("\(display) attended")
                    break
                }
            }
        }

        // Shares a distinctive title word with most of the project.
        if profile.memberCount > 0 {
            let shared = features.titleEntities.filter { entity, _ in
                entity != profile.folded && Double(profile.entities[entity] ?? 0) >= Double(profile.memberCount) * 0.5
            }
            if let word = shared.values.sorted().first {
                weights.append(0.4)
                reasons.append("Title shares “\(word)”")
            }
        }

        // The notes talk about the project.
        if !profile.folded.isEmpty {
            let mentions = features.foldedText.components(separatedBy: " \(profile.folded) ").count - 1
            if mentions >= 3 {
                weights.append(0.45)
                reasons.append("The notes mention \(name) \(mentions) times")
            } else if mentions >= 1 {
                weights.append(0.2)
                reasons.append("The notes mention \(name)")
            }
        }

        guard !weights.isEmpty else { return nil }
        let confidence = 1 - weights.reduce(1) { $0 * (1 - $1) }
        return Suggestion(
            meetingID: features.id,
            project: name,
            confidence: confidence,
            reasons: reasons,
            strongSignals: weights.filter { $0 >= 0.5 }.count
        )
    }

    /// A suggestion for every meeting without a project, skipping projects the
    /// user rejected for that meeting. Ambiguous meetings (two projects within
    /// 0.1) are scored down.
    static func suggestions(
        for meetings: [MeetingSignals],
        knownProjects: [String] = [],
        rejected: [UUID: Set<String>] = [:],
        context: Context? = nil
    ) -> [UUID: Suggestion] {
        let context = context ?? Context.build(meetings)
        let profiles = profiles(meetings, context: context, extraProjects: knownProjects)
        guard !profiles.isEmpty else { return [:] }
        var result: [UUID: Suggestion] = [:]
        for meeting in meetings where meeting.project == nil {
            if let suggestion = best(for: meeting, profiles: profiles, context: context, rejected: rejected[meeting.id] ?? []) {
                result[meeting.id] = suggestion
            }
        }
        return result
    }

    /// The best project for one meeting (or calendar event).
    static func best(
        for meeting: MeetingSignals,
        profiles: [Profile],
        context: Context,
        rejected: Set<String> = []
    ) -> Suggestion? {
        let features = Features(meeting, context: context)
        let scored = profiles
            .filter { !rejected.contains($0.folded) }
            .compactMap { score(features, against: $0) }
            .sorted { $0.confidence > $1.confidence }
        guard var top = scored.first else { return nil }
        if scored.count > 1, top.confidence - scored[1].confidence < 0.1 {
            top.confidence *= 0.85
            top.strongSignals = min(top.strongSignals, 1)
        }
        return top.confidence >= suggestThreshold ? top : nil
    }

    // MARK: - New projects

    /// Groups of meetings without a project that look like one: people from
    /// the same outside company (3+ meetings), or a distinctive word in the
    /// titles (3+), or both together (2+). Groups that mostly repeat a stronger
    /// group are dropped, and so are meetings in `excluding` (those that
    /// already fit an existing project).
    static func clusters(
        _ meetings: [MeetingSignals],
        existingProjects: [String] = [],
        dismissed: Set<String> = [],
        excluding: Set<UUID> = [],
        context: Context? = nil
    ) -> [Cluster] {
        let context = context ?? Context.build(meetings)
        let existing = Set(existingProjects.map(ProjectCatalog.fold))
            .union(meetings.compactMap(\.project).map(ProjectCatalog.fold))
        // Meetings that already fit an existing project aren't material for a new one.
        let unassigned = meetings.filter { $0.project == nil && !excluding.contains($0.id) }

        struct Candidate {
            var display: [String: Int] = [:]
            var members: Set<UUID> = []
            var companyMembers: Set<UUID> = []
            var titleMembers: Set<UUID> = []
            var domains: [String: Int] = [:]
            /// Series key → (a title, the meetings in it).
            var series: [String: (title: String, members: Set<UUID>)] = [:]

            mutating func addSeries(_ key: String?, title: String, id: UUID) {
                guard let key else { return }
                series[key] = (series[key]?.title ?? title, (series[key]?.members ?? []).union([id]))
            }
        }
        var candidates: [String: Candidate] = [:]
        for meeting in unassigned {
            let features = Features(meeting, context: context)
            for (company, display) in features.companies {
                var candidate = candidates[company] ?? Candidate()
                candidate.display[display, default: 0] += 1
                candidate.members.insert(meeting.id)
                candidate.companyMembers.insert(meeting.id)
                for domain in features.domains where ProjectCatalog.fold(Company.displayName(from: domain)) == company {
                    candidate.domains[domain, default: 0] += 1
                }
                candidate.addSeries(features.seriesKey, title: meeting.title.trimmingCharacters(in: .whitespaces), id: meeting.id)
                candidates[company] = candidate
            }
            for (entity, written) in features.titleEntities {
                var candidate = candidates[entity] ?? Candidate()
                candidate.display[written, default: 0] += 1
                candidate.members.insert(meeting.id)
                candidate.titleMembers.insert(meeting.id)
                candidate.addSeries(features.seriesKey, title: meeting.title.trimmingCharacters(in: .whitespaces), id: meeting.id)
                candidates[entity] = candidate
            }
        }

        var result: [Cluster] = []
        for (key, candidate) in candidates {
            guard !existing.contains(key), !dismissed.contains(key) else { continue }
            let both = !candidate.companyMembers.isEmpty && !candidate.titleMembers.isEmpty
            let count = candidate.members.count
            guard count >= 3 || (count >= 2 && both) else { continue }
            // A title word alone needs a majority of distinct titles, not one series repeated.
            if candidate.companyMembers.isEmpty, candidate.series.count < 2, count < 4 { continue }

            var confidence = min(0.9, 0.55 + 0.07 * Double(count - 2))
            if both { confidence = min(0.98, confidence + 0.1) }
            let name = candidate.display.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? key

            var reasons: [String] = []
            if !candidate.companyMembers.isEmpty {
                let n = candidate.companyMembers.count
                if let domain = candidate.domains.max(by: { $0.value < $1.value })?.key {
                    reasons.append("\(n) \(n == 1 ? "meeting" : "meetings") with people from \(domain)")
                } else {
                    reasons.append("\(n) \(n == 1 ? "meeting" : "meetings") with people from \(name)")
                }
            }
            if !candidate.titleMembers.isEmpty {
                let n = candidate.titleMembers.count
                reasons.append("“\(name)” is in \(n) \(n == 1 ? "title" : "titles")")
            }
            if let series = candidate.series.values.filter({ $0.members.count >= 2 }).max(by: { $0.members.count < $1.members.count }) {
                reasons.append("Recurring: \(series.title) (\(series.members.count))")
            }
            result.append(Cluster(
                name: name,
                meetingIDs: unassigned.filter { candidate.members.contains($0.id) }.map(\.id),
                confidence: confidence,
                reasons: reasons
            ))
        }

        // Strongest first; drop groups that are mostly inside a stronger one.
        result.sort { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.meetingIDs.count > $1.meetingIDs.count }
        var kept: [Cluster] = []
        for cluster in result {
            let ids = Set(cluster.meetingIDs)
            let overlaps = kept.contains { other in
                Double(ids.intersection(other.meetingIDs).count) >= Double(ids.count) * 0.7
            }
            if !overlaps { kept.append(cluster) }
        }
        return kept
    }
}
