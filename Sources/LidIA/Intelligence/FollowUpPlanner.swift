import Foundation

/// Reads a markdown summary's sections: top bullets per heading and the
/// next steps (a "Next steps" / "Action items" section, plus Granola's bold
/// task lines such as "- **Share the recording** (Mateo)").
enum SummaryOutline {
    struct Section: Sendable, Equatable {
        var heading: String
        var bullets: [String]
    }

    struct NextStep: Hashable, Sendable {
        var text: String
        var owner: String?
    }

    static func sections(_ markdown: String) -> [Section] {
        var result: [Section] = []
        var current: Section?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if let current { result.append(current) }
                current = Section(heading: line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), bullets: [])
            } else if (rawLine.hasPrefix("- ") || rawLine.hasPrefix("* ")), !line.isEmpty {
                // Top-level bullets only.
                let text = clean(String(line.dropFirst(2)))
                guard !text.isEmpty else { continue }
                if current == nil { current = Section(heading: "", bullets: []) }
                current?.bullets.append(text)
            }
        }
        if let current { result.append(current) }
        return result
    }

    static func isNextStepsHeading(_ heading: String) -> Bool {
        let folded = heading.lowercased()
        return ["next step", "action item", "to-do", "todo", "follow-up", "follow up", "takeaway"].contains { folded.contains($0) }
    }

    /// Next steps, deduplicated, in the order they appear.
    static func nextSteps(_ markdown: String) -> [NextStep] {
        var result: [NextStep] = []
        var seen: Set<String> = []
        func add(_ step: NextStep) {
            let key = ProjectCatalog.fold(step.text)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            result.append(step)
        }
        for section in sections(markdown) where isNextStepsHeading(section.heading) {
            for bullet in section.bullets { add(split(bullet)) }
        }
        // Granola's task lines: "- **Title** (Owner)" anywhere.
        for line in markdown.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(of: /^\s*[-*]\s+\*\*(.+?)\*\*\s*(?:\(([^)]+)\))?\s*$/) else { continue }
            add(NextStep(text: String(match.1).trimmingCharacters(in: .whitespaces), owner: match.2.map { String($0) }))
        }
        return result
    }

    /// The first bullet of each topic (not next steps), for a recap.
    static func keyPoints(_ markdown: String, limit: Int = 3) -> [String] {
        sections(markdown)
            .filter { !isNextStepsHeading($0.heading) }
            .compactMap(\.bullets.first)
            .filter { !$0.hasPrefix("**") }
            .prefix(limit)
            .map { $0 }
    }

    /// "Title (Owner)" → text and owner.
    private static func split(_ bullet: String) -> NextStep {
        if let match = bullet.firstMatch(of: /^(.+?)\s*\(([^)]{2,40})\)\s*$/) {
            return NextStep(text: String(match.1), owner: String(match.2))
        }
        return NextStep(text: bullet, owner: nil)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\\~", with: "~")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Suggested follow-up emails after meetings with people from outside the
/// user's company, drafted on this Mac from the summary and action items.
/// Nothing is sent: the draft opens in Mail or goes to the clipboard.
enum FollowUpPlanner {
    /// How far back a meeting still deserves a follow-up.
    static let maxAgeDays = 10
    /// A summary shorter than this (with no next steps) has nothing to recap.
    static let minSummaryLength = 300

    struct Draft: Identifiable, Hashable, Sendable {
        var meetingID: UUID
        var meetingTitle: String
        var meetingDate: Date
        /// The person the email is to (first) and everyone else outside.
        var recipients: [MeetingAttendee]
        var company: String?
        var subject: String
        var body: String
        var reasons: [String]

        var id: String { "followup:" + meetingID.uuidString }
        var primary: MeetingAttendee? { recipients.first }
    }

    enum Ineligible: Equatable, Sendable {
        case notComplete, noExternalAttendees, tooOld, inFuture, nothingToRecap, alreadyHandled, newerMeetingInSeries
    }

