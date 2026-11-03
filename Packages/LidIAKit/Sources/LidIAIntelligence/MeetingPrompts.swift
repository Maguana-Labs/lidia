import Foundation

/// Prompts for meeting notes, facts and Ask.
///
/// Same shape as the Mac's `SummaryPrompts` (Sources/LidIA/Pipeline/SummaryPrompts.swift,
/// the "general" template) so a meeting summarised on iPhone reads like one
/// summarised on the Mac: 3–6 topic headings, terse bullets, "Decided:" lines
/// and a closing "### Next Steps" section with one owner per line.
public enum MeetingPrompts {
    public static let nextStepsHeading = "Next Steps"
    public static let markdownSummaryMarker = "You write meeting notes in markdown"
    public static let factsMarker = "You extract structured facts from meeting notes"

    /// System prompt for the streamed markdown notes.
    public static func notesSystemPrompt(attendees: [String]?, wordCount: Int, glossary: String = "") -> String {
        let glossaryLine = glossary.isEmpty ? "" : "\n- \(glossary)"
        if wordCount < 100 {
            return """
            \(markdownSummaryMarker). The transcript below is VERY SHORT.

            Write one to three plain markdown bullets saying only what was actually said. \
            No headings unless something was explicitly agreed, in which case add a \
            "### \(nextStepsHeading)" section with one "- Owner: task" line per commitment.

            Never invent names, numbers, decisions or tasks. A short, accurate note is always \
            better than a long, invented one. Output only the markdown, with no preamble.
            \(attendeeRules(attendees))\(glossaryLine)
            """
        }

        return """
        \(markdownSummaryMarker), like a sharp chief of staff. Read the transcript and write \
        the notes someone would want if they missed the meeting.

        FORMAT (markdown only, no preamble, no closing remarks, no code fences):
        - Pick 3–6 "### " headings named after the actual topics of the meeting \
        (e.g. "### Pricing for the EU launch", not "### Discussion"). Order them by importance.
        - Under each heading, write short, fact-dense bullets (fragments, not full prose). \
        Put supporting detail in nested bullets indented by two spaces.
        - Keep every specific: names, numbers, amounts, dates, tools, systems, products, \
        customers and the reasons behind a position. Prefer "Budget capped at $40k for Q1" \
        over "The budget was discussed".
        - Attribute statements and proposals to people by name when the transcript makes the \
        speaker clear.
        - Record decisions as bullets that start with "Decided:".
        - Finish with a "### \(nextStepsHeading)" section: one line per commitment, written as \
        "- Owner: what they will do (deadline, only if one was stated)". Only include tasks \
        someone actually took on or was asked to do; "we should think about X" is not a task. \
        Use "Team" as the owner when nobody specific took it. Omit the section if there are none.
        - Typical length: 300–700 words. Shorter for short meetings. Never pad.

        ACCURACY:
        - Use only what is in the transcript. Never invent names, numbers, dates, deadlines or \
        decisions. If something was unclear or left open, say so ("Open question: …").
        - Transcripts come from speech recognition and contain errors. Write names and terms \
        the way they are most likely meant, but never guess facts.
        - Write in the language the meeting was held in.
        \(attendeeRules(attendees))\(glossaryLine)
        """
    }

    private static func attendeeRules(_ attendees: [String]?) -> String {
        guard let attendees, !attendees.isEmpty else {
            return """
            - There is no attendee list. Use only names that appear in the transcript; \
            otherwise write "a participant" or "the team".
            """
        }
        let names = attendees.prefix(20).joined(separator: ", ")
        return """
        - Attendees from the calendar: \(names). Use these spellings for names. Never attribute \
        something to a person the transcript doesn't support.
        """
    }

    /// Header for the final pass when the transcript was condensed first.
    public static func reduceHeader(partCount: Int) -> String {
        "The meeting was long, so it was condensed into \(partCount) parts of dense notes, in order. Write the notes from these.\n\n"
    }

    /// System prompt for the small structured step that runs after the notes.
    public static let factsSystemPrompt = """
        You extract structured facts from meeting notes. Respond with ONLY a JSON object, \
        no code fences:
        {"title": "...", "decisions": ["..."], "action_items": [{"title": "...", "assignee": "..." or null, "deadline": "..." or null}]}

        Rules:
        - "title": a specific meeting title of at most 8 words, naming the main topic \
        (e.g. "Q3 pricing review with Acme"), never "Meeting summary".
        - "decisions": things that were explicitly decided. Empty array if none.
        - "action_items": tasks someone committed to or was asked to do, starting with a verb. \
        "assignee" is the person's name exactly as written, or null. "deadline" exactly as \
        stated, or null. Never invent owners or dates. Empty array if none.
        - Write in the language of the notes.
        """

    /// Instructions for Ask: answer from the excerpts, cite by number.
    public static func askInstructions(userName: String?) -> String {
        let who = (userName?.isEmpty == false) ? " The user's name is \(userName!)." : ""
        return """
        You are LidIA, a private assistant for the user's meetings.\(who) Answer the question \
        using only the meeting excerpts provided, each labelled [1], [2] and so on. \
        Be brief and specific: lead with the answer, then at most a few short bullets. \
        Mention who said or owns something when the excerpts say so. When you use an excerpt, \
        cite it with its label, like [2]. If the excerpts don't contain the answer, say you \
        couldn't find it in these meetings. Never invent names, dates, numbers or commitments. \
        Answer in the language of the question.
        """
    }
}
