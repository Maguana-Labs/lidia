import Foundation
import SwiftData

@MainActor
@Observable
final class RelationshipStore {
    struct PersonProfile: Identifiable {
        let id: String  // email (lowercased) when available, otherwise name lowercased
        let name: String
        let email: String?
        let meetingCount: Int
        let lastMet: Date
        let openActionItems: [ActionItem]
        let recentMeetings: [Meeting]
        let talkingPoints: [TalkingPoint]
    }

    static func parseAttendee(_ raw: String) -> (displayName: String?, email: String?) {
        let pattern = /^(.+?)\s*<([^>]+)>$/
        if let match = raw.wholeMatch(of: pattern) {
            return (String(match.1).trimmingCharacters(in: .whitespaces), String(match.2).lowercased())
        }
        if raw.contains("@") {
            return (nil, raw.lowercased().trimmingCharacters(in: .whitespaces))
        }
        return (raw.trimmingCharacters(in: .whitespaces), nil)
    }

    static func displayNameFromEmail(_ email: String) -> String {
        let prefix = email.split(separator: "@").first.map(String.init) ?? email
        return prefix
            .split(separator: ".")
            .flatMap { $0.split(separator: "-") }
            .flatMap { $0.split(separator: "_") }
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    func buildProfiles(modelContext: ModelContext, currentUserName: String = MeetingAttendeeContext.currentUserName) -> [PersonProfile] {
        let meetingDescriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let talkingPointDescriptor = FetchDescriptor<TalkingPoint>(
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )

        guard let meetings = try? modelContext.fetch(meetingDescriptor),
              let talkingPoints = try? modelContext.fetch(talkingPointDescriptor) else {
            return []
        }

        let completedMeetings = meetings.filter { $0.status == .complete }

        struct PersonData {
            var displayName: String?
            var email: String?
            var meetings: [Meeting] = []
        }

        var people: [String: PersonData] = [:]

        for meeting in completedMeetings {
            // Parsed people (one raw entry can hold several), without the user.
            let attendees = AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: currentUserName)
            for attendee in attendees where !attendee.isCurrentUser {
                let key = attendee.email ?? attendee.name.lowercased()
                guard !key.isEmpty else { continue }

                var data = people[key] ?? PersonData()
                if let email = attendee.email { data.email = email }
                if !attendee.name.isEmpty, data.displayName == nil || attendee.name.count > (data.displayName?.count ?? 0) {
                    data.displayName = attendee.name
                }
                data.meetings.append(meeting)
                people[key] = data
            }
        }

        // "Leo" with no email in one meeting is leo@… from another.
        for key in people.keys where !key.contains("@") {
            guard let nameOnly = people[key] else { continue }
            let folded = AttendeeParser.fold(nameOnly.displayName ?? key)
            let candidates = people.filter { candidate in
                guard candidate.key.contains("@"), let name = candidate.value.displayName else { return false }
                let other = AttendeeParser.fold(name)
                let firstOf = { (text: String) in text.split(separator: " ").first.map(String.init) }
                return other == folded
                    || (!folded.contains(" ") && firstOf(other) == folded)
                    || (!other.contains(" ") && firstOf(folded) == other)
            }
            guard candidates.count == 1, let target = candidates.first else { continue }
            people[target.key]?.meetings += nameOnly.meetings
            if let fuller = nameOnly.displayName, fuller.count > (people[target.key]?.displayName?.count ?? 0) {
                people[target.key]?.displayName = fuller
            }
            people[key] = nil
        }

        let talkingPointsByPerson = Dictionary(grouping: talkingPoints.filter { !$0.isUsed }) {
            $0.personIdentifier.lowercased()
        }

        return people.map { (key, data) in
            let resolvedName: String
            if let displayName = data.displayName, !displayName.isEmpty {
                resolvedName = displayName
            } else if let email = data.email {
                resolvedName = Self.displayNameFromEmail(email)
            } else {
                resolvedName = key.capitalized
            }

            let sortedMeetings = data.meetings.sorted { $0.date > $1.date }
            let openActions = sortedMeetings.flatMap(\.actionItems).filter { item in
                guard !item.isCompleted else { return false }
                guard let assignee = item.assignee?.lowercased() else { return true }
                let nameLower = resolvedName.lowercased()
                return assignee.contains(nameLower)
                    || nameLower.contains(assignee)
                    || data.email.map { assignee.contains($0) } == true
                    || assignee.contains(key)
            }

            return PersonProfile(
                id: key,
                name: resolvedName,
                email: data.email,
                meetingCount: sortedMeetings.count,
                lastMet: sortedMeetings.first?.date ?? .distantPast,
                openActionItems: openActions,
                recentMeetings: Array(sortedMeetings.prefix(5)),
                talkingPoints: talkingPointsByPerson[key] ?? []
            )
        }
        .sorted { $0.lastMet > $1.lastMet }
    }