    /// People from outside the user's company who have an email address.
    static func externalRecipients(_ meeting: MeetingSignals, context: ProjectSuggester.Context) -> [MeetingAttendee] {
        meeting.attendees.filter { attendee in
            guard !attendee.isCurrentUser, let domain = attendee.domain else { return false }
            if context.homeDomains.contains(domain) { return false }
            if let company = attendee.company, context.homeCompanies.contains(ProjectCatalog.fold(company)) { return false }
            return true
        }
    }

    static func hasSubstance(_ meeting: MeetingSignals) -> Bool {
        meeting.summary.count >= minSummaryLength
            || !SummaryOutline.nextSteps(meeting.summary).isEmpty
            || meeting.actionItems.contains { !$0.isCompleted }
    }

    /// Why a meeting gets no follow-up, or nil when it should.
    static func ineligibility(
        _ meeting: MeetingSignals,
        among all: [MeetingSignals],
        context: ProjectSuggester.Context,
        handled: Set<UUID>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Ineligible? {
        guard meeting.isComplete else { return .notComplete }
        if handled.contains(meeting.id) { return .alreadyHandled }
        guard meeting.date <= now else { return .inFuture }
        guard let cutoff = calendar.date(byAdding: .day, value: -maxAgeDays, to: calendar.startOfDay(for: now)),
              meeting.date >= cutoff else { return .tooOld }
        guard !externalRecipients(meeting, context: context).isEmpty else { return .noExternalAttendees }
        guard hasSubstance(meeting) else { return .nothingToRecap }
        // Only the latest meeting of a series with something to recap.
        if let key = meeting.seriesKey,
           all.contains(where: { $0.id != meeting.id && $0.seriesKey == key && $0.date > meeting.date && $0.isComplete && hasSubstance($0) }) {
            return .newerMeetingInSeries
        }
        return nil
    }

    /// Drafts for every eligible meeting, newest first.
    static func drafts(
        _ meetings: [MeetingSignals],
        handled: Set<UUID>,
        senderName: String,
        transcriptMentions: [UUID: String] = [:],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Draft] {
        let context = ProjectSuggester.Context.build(meetings)
        return meetings
            .filter { ineligibility($0, among: meetings, context: context, handled: handled, now: now, calendar: calendar) == nil }
            .sorted { $0.date > $1.date }
            .map { draft(for: $0, among: meetings, context: context, senderName: senderName, mentionsText: transcriptMentions[$0.id] ?? "", now: now, calendar: calendar) }
    }

    /// The email for one meeting.
    static func draft(
        for meeting: MeetingSignals,
        among all: [MeetingSignals],
        context: ProjectSuggester.Context,
        senderName: String,
        mentionsText: String = "",
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Draft {
        // The person mentioned most in the notes and transcript goes first.
        let text = (meeting.summary + " " + meeting.notes + " " + mentionsText).lowercased()
        let recipients = externalRecipients(meeting, context: context)
            .enumerated()
            .sorted { lhs, rhs in
                let l = mentions(of: lhs.element, in: text), r = mentions(of: rhs.element, in: text)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
        let company = AttendeeGrouping.externalCompanies(recipients).first
        let firstName = recipients.first.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name } ?? "there"

        let steps = nextSteps(for: meeting)
        let points = SummaryOutline.keyPoints(meeting.summary)
        let when = dayPhrase(meeting.date, now: now, calendar: calendar)

        var lines: [String] = ["Hi \(firstName),", "", "Thanks for the time \(when). Here's a short recap of what we covered and what comes next."]
        if !points.isEmpty {
            lines += ["", "What we covered"] + points.map { "- " + $0 }
        }
        if !steps.isEmpty {
            lines += ["", "Next steps"] + steps.map { step in "- " + step.text + (step.owner.map { " (\($0))" } ?? "") }
        }
        lines += ["", "Let me know if I missed anything.", "", "Best,", senderName.split(separator: " ").first.map(String.init) ?? senderName]

        var reasons: [String] = []
        if let company { reasons.append("You met people from \(company) \(when)") }
        if let promise = steps.first(where: { isRecapPromise($0.text) }) {
            reasons.append("You said you'd “\(promise.text.prefix(60))\(promise.text.count > 60 ? "…" : "")”")
        }
        let habit = followUpHabit(for: meeting, among: all)
        if let habit { reasons.append(habit) }
        if !steps.isEmpty { reasons.append("\(steps.count) next \(steps.count == 1 ? "step" : "steps") to confirm") }

        return Draft(
            meetingID: meeting.id,
            meetingTitle: meeting.title.trimmingCharacters(in: .whitespaces),
            meetingDate: meeting.date,
            recipients: recipients,
            company: company,
            subject: subject(for: meeting.title),
            body: lines.joined(separator: "\n"),
            reasons: reasons
        )
    }

    /// Summary next steps plus open action items, deduplicated, at most six.
    static func nextSteps(for meeting: MeetingSignals) -> [SummaryOutline.NextStep] {
        var steps = SummaryOutline.nextSteps(meeting.summary)
        var seen = Set(steps.map { ProjectCatalog.fold($0.text) })
        for item in meeting.actionItems where !item.isCompleted {
            let key = ProjectCatalog.fold(item.title)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            steps.append(SummaryOutline.NextStep(text: item.title, owner: item.assignee))
        }
        return Array(steps.prefix(6))
    }

    /// "Northwind x Harborcloud – Session recap & next steps".
    static func subject(for title: String) -> String {
        var base = title.trimmingCharacters(in: .whitespaces)
        for separator in [" - ", " – ", " — ", ": "] {
            if let range = base.range(of: separator), base.distance(from: base.startIndex, to: range.lowerBound) >= 8 {
                base = String(base[..<range.lowerBound])
                break
            }
        }
        return "\(base.isEmpty ? "Our meeting" : base) – Session recap & next steps"
    }

    /// "today", "yesterday", "on Tuesday", "on Oct 28".
    static func dayPhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return "on " + date.formatted(style)
        }
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.calendar = calendar
        dayStyle.timeZone = calendar.timeZone
        return "on " + date.formatted(dayStyle)
    }

