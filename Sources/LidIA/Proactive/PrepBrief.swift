import Foundation

/// Builds the LLM prompt for a pre-meeting brief from the meeting's history.
///
/// History comes from `MeetingHistoryMatcher` (attendees AND title series), so
/// a weekly client call is recognised even when its attendees were imported
/// wrongly. When any history exists the prompt states it and forbids calling
/// the meeting a first encounter.
enum PrepBrief {
    /// Most recent past meetings whose summaries go into the prompt.
    static let summaryCount = 3
    /// Characters kept from each summary (small local models have small contexts).
    static let summaryCharacterLimit = 1_400
    static let openItemLimit = 10

    struct Context {
        let prompt: String
        let hasHistory: Bool
        let matchedMeetingIDs: [UUID]
    }

    @MainActor
    static func context(for upcoming: MeetingHistoryMatcher.Upcoming, library: [Meeting]) -> Context {
        let usable = library.filter { $0.status == .complete || !$0.summary.isEmpty }
        let matches = MeetingHistoryMatcher.matches(for: upcoming, in: usable)
        let related = matches.map(\.meeting)
        let openItems = related.flatMap(\.actionItems).filter { !$0.isCompleted }

        var lines: [String] = []
        lines.append("UPCOMING MEETING: \(upcoming.title)")
        lines.append("STARTS: \(upcoming.start.formatted(date: .abbreviated, time: .shortened))")
        if !upcoming.attendees.isEmpty {
            lines.append("ATTENDEES: \(upcoming.attendees.prefix(8).joined(separator: ", "))")
        }

        guard !related.isEmpty else {
            lines.append("")
            lines.append("(No earlier meetings with this title or these attendees are on record.)")
            let prompt = """
            You are a meeting prep assistant. The user has no earlier meetings with this title \
            or these attendees on record. In 2 short sentences (no bullets, no preamble), say this \
            looks like a first meeting and suggest one or two concrete things to think about based \
            on the title and attendees. Do not invent facts.

            \(lines.joined(separator: "\n"))
            """
            return Context(prompt: prompt, hasHistory: false, matchedMeetingIDs: [])
        }

        let sameSeries = matches.filter { !$0.reasons.isDisjoint(with: [.sameTitle, .calendarSeries, .similarTitle]) }.count
        lines.append("")
        lines.append("HISTORY: \(related.count) earlier meeting\(related.count == 1 ? "" : "s") on record"
            + (sameSeries > 0 ? " (\(sameSeries) in the same recurring series)" : "")
            + ", most recent first:")
        for meeting in related.prefix(8) {
            lines.append("- \(meeting.title) (\(meeting.date.formatted(date: .abbreviated, time: .omitted)))")
        }

        for meeting in related.prefix(summaryCount) {
            let summary = MeetingContextRetrievalService.effectiveSummary(for: meeting)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { continue }
            lines.append("")
            lines.append("NOTES FROM \(meeting.title.uppercased()) ON \(meeting.date.formatted(date: .abbreviated, time: .omitted)):")
            lines.append(String(summary.prefix(summaryCharacterLimit)) + (summary.count > summaryCharacterLimit ? " …" : ""))
        }

        if !openItems.isEmpty {
            lines.append("")
            lines.append("OPEN ACTION ITEMS FROM EARLIER MEETINGS:")
            for item in openItems.prefix(openItemLimit) {
                var line = "- \(item.title)"
                if let assignee = item.assignee, !assignee.isEmpty { line += " (owner: \(assignee))" }
                if let deadline = item.displayDeadline { line += " (due: \(deadline))" }
                lines.append(line)
            }
        }

        let prompt = """
        You are a meeting prep assistant. This meeting continues earlier ones: the user has met \
        on this before (see HISTORY). It is NOT a first meeting; never call it one. In 2–4 short \
        sentences (no bullets, no preamble), say what the user should know walking in: where \
        things stood last time, what was agreed, and which open items or questions to follow up \
        on. Be specific and use only the notes below.

        \(lines.joined(separator: "\n"))
        """
        return Context(prompt: prompt, hasHistory: true, matchedMeetingIDs: related.map(\.id))
    }
}
