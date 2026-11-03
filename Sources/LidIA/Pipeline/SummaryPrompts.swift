import Foundation

/// Prompts for the streaming summary.
///
/// The visible summary is written as plain markdown (not JSON), so it can be
/// shown token by token while the model writes it. Structured data (title,
/// decisions, action items) comes from a separate, small extraction step
/// (`MeetingFactsExtractor`) and, as a fallback, from the "Next Steps" section
/// of the markdown itself.
///
/// The format mirrors Granola's notes, which the owner compared against
/// (docs/research/2026-11-summary-benchmark.md): 3–6 topic headings, terse
/// fact-dense bullets with nested detail, then a "Next Steps" section with one
/// owner per line.
enum SummaryPrompts {
    /// Heading of the closing section that lists commitments. Parsed by
    /// `SummaryMarkdownParser.nextSteps(in:)`.
    static let nextStepsHeading = "Next Steps"

    /// Marker the scripted test client and the Apple FM client use to tell a
    /// markdown-summary request from other chat calls.
    static let markdownSummaryMarker = "You write meeting notes in markdown"

    /// System prompt for the streamed markdown summary, or nil when the template
    /// is a custom free-form prompt that asks for its own (JSON) output. Those
    /// keep the legacy non-streaming JSON path so user prompts are honoured.
    static func markdownSystemPrompt(
        template: MeetingTemplate?,
        attendees: [String]?,
        wordCount: Int,
        glossary: String = "",
        userName: String = ""
    ) -> String? {
        let glossaryLine = (glossary.isEmpty ? "" : "\n- \(glossary)") + ownerRule(userName)
        let template = template ?? .general
        guard let sections = sectionGuidance(for: template) else { return nil }

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
        \(sections)
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

    /// Heading guidance per template. nil for free-form custom prompts.
    /// The prompt is v1 from docs/research/2026-11-summary-benchmark.md: v2 and
    /// v3 (fewer examples, a stricter Next Steps rule) scored worse on Qwen 3.5 4B.
    static func sectionGuidance(for template: MeetingTemplate) -> String? {
        switch template.id {
        case MeetingTemplate.general.id:
            return """
            - Pick 3–6 "### " headings named after the actual topics of the meeting \
            (e.g. "### Pricing for the EU launch", not "### Discussion"). Order them by importance.
            """
        case MeetingTemplate.oneOnOne.id:
            return """
            - Use these "### " headings, skipping any with nothing to say: Top of Mind, \
            Updates & Progress, Challenges & Blockers, Feedback & Alignment.
            """
        case MeetingTemplate.brainstorm.id:
            return """
            - Use these "### " headings, skipping any with nothing to say: Problem Context, \
            Ideas & Proposals (each idea with who proposed it and its pros and cons), \
            Themes & Patterns, Direction & Priorities.
            """
        case MeetingTemplate.standup.id:
            return """
            - Use these "### " headings, skipping any with nothing to say: Status Updates \
            (one bullet per person, name in bold), Blockers & Dependencies, Priorities.
            """
        default:
            break
        }
        guard !template.isAdvancedMode, !template.sections.isEmpty else { return nil }
        let lines = template.sections.map { section -> String in
            let format: String
            switch section.format {
            case .bullets: format = "bullets"
            case .prose: format = "a short paragraph"
            case .table: format = "a markdown table"
            }
            let detail = section.description.isEmpty ? "" : " — \(section.description)"
            return "  - ### \(section.name)\(detail) (as \(format))"
        }
        return "- Use these \"### \" headings in this order, skipping any with nothing to say:\n"
            + lines.joined(separator: "\n")
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

    /// Who owns a next step, relative to the person recording. The classic
    /// mistake it prevents: someone asks the user to explain something and
    /// the note says "explain it to <user>".
    static func ownerRule(_ userName: String) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return """

        - The user recording this is \(name) ("Me" in the transcript). In Next Steps write \(first) as the owner \
        of what they took on, never "Me", "User" or "You". When someone asks \(first) to do something, \(first) owns it \
        and it is done for the person who asked: the task names who it is for, never \(first) as the receiver.
        """
    }

    // MARK: - Facts extraction

    /// The facts prompt with who the user is, so owners come out right.
    static func factsSystemPrompt(userName: String) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return factsSystemPrompt }
        return factsSystemPrompt + "\n- The user is \(name) (\"Me\" in a transcript). Use their name as the assignee for what they took on. A task someone asked the user to do is the user's task, for the person who asked."
    }

    /// System prompt for the small structured step that runs next to the summary.
    static let factsSystemPrompt = """
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

    /// Marker so tests and logs can recognise the facts request.
    static let factsMarker = "You extract structured facts from meeting notes"
}