    /// A next step that promises to send something.
    static func isRecapPromise(_ text: String) -> Bool {
        let folded = text.lowercased()
        let verbs = ["send", "share", "email", "forward", "circulate"]
        let objects = ["recap", "summary", "recording", "notes", "deck", "slides", "proposal", "estimate", "follow", "minutes", "plan"]
        return verbs.contains { folded.contains($0) } && objects.contains { folded.contains($0) }
    }

    /// "You promised a recap after 3 of the last 4": past meetings in the
    /// series whose next steps promised to send something.
    static func followUpHabit(for meeting: MeetingSignals, among all: [MeetingSignals]) -> String? {
        guard let key = meeting.seriesKey else { return nil }
        let past = all
            .filter { $0.id != meeting.id && $0.seriesKey == key && $0.date < meeting.date && $0.isComplete }
            .sorted { $0.date > $1.date }
            .prefix(4)
        guard past.count >= 2 else { return nil }
        let promised = past.filter { other in SummaryOutline.nextSteps(other.summary).contains { isRecapPromise($0.text) } }.count
        guard promised >= 2, Double(promised) >= Double(past.count) * 0.5 else { return nil }
        return "You usually follow up: you promised a recap after \(promised) of the last \(past.count) meetings in this series"
    }

    private static func mentions(of attendee: MeetingAttendee, in text: String) -> Int {
        guard let first = attendee.name.split(separator: " ").first?.lowercased(), first.count >= 3 else { return 0 }
        return text.components(separatedBy: first).count - 1
    }
}
