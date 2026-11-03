import Foundation

/// Everything an intent is worked out from, copied out of the library so
/// building it is pure (and testable).
struct IntentInput: Sendable {
    var itemID: UUID
    var meetingID: UUID
    var title: String
    var assignee: String?
    var meetingTitle: String
    var meetingDate: Date
    var attendees: [MeetingAttendee]
    var turns: [TranscriptTurn]
    var userName: String
    /// The meeting's notes (markdown), for draft content.
    var summary: String
    var verification: IntentStore.Verification?
    /// The meeting has LidIA's own timed transcript (not an import).
    var hasTimedTranscript = true
}

/// Builds an intent without any model: evidence, direction, kind,
/// destinations, a calendar proposal and a template draft. A model may
/// then rewrite the draft (`IntentEngine`).
enum IntentBuilder {
    static func build(
        _ input: IntentInput,
        connections: IntentConnections,
        events: [IntentCalendarEvent] = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ActionIntent {
        let userFirst = input.userName.split(separator: " ").first.map(String.init) ?? input.userName
        let exclude = [input.userName, userFirst].filter { !$0.isEmpty }
        let matches = EvidenceMatcher.matches(for: input.title, in: input.turns, exclude: exclude, limit: 3)
        let best = matches.first

        // Evidence: the pipeline's check when there was one, else the best passage.
        var evidence: [ActionIntent.Evidence] = []
        if var checked = input.verification?.evidence {
            if checked.spokenAt == nil, let offset = checked.offset { checked.spokenAt = input.meetingDate.addingTimeInterval(offset) }
            evidence.append(checked)
        }
        for match in matches where match.score >= EvidenceMatcher.notFoundBelow || evidence.isEmpty {
            let item = self.evidence(match, meetingDate: input.meetingDate)
            if !evidence.contains(where: { $0.quote == item.quote }) { evidence.append(item) }
            if evidence.count >= 2 { break }
        }

        let hasTranscript = !input.turns.isEmpty
        let verdict: ActionIntent.Verdict = input.verification?.verdict
            ?? (hasTranscript ? EvidenceMatcher.verdict(for: best?.score) : .supported)
        let evidenceTurn = verdict == .notFound ? nil : best?.turn

        let resolution = OwnerResolver.resolve(.init(
            title: input.title, assignee: input.assignee, userName: input.userName,
            attendees: input.attendees, evidence: evidenceTurn
        ))
        let workingTitle = resolution.suggestedTitle ?? input.title
        let kind = IntentClassifier.kind(title: workingTitle, evidence: best?.quote)
        let homeDomains = Set(input.attendees.filter { $0.isCurrentUser || OwnerResolver.isUser($0.name, userName: input.userName) }.compactMap(\.domain))
        let external = resolution.recipients.contains { person in
            guard let domain = person.email?.split(separator: "@").last.map({ String($0).lowercased() }) else { return false }
            return !homeDomains.isEmpty && !homeDomains.contains(domain)
        }
        var destinations = IntentDestinationRanker.rank(kind: kind, title: workingTitle, recipientsAreExternal: external, connections: connections)

        var proposal: ActionIntent.CalendarProposal?
        var resolutionOverride: ([ActionIntent.Person], String?)?
        let artifact: ActionIntent.Artifact
        switch kind {
        case .schedule:
            let made = calendarProposal(title: input.title, quote: best?.quote, events: events, now: now, calendar: calendar, userName: input.userName)
            proposal = made
            if made.source == "google" {
                destinations = [.init(id: "calendarApp", name: "Google Calendar", configured: true, reason: "Google Calendar · LidIA can only read these events")]
            } else if made.source == "none" {
                destinations = [.init(id: "calendarApp", name: "Calendar", configured: true, reason: "Calendar · LidIA couldn't find the event")]
            }
            if !made.attendees.isEmpty {
                // The people to reach are the event's, not this meeting's.
                let people = made.attendees.map { MeetingAttendee(name: $0.name, email: $0.email) }
                resolutionOverride = (made.attendees, OwnerResolver.groupLabel(people))
            }
            if made.source == "apple", !made.editable, !made.slots.isEmpty {
                // Someone else organizes it: propose the free times to them.
                var mail = IntentDestinationRanker.email(connections)
                mail.reason = "\(mail.name) · someone else organizes this event"
                destinations = [mail, .init(id: "calendarApp", name: "Calendar", configured: true, reason: "Calendar · open the event")]
            }
            artifact = .calendarChange(made)
        default:
            artifact = templateArtifact(kind: kind, input: input, title: workingTitle, resolution: resolution, destination: destinations.first)
        }

        let hasCue = resolution.cue != nil
        var (confidence, reasons) = IntentConfidence.score(
            evidence: hasTranscript ? best?.score : nil,
            hasDirectionCue: hasCue,
            verifierAgrees: input.verification.map { $0.verdict == .supported && $0.checkedBy != nil ? true : ($0.verdict == .notFound ? false : nil) } ?? nil,
            kind: kind
        )
        if !hasTranscript {
            confidence = 0.55
            reasons = ["From the meeting notes (no transcript)"]
        }
        if let cue = resolution.cue { reasons.append(cue) }
        if resolution.suggestedTitle != nil { reasons.append("Direction corrected: you owe this to \(resolution.recipientLabel ?? "them")") }

        let explains = IntentText.words(workingTitle).contains { ["explain", "walk", "show", "introduce", "share"].contains($0) }
        let reviewable = input.verification != nil || input.hasTimedTranscript
        let primary = reviewable && (verdict == .notFound || verdict == .doneInMeeting)
            ? "Review"
            : IntentDestinationRanker.primaryLabel(
                kind: kind, direction: resolution.direction, destination: destinations.first,
                recipientLabel: resolution.recipientLabel, proposal: proposal, title: workingTitle, calendar: calendar
            )

        return ActionIntent(
            itemID: input.itemID,
            meetingID: input.meetingID,
            kind: kind,
            direction: resolution.direction,
            owner: resolution.owner,
            ownerIsUser: resolution.ownerIsUser,
            recipients: resolutionOverride?.0 ?? resolution.recipients,
            recipientLabel: resolutionOverride.map { $0.1 } ?? resolution.recipientLabel,
            destinations: destinations,
            artifact: artifact,
            links: [],
            linkNote: (kind == .message || kind == .document) && explains ? "Add a link to a good reference" : nil,
            evidence: evidence,
            verdict: verdict,
            confidence: confidence,
            confidenceReasons: reasons,
            suggestedTitle: resolution.suggestedTitle,
            primaryLabel: primary,
            computedAt: now,
            inputFingerprint: "",
            draftedBy: nil,
            reviewable: reviewable
        )
    }

    static func evidence(_ match: EvidenceMatcher.Match, meetingDate: Date) -> ActionIntent.Evidence {
        ActionIntent.Evidence(
            quote: match.quote,
            speaker: match.turn.speaker,
            speakerIsUser: match.turn.isUser,
            offset: match.turn.start,
            spokenAt: match.turn.start.map { meetingDate.addingTimeInterval($0) },
            score: match.score
        )
    }

    // MARK: - Calendar

    static func calendarProposal(title: String, quote: String?, events: [IntentCalendarEvent], now: Date, calendar: Calendar, userName: String = "") -> ActionIntent.CalendarProposal {
        let text = [title, quote ?? ""].joined(separator: " ")
        let targets = SlotFinder.targetEvents(for: text, among: events, now: now, calendar: calendar)
        guard let target = targets.first else {
            let day = SlotFinder.weekdayNumber(in: IntentText.words(text)).map { calendar.weekdaySymbols[$0 - 1] }
            return ActionIntent.CalendarProposal(
                eventID: nil, eventTitle: day.map { "\($0)'s meeting" } ?? "The meeting", slots: [], editable: false, source: "none",
                note: "LidIA couldn't find this meeting in your calendars."
            )
        }
        let duration = max(15 * 60, target.end.timeIntervalSince(target.start))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let searchEnd = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: target.start)) ?? target.start
        let busy = events
            .filter { !$0.isAllDay && $0.id != target.id }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        let slots = SlotFinder.freeSlots(
            busy: busy, duration: duration,
            from: max(tomorrow, now), to: searchEnd,
            avoidDays: [target.start],
            preferTimeOfDay: target.start.timeIntervalSince(calendar.startOfDay(for: target.start)),
            calendar: calendar
        )
        let editable = target.source == "apple" && target.editable
        let attendees = target.attendees
            .map { ActionIntent.Person(name: AttendeeParser.parseEntry($0).first?.name ?? $0, email: $0.contains("@") ? $0 : nil) }
            // Not the user themself.
            .filter { person in
                !OwnerResolver.isUser(person.name, userName: userName)
                    && !(person.email.map { OwnerResolver.isUser(String($0.split(separator: "@")[0]), userName: userName) } ?? false)
            }
        var note: String?
        if target.source == "google" {
            note = "This event comes from Google Calendar, which LidIA can only read. Move it in Google Calendar."
        } else if !editable {
            note = "You can't edit this event (someone else organizes it). Ask the organizer, or propose a time."
        } else if slots.isEmpty {
            note = "No free time in the week after it."
        }
        return ActionIntent.CalendarProposal(
            eventID: target.id, eventTitle: target.title, currentStart: target.start, currentEnd: target.end,
            attendees: attendees, slots: slots, editable: editable, source: target.source, note: note
        )
    }

    // MARK: - Templates

    /// Summary bullets about the item, for a draft's substance.
    static func relevantBullets(_ summary: String, title: String, exclude: [String], limit: Int = 3) -> [String] {
        let keywords = IntentText.keywords(title).filter { word in !exclude.contains { IntentText.fold($0).contains(word) } }.map(IntentText.stem)
        guard !keywords.isEmpty else { return [] }
        let bullets = summary.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") || line.hasPrefix("*") else { return nil }
            let text = line.drop { $0 == "-" || $0 == "*" || $0 == " " }.replacingOccurrences(of: "**", with: "")
            return text.isEmpty ? nil : text
        }
        return bullets
            .map { bullet -> (String, Int) in
                let words = Set(IntentText.words(bullet).map(IntentText.stem))
                return (bullet, keywords.filter { stem in words.contains { IntentText.stemMatches($0, stem) } }.count)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func templateArtifact(
        kind: ActionIntent.Kind,
        input: IntentInput,
        title: String,
        resolution: OwnerResolver.Resolution,
        destination: ActionIntent.Destination?
    ) -> ActionIntent.Artifact {
        let sender = input.userName.split(separator: " ").first.map(String.init) ?? (input.userName.isEmpty ? "" : input.userName)
        let greeting = "Hi \(resolution.recipients.count == 1 ? resolution.recipients[0].firstName : (resolution.recipientLabel.map { $0.hasPrefix("the ") ? "all" : $0 } ?? "all")),"
        let bullets = relevantBullets(input.summary, title: title, exclude: [input.userName])
        let meeting = input.meetingTitle.trimmingCharacters(in: .whitespaces)
        let topic = FollowUpPlanner.subject(for: meeting).replacingOccurrences(of: " – Session recap & next steps", with: "")
        switch kind {
        case .message, .document where destination?.id != "notion":
            if resolution.direction == .othersOweUser {
                let body = [greeting, "", "Following up on \(title.prefix(1).lowercased() + title.dropFirst()) from \(meeting.isEmpty ? "our meeting" : meeting).",
                            "Could you let me know where it stands?", "", "Thanks,", sender].joined(separator: "\n")
                return .message(subject: "Following up: \(title.prefix(70))", body: body)
            }
            var lines = [greeting, "", opening(for: title)]
            if !bullets.isEmpty { lines += [""] + bullets.map { "- " + $0 } }
            if IntentText.words(title).contains(where: { ["explain", "share", "send", "walk"].contains($0) }) {
                lines += ["", "[add a link]"]
            }
            lines += ["", "Best,", sender]
            return .message(subject: "\(topic): \(sentence(title, lower: false))", body: lines.joined(separator: "\n"))
        case .document:
            var body = ["## Context", "From \(meeting) on \(input.meetingDate.formatted(date: .abbreviated, time: .omitted))."]
            if !bullets.isEmpty { body += [""] + bullets.map { "- " + $0 } }
            body += ["", "## To do", "- \(title)"]
            return .document(title: sentence(title, lower: false), body: body.joined(separator: "\n"))
        case .ticket:
            var body = [sentence(title, lower: false) + "."]
            if !bullets.isEmpty { body += ["", "Context:"] + bullets.map { "- " + $0 } }
            body += ["", "From \(meeting) (\(input.meetingDate.formatted(date: .abbreviated, time: .omitted)))."]
            return .ticket(title: sentence(title, lower: false), body: body.joined(separator: "\n"))
        case .research:
            var notes = ["Question: \(title)"]
            if !bullets.isEmpty { notes += ["", "What we know:"] + bullets.map { "- " + $0 } }
            return .research(notes: notes.joined(separator: "\n"))
        case .reminder, .unclear:
            return .reminder(title: title, notes: "From \(meeting)")
        case .schedule:
            return .none
        }
    }

    /// "As promised, here's a short explanation of the stacking process."
    static func opening(for title: String) -> String {
        var rest = title.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
        // Drop who it's for: the greeting says that.
        if let range = rest.range(of: #"\s+(to|for|with)\s+(the\s+)?[A-Z][\w'’.-]*(\s+(team|team's|and\s+\w+))?.*$"#, options: .regularExpression) {
            rest = String(rest[..<range.lowerBound])
        }
        let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = words.first?.lowercased(), words.count == 2 else { return "Following up on \(sentence(title, lower: true))." }
        switch verb {
        case "explain", "clarify", "describe": return "As promised, here's a short explanation of \(words[1])."
        case "share", "send", "forward", "circulate": return "As promised, here's the \(words[1].replacingOccurrences(of: #"^(the|a|an)\s+"#, with: "", options: [.regularExpression, .caseInsensitive]))."
        default: return "Following up on \(sentence(rest, lower: true))."
        }
    }

    /// "Explain the stacking process" → "explain the stacking process" (or capitalised).
    static func sentence(_ title: String, lower: Bool) -> String {
        let trimmed = title.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
        guard let first = trimmed.first else { return trimmed }
        return (lower ? first.lowercased() : first.uppercased()) + trimmed.dropFirst()
    }
}