    /// Companies from attendee emails (personal mail domains skipped), one per
    /// company name so harborcloud.example and harborcloud.test are one company. Each
    /// meeting counts once per company.
    func companies(from meetings: [Meeting], currentUserName: String = MeetingAttendeeContext.currentUserName) -> [Company] {
        var companyMap: [String: Company] = [:]
        var domainToName: [String: String] = [:]

        for meeting in meetings where meeting.status == .complete && !meeting.isDeleted {
            let attendees = AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: currentUserName)
            var countedThisMeeting: Set<String> = []
            for attendee in attendees {
                guard let email = attendee.email, let domain = attendee.domain,
                      let name = AttendeeParser.companyName(forEmail: email) else { continue }
                domainToName[domain] = name
                var company = companyMap[name] ?? Company(domain: domain, name: name)
                if !attendee.isCurrentUser { company.attendeeEmails.insert(email) }
                if countedThisMeeting.insert(name).inserted {
                    company.meetingCount += 1
                    if company.lastMeetingDate.map({ meeting.date > $0 }) ?? true {
                        company.lastMeetingDate = meeting.date
                    }
                }
                companyMap[name] = company
            }
        }

        // Count open action items per company
        for meeting in meetings where !meeting.isDeleted {
            for item in meeting.actionItems where !item.isDeleted && !item.isCompleted {
                if let assignee = item.assignee?.lowercased(),
                   let domain = assignee.split(separator: "@").last.map(String.init),
                   let name = domainToName[domain] {
                    companyMap[name]?.openActionItems += 1
                }
            }
        }

        return companyMap.values
            .filter { !$0.attendeeEmails.isEmpty }
            .sorted { $0.meetingCount != $1.meetingCount ? $0.meetingCount > $1.meetingCount : $0.name < $1.name }
    }

    func prepContext(for attendees: [String], modelContext: ModelContext) -> String {
        let profiles = buildProfiles(modelContext: modelContext)
        var context = ""
        for attendee in attendees {
            let parsed = Self.parseAttendee(attendee)
            let lookupKey: String
            if let email = parsed.email {
                lookupKey = email
            } else if let name = parsed.displayName {
                lookupKey = name.lowercased()
            } else {
                lookupKey = attendee.lowercased()
            }

            guard let profile = profiles.first(where: { $0.id == lookupKey }) else { continue }

            context += "## \(profile.name)\n"
            context += "- Met \(profile.meetingCount) times, last: \(profile.lastMet.formatted(date: .abbreviated, time: .omitted))\n"

            // Full summaries from last 3 meetings
            for meeting in profile.recentMeetings.prefix(3) {
                context += "### \(meeting.title) (\(meeting.date.formatted(date: .abbreviated, time: .omitted)))\n"
                let summary = MeetingContextRetrievalService.effectiveSummary(for: meeting)
                if !summary.isEmpty {
                    context += summary + "\n"
                }
            }

            // All open action items with details
            if !profile.openActionItems.isEmpty {
                context += "### Open Action Items\n"
                for item in profile.openActionItems {
                    context += "- \(item.title)"
                    if let assignee = item.assignee { context += " (assigned: \(assignee))" }
                    if let deadline = item.displayDeadline { context += " [due: \(deadline)]" }
                    context += "\n"
                }
            }

            // All talking points (fetch all, not just unused from profile)
            let allTalkingPoints = (try? modelContext.fetch(
                FetchDescriptor<TalkingPoint>(
                    predicate: #Predicate { $0.personIdentifier == lookupKey },
                    sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
                )
            )) ?? []
            if !allTalkingPoints.isEmpty {
                context += "### Talking Points\n"
                for tp in allTalkingPoints {
                    context += "- \(tp.content)\(tp.isUsed ? " [used]" : "")\n"
                }
            }

            context += "\n"
        }
        return context
    }
}
