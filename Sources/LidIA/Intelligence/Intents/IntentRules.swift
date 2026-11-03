import Foundation

/// What kind of next step an item is, from its wording (and the passage it
/// came from). Deterministic: a local model only refines drafts.
enum IntentClassifier {
    private static func has(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func kind(title: String, evidence: String? = nil) -> ActionIntent.Kind {
        let t = " " + IntentText.words(title).joined(separator: " ") + " "
        if has(t, [#" re ?schedul"#, #" schedul"#, #" move (the |our |my |a )?(\w+ )?(meeting|call|sync|demo|session)"#,
                   #" postpone"#, #" book (a |the )?(meeting|call|slot|room)"#, #" set up (a |the )?(meeting|call|sync)"#,
                   #" (send|update) (an |the )?invite"#, #" calendar"#, #" find (a )?time"#]) {
            return .schedule
        }
        if has(t, [#" ticket"#, #" bug"#, #" issue"#, #" fix"#, #" implement"#, #" deploy"#, #" refactor"#, #" merge"#,
                   #" pr "#, #" prs "#, #" pull request"#, #" track"#, #" resolve"#, #" unblock"#, #" allowlist"#, #" whitelist"#, #" backlog"#, #" migrat"#, #" configure"#, #" set up (the )?(pipeline|infra|environment|account|repo)"#]) {
            return .ticket
        }
        if has(t, [#" (create|write|draft|prepare|share|send|publish) (a |the |an )?([\w-]+ ){0,3}(doc|docs|documentation|page|wiki|diagram|deck|slides|proposal|spec|history|repo|repository|recording|notes|guide|runbook|link)"#,
                   #" document"#, #" write up"#, #" writeup"#]) {
            return .document
        }
        if has(t, [#" explain"#, #" tell "#, #" let (him|her|them|\w+) know"#, #" email"#, #" message"#, #" ping"#, #" reply"#,
                   #" respond"#, #" follow ?up with"#, #" reach out"#, #" recap"#, #" inform"#, #" notify"#, #" update (the )?\w+ on"#,
                   #" send"#, #" share"#, #" ask "#, #" introduce"#, #" intro "#, #" confirm with"#, #" check (in )?with"#]) {
            return .message
        }
        if has(t, [#" research"#, #" investigat"#, #" look into"#, #" find out"#, #" explore"#, #" compare"#, #" evaluate"#, #" read up"#]) {
            return .research
        }
        if has(t, [#" remind"#, #" remember"#, #" review"#, #" check "#, #" think about"#, #" day off"#, #" take \w+ off"#, #" prepare"#, #" book "#, #" buy"#, #" pay"#]) {
            return .reminder
        }
        return .unclear
    }
}

/// Who owes what to whom. Fixes the classic extraction mistake: someone asks
/// the user ("Alex, can you explain stacked PRs?") and the item comes out as
/// "Explain stacked PRs to Alex".
enum OwnerResolver {
    struct Input: Sendable {
        var title: String
        var assignee: String?
        var userName: String
        /// Everyone on the invite (the user included), as parsed attendees.
        var attendees: [MeetingAttendee]
        var evidence: TranscriptTurn?
    }

    struct Resolution: Sendable, Equatable {
        var direction: ActionIntent.Direction
        var owner: String?
        var ownerIsUser: Bool
        var recipients: [ActionIntent.Person]
        var recipientLabel: String?
        var suggestedTitle: String?
        /// Why, for the confidence reasons.
        var cue: String?
    }

    static let requestPattern = #"\b(can|could|would|will) you\b|\bplease\b|\bi need you\b|\bcan i ask you\b|\bmind (explaining|sharing|sending)\b|\byou (should|need to|have to)\b|\b(great|good|nice|helpful) if you\b|\bif you could\b|\bpuedes\b|\bpodrias\b|\bpor favor\b"#
    static let commitmentPattern = #"\b(i'll|i will|i'm going to|im going to|let me|i can|i'll try|i will try|i shall|i'd like to)\b"#

    /// Words that mean "the person recording" in an assignee field.
    static let selfWords: Set<String> = ["me", "i", "you", "user", "the user", "myself", "yo"]

    /// A transcript label, not a person ("Them", "Speaker 2").
    static func isSpeakerLabel(_ name: String) -> Bool {
        let folded = IntentText.fold(name.trimmingCharacters(in: .whitespaces))
        return folded == "them" || folded == "they" || folded.range(of: #"^speaker \d+$"#, options: .regularExpression) != nil
    }

    static func isUser(_ name: String?, userName: String) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
        let folded = IntentText.fold(name)
        if selfWords.contains(folded) { return true }
        let first = IntentText.firstName(userName)
        guard !first.isEmpty else { return false }
        return folded == IntentText.fold(userName) || folded.split(separator: " ").first.map(String.init) == first
    }

    static func resolve(_ input: Input) -> Resolution {
        let others = input.attendees.filter { !$0.isCurrentUser && !isUser($0.name, userName: input.userName) }
        let external = externalPeople(others, attendees: input.attendees)
        let audience = external.isEmpty ? others : external
        let quote = input.evidence.map { IntentText.fold($0.text) } ?? ""
        let speakerIsUser = input.evidence?.isUser
        let asks = quote.range(of: requestPattern, options: .regularExpression) != nil
        let commits = quote.range(of: commitmentPattern, options: .regularExpression) != nil
        let titleNamesUserAsTarget = targetsUser(input.title, userName: input.userName)

        // Someone else asked the user: the user owes it, to them.
        if speakerIsUser == false, asks {
            let asker = person(named: input.evidence?.speaker, in: others)
            let recipients = asker.map { [$0] } ?? audience.map(person)
            let label = asker?.firstName ?? groupLabel(audience)
            return Resolution(
                direction: .userOwes, owner: input.userName.nilIfBlank ?? "You", ownerIsUser: true,
                recipients: recipients, recipientLabel: label,
                suggestedTitle: titleNamesUserAsTarget || isUser(input.assignee, userName: input.userName) == false
                    ? retarget(input.title, userName: input.userName, to: label) : nil,
                cue: "Asked of you\(input.evidence?.speaker.map { " by \($0)" } ?? "")"
            )
        }
        // The user said they'd do it.
        if speakerIsUser == true, commits || asks == false {
            let label = groupLabel(audience)
            return Resolution(
                direction: .userOwes, owner: input.userName.nilIfBlank ?? "You", ownerIsUser: true,
                recipients: audience.map(person), recipientLabel: label,
                suggestedTitle: titleNamesUserAsTarget ? retarget(input.title, userName: input.userName, to: label) : nil,
                cue: commits ? "You said you'd do it" : "You brought it up"
            )
        }
        // Someone else committed: they owe the user.
        if speakerIsUser == false, commits {
            let speaker = person(named: input.evidence?.speaker, in: others)
            return Resolution(
                direction: .othersOweUser, owner: speaker?.name ?? input.assignee ?? input.evidence?.speaker, ownerIsUser: false,
                recipients: speaker.map { [$0] } ?? audience.map(person), recipientLabel: speaker?.firstName ?? groupLabel(audience),
                suggestedTitle: nil, cue: "\(speaker?.firstName ?? "They") said they'd do it"
            )
        }
        // Only the assignee to go on.
        if let assignee = input.assignee?.trimmingCharacters(in: .whitespaces), !assignee.isEmpty,
           !["team", "everyone", "all"].contains(IntentText.fold(assignee)) {
            if isUser(assignee, userName: input.userName) {
                let label = groupLabel(audience)
                return Resolution(
                    direction: .userOwes, owner: input.userName.nilIfBlank ?? assignee, ownerIsUser: true,
                    recipients: audience.map(person), recipientLabel: label,
                    suggestedTitle: titleNamesUserAsTarget ? retarget(input.title, userName: input.userName, to: label) : nil,
                    cue: "Assigned to you"
                )
            }
            let owner = person(named: assignee, in: others)
            return Resolution(
                direction: .othersOweUser, owner: owner?.name ?? assignee, ownerIsUser: false,
                recipients: owner.map { [$0] } ?? [ActionIntent.Person(name: assignee)], recipientLabel: owner?.firstName ?? assignee,
                suggestedTitle: nil, cue: "Assigned to \(assignee)"
            )
        }
        // Nothing says otherwise: it's in the user's own recording, so the user.
        let label = groupLabel(audience)
        return Resolution(
            direction: .userOwes, owner: input.userName.nilIfBlank ?? "You", ownerIsUser: true,
            recipients: audience.map(person), recipientLabel: label,
            suggestedTitle: titleNamesUserAsTarget ? retarget(input.title, userName: input.userName, to: label) : nil,
            cue: nil
        )
    }

    /// "Explain X to Alex" when Alex is the user.
    static func targetsUser(_ title: String, userName: String) -> Bool {
        let first = IntentText.firstName(userName)
        guard !first.isEmpty else { return false }
        let folded = " " + IntentText.words(title).joined(separator: " ") + " "
        return folded.range(of: " (to|for|with) \(first)( |s )", options: .regularExpression) != nil
            || folded.contains(" \(first)s ") // "Alex's visibility"
    }

    /// "Explain the stacking process to Alex" → "… to the Northwind team".
    static func retarget(_ title: String, userName: String, to label: String?) -> String? {
        let first = userName.split(separator: " ").first.map(String.init) ?? userName
        guard !first.isEmpty else { return nil }
        let target = label ?? "the others"
        var result = title
        for pattern in ["\\b(to|for|with) \(NSRegularExpression.escapedPattern(for: first))('s)?\\b(\\s+\\S+)?"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            guard let match = regex.firstMatch(in: result, range: range), let whole = Range(match.range, in: result) else { continue }
            let preposition = Range(match.range(at: 1), in: result).map { String(result[$0]) } ?? "to"
            let possessive = match.range(at: 2).location != NSNotFound
            let following = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? ""
            result.replaceSubrange(whole, with: possessive
                ? "\(preposition) \(target)'s\(following)"
                : "\(preposition) \(target)\(following)")
        }
        return result == title ? nil : result
    }

    /// People from outside the user's company (by email domain).
    static func externalPeople(_ others: [MeetingAttendee], attendees: [MeetingAttendee]) -> [MeetingAttendee] {
        let homeDomains = Set(attendees.filter { $0.isCurrentUser || others.contains($0) == false }.compactMap(\.domain))
        guard !homeDomains.isEmpty else { return [] }
        return others.filter { $0.domain.map { !homeDomains.contains($0) } ?? false }
    }

    /// "Mateo", "Mateo and Daniel", "the Northwind team".
    static func groupLabel(_ people: [MeetingAttendee]) -> String? {
        guard !people.isEmpty else { return nil }
        if people.count == 1 { return people[0].name.split(separator: " ").first.map(String.init) ?? people[0].name }
        let domains = Set(people.compactMap(\.domain))
        if domains.count == 1, let domain = domains.first, !["gmail.com", "outlook.com", "hotmail.com", "icloud.com"].contains(domain) {
            return "the \(IntentText.company(fromDomain: domain)) team"
        }
        if people.count == 2 { return people.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }.joined(separator: " and ") }
        return "everyone"
    }

    static func person(_ attendee: MeetingAttendee) -> ActionIntent.Person {
        ActionIntent.Person(name: attendee.name, email: attendee.email)
    }

    /// The attendee a speaker label or name refers to ("Mateo" → Mateo K.).
    static func person(named name: String?, in attendees: [MeetingAttendee]) -> ActionIntent.Person? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name != SpeakerTranscriptFormatter.remoteLabel, !name.hasPrefix("Speaker ") else { return nil }
        let first = IntentText.firstName(name)
        if let match = attendees.first(where: { IntentText.firstName($0.name) == first }) { return person(match) }
        return ActionIntent.Person(name: name)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Grounded confidence: from the evidence and the direction cue, plus a
/// verifier's agreement. Never a model's opinion of itself.
enum IntentConfidence {
    static func score(evidence: Double?, hasDirectionCue: Bool, verifierAgrees: Bool?, kind: ActionIntent.Kind) -> (Double, [String]) {
        var reasons: [String] = []
        var value = 0.0
        if let evidence {
            value += 0.6 * min(1, evidence)
            reasons.append(evidence >= EvidenceMatcher.supportedFrom ? "The transcript says it" : evidence >= EvidenceMatcher.notFoundBelow ? "The transcript partly says it" : "Barely in the transcript")
        } else {
            reasons.append("Not found in the transcript")
        }
        if hasDirectionCue { value += 0.2 }
        switch verifierAgrees {
        case true?: value += 0.2; reasons.append("Checked against the transcript")
        case false?: value -= 0.2; reasons.append("A check against the transcript disagreed")
        case nil: break
        }
        if kind == .unclear { value -= 0.15 }
        return (max(0, min(1, value)), reasons)
    }
}
