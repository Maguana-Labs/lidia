import Foundation

// MARK: - Outline parsing

/// The structure of the notes the user typed during the meeting.
struct NoteOutline: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var heading: String?
        var points: [String]
    }

    var sections: [Section]

    var allPoints: [String] { sections.flatMap(\.points) }
    var isEmpty: Bool { allPoints.isEmpty }
}

enum NoteOutlineParser {
    /// Parses free-form notes into headings and points. Markdown headings (`#`) and short
    /// lines ending in ":" start sections; bullets, numbers and checkboxes are stripped.
    static func parse(_ notes: String) -> NoteOutline {
        var sections: [NoteOutline.Section] = []
        var current = NoteOutline.Section(heading: nil, points: [])

        func push() {
            if current.heading != nil || !current.points.isEmpty {
                sections.append(current)
            }
        }

        for rawLine in notes.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard !heading.isEmpty else { continue }
                push()
                current = .init(heading: heading, points: [])
                continue
            }

            let point = stripMarker(line)
            guard !point.isEmpty else { continue }
            let isBullet = point != line
            if !isBullet, line.hasSuffix(":"), line.count <= 60, !line.dropLast().contains(":") {
                push()
                current = .init(heading: String(line.dropLast()).trimmingCharacters(in: .whitespaces), points: [])
                continue
            }
            current.points.append(point)
        }
        push()
        // Drop headings that never got points, unless they are the only content.
        let withPoints = sections.filter { !$0.points.isEmpty }
        return NoteOutline(sections: withPoints)
    }

    private static func stripMarker(_ line: String) -> String {
        var s = Substring(line)
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "[ ] ", "[x] ", "- ", "* ", "• ", "– ", "+ "] where s.hasPrefix(marker) {
            s = s.dropFirst(marker.count)
            break
        }
        // Numbered: "1. " or "1) "
        if let first = s.first, first.isNumber {
            let digits = s.prefix(while: \.isNumber)
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                s = rest.dropFirst(2)
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Merge

/// Builds a Granola-style summary around the user's own notes: every point the user
/// typed is kept verbatim (`fromUserNotes == true`), with AI-written detail from the
/// meeting placed directly under it, followed by topics the notes did not cover.
@MainActor
struct NotesMerger {
    let client: any LLMClient
    let model: String
    let budget: SummarizationBudget
    /// `PersonalGlossary.promptBlock`: the user's confirmed spellings.
    var glossary: String = ""

    struct EnhancementResponse: Decodable, Sendable {
        struct Detail: Decodable, Sendable {
            let point: Int
            let bullets: [StructuredSummary.SummaryBullet]
        }
        let details: [Detail]?
        let otherSections: [StructuredSummary.SummarySection]?

        enum CodingKeys: String, CodingKey {
            case details
            case otherSections = "other_sections"
        }
    }

    static let fallbackHeading = String(localized: "My notes")

    /// Merges the notes with the meeting record. Never throws: if the AI call fails the
    /// result still contains every user point, followed by the AI summary sections.
    func merge(
        outline: NoteOutline,
        record: String,
        aiSummary: StructuredSummary?,
        title: String
    ) async -> (summary: StructuredSummary, enhanced: Bool) {
        do {
            let response = try await requestEnhancement(outline: outline, record: record)
            return (Self.build(outline: outline, enhancement: response, aiSummary: aiSummary, title: title), true)
        } catch {
            return (Self.build(outline: outline, enhancement: nil, aiSummary: aiSummary, title: title), false)
        }
    }

    /// Pure assembly step, exposed for tests.
    static func build(
        outline: NoteOutline,
        enhancement: EnhancementResponse?,
        aiSummary: StructuredSummary?,
        title: String
    ) -> StructuredSummary {
        var detailsByPoint: [Int: [StructuredSummary.SummaryBullet]] = [:]
        for detail in enhancement?.details ?? [] {
            let cleaned = detail.bullets
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { StructuredSummary.SummaryBullet(text: $0.text, sourceQuote: $0.sourceQuote, fromUserNotes: false) }
            detailsByPoint[detail.point, default: []].append(contentsOf: cleaned)
        }

        var sections: [StructuredSummary.SummarySection] = []
        var pointNumber = 0
        for section in outline.sections {
            var bullets: [StructuredSummary.SummaryBullet] = []
            for point in section.points {
                pointNumber += 1
                bullets.append(.init(text: point, fromUserNotes: true))
                bullets.append(contentsOf: (detailsByPoint[pointNumber] ?? []).prefix(4))
            }
            sections.append(.init(heading: section.heading ?? fallbackHeading, bullets: bullets))
        }

        let extra: [StructuredSummary.SummarySection]
        if let enhancement {
            extra = (enhancement.otherSections ?? []).map { section in
                .init(heading: section.heading, bullets: section.bullets.map {
                    .init(text: $0.text, sourceQuote: $0.sourceQuote, fromUserNotes: false)
                })
            }
        } else {
            // AI enhancement failed: keep the regular AI summary under the user's notes.
            extra = aiSummary?.sections ?? []
        }
        let usedHeadings = Set(sections.map { $0.heading.lowercased() })
        for section in extra where !section.bullets.isEmpty {
            var section = section
            if usedHeadings.contains(section.heading.lowercased()) {
                section.heading += " " + String(localized: "(more)")
            }
            sections.append(section)
        }

        return StructuredSummary(
            title: aiSummary?.title ?? title,
            sections: sections,
            decisions: aiSummary?.decisions ?? [],
            actionItems: aiSummary?.actionItems ?? []
        )
    }

    private func requestEnhancement(outline: NoteOutline, record: String) async throws -> EnhancementResponse {
        let numbered = outline.allPoints.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let available = budget.inputTokens - TokenEstimator.estimate(numbered) - TokenEstimator.estimate(Self.systemPrompt)
        let fittedRecord = Self.fit(record, tokens: max(256, available))

        var content = try await client.chat(
            messages: [
                .init(role: "system", content: glossary.isEmpty ? Self.systemPrompt : Self.systemPrompt + "\n\n" + glossary),
                .init(role: "user", content: "USER NOTES:\n\(numbered)\n\nMEETING RECORD:\n\(fittedRecord)"),
            ],
            model: model,
            format: .json
        )
        content = MapReduceSummarizer.stripThinking(content)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.hasPrefix("{"), let start = content.firstIndex(of: "{") {
            content = String(content[start...])
        }
        guard let data = content.data(using: .utf8) else {
            throw LLMError.invalidResponse("Notes enhancement was not UTF-8")
        }
        return try JSONDecoder().decode(EnhancementResponse.self, from: data)
    }

    /// Keeps the leading part of `text` that fits `tokens`. Only reached when the caller
    /// had no better-fitting record; the pipeline normally passes text that already fits.
    static func fit(_ text: String, tokens: Int) -> String {
        guard TokenEstimator.estimate(text) > tokens else { return text }
        let chunks = TranscriptChunker.chunk(text, maxTokens: tokens)
        return chunks.first ?? ""
    }

    static let systemPrompt = """
        You enhance the notes a user typed during a meeting, using the meeting record.

        The user's points are numbered. For each point add 0-3 short supporting bullets \
        from the meeting record: facts, numbers, who said what, outcomes, next steps. \
        Do NOT repeat or reword the user's point. Skip a point if the record adds nothing.

        Then list important topics from the record that the user's notes did NOT cover, \
        grouped under short headings. Leave it empty if the notes covered everything.

        Rules:
        - Never invent anything that is not in the meeting record.
        - Use speaker labels exactly as they appear in the record ("Me", "Them", names).
        - "source_quote" is a short verbatim quote (5-15 words) from the record, or null.

        Respond ONLY with JSON, no markdown fences:
        {"details": [{"point": 1, "bullets": [{"text": "...", "source_quote": "..."}]}],
         "other_sections": [{"heading": "...", "bullets": [{"text": "...", "source_quote": null}]}]}
        """
}
