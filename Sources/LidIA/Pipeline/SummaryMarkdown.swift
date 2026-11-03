import Foundation

/// Turns the streamed markdown summary into the structured pieces the rest of
/// the app stores: sections (`StructuredSummary`), decisions and next steps.
/// Pure and deterministic, so it can't fail the pipeline.
enum SummaryMarkdownParser {
    /// Removes a code fence or "Here are the notes:" preamble some models add.
    static func clean(_ markdown: String) -> String {
        var text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            } else {
                text = ""
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        // A one-line preamble before the first heading or bullet ("Here are the notes:").
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           lines.count > 1,
           !first.hasPrefix("#"), !first.hasPrefix("-"), !first.hasPrefix("*"),
           first.hasSuffix(":"), first.count < 80 {
            text = lines.dropFirst().joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sections in order. Nested bullets become their own bullets (the stored
    /// summary keeps the full markdown, so nesting is not lost for display).
    /// Text before the first heading goes under "Summary".
    static func sections(in markdown: String) -> [StructuredSummary.SummarySection] {
        var sections: [StructuredSummary.SummarySection] = []
        var heading: String?
        var bullets: [StructuredSummary.SummaryBullet] = []

        func flush() {
            if !bullets.isEmpty {
                sections.append(.init(heading: heading ?? String(localized: "Summary"), bullets: bullets))
            }
            bullets = []
        }

        for raw in clean(markdown).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                flush()
                heading = stripInlineMarkup(String(line.drop(while: { $0 == "#" })))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if let bold = boldHeading(line) {
                flush()
                heading = bold
                continue
            }
            let text = bulletText(line) ?? line
            guard !text.isEmpty else { continue }
            bullets.append(.init(text: text))
        }
        flush()
        return sections
    }

    /// Bullets that record a decision ("Decided: …"), with the prefix removed.
    static func decisions(in markdown: String) -> [String] {
        clean(markdown).components(separatedBy: .newlines).compactMap { raw in
            let text = bulletText(raw.trimmingCharacters(in: .whitespaces)) ?? ""
            let plain = stripInlineMarkup(text)
            for prefix in ["Decided:", "Decision:", "Decidido:", "Decisión:"] where plain.hasPrefix(prefix) {
                let rest = plain.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
            return nil
        }
    }

    /// Action items from the "Next Steps" section: "- Owner: task (deadline)".
    static func nextSteps(in markdown: String) -> [MeetingSummaryResponse.ActionItemResponse] {
        let headings = ["next steps", "next step", "action items", "próximos pasos", "siguientes pasos", "next steps & timeline"]
        var inSection = false
        var items: [MeetingSummaryResponse.ActionItemResponse] = []
        for raw in clean(markdown).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || boldHeading(line) != nil {
                let title = (boldHeading(line) ?? stripInlineMarkup(String(line.drop(while: { $0 == "#" }))))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                inSection = headings.contains(title)
                continue
            }
            // Only top-level bullets are tasks; nested ones are detail.
            guard inSection, !raw.hasPrefix("  "), !raw.hasPrefix("\t"),
                  let text = bulletText(line).map(stripInlineMarkup), !text.isEmpty else { continue }
            items.append(parseTask(text))
        }
        return items
    }

    /// "Alex: send the deck (by Friday)" → title "Send the deck", assignee "Alex", deadline "by Friday".
    static func parseTask(_ text: String) -> MeetingSummaryResponse.ActionItemResponse {
        var assignee: String?
        var body = text
        if let colon = text.firstIndex(of: ":") {
            let owner = text[..<colon].trimmingCharacters(in: .whitespaces)
            // An owner is a short name, not a sentence ("Note: …" is not an owner either).
            let words = owner.split(separator: " ")
            if !owner.isEmpty, words.count <= 4, !owner.contains("http"),
               !["note", "nota", "open question", "decided", "decision"].contains(owner.lowercased()) {
                let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    assignee = ["team", "equipo", "everyone", "all", "todos"].contains(owner.lowercased()) ? nil : owner
                    body = rest
                }
            }
        }
        var deadline: String?
        if body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
            let inner = body[body.index(after: open)..<body.index(before: body.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, inner.count <= 40 {
                deadline = inner
                body = body[..<open].trimmingCharacters(in: .whitespaces)
            }
        }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
        if let first = body.first, first.isLowercase {
            body = first.uppercased() + body.dropFirst()
        }
        return .init(title: body, assignee: assignee, deadline: deadline, sourceQuote: nil)
    }

    /// The first topic heading, used as a title fallback.
    static func firstHeading(in markdown: String) -> String? {
        sections(in: markdown).first { $0.heading != String(localized: "Summary") }?.heading
    }

    // MARK: - Line helpers

    static func bulletText(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        // Numbered list: "1. text" / "1) text"
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// A line that is only bold text ("**Pricing**") acts as a heading.
    private static func boldHeading(_ line: String) -> String? {
        guard line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"), line.count > 4 else { return nil }
        let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "*: "))
        return inner.contains("**") || inner.isEmpty ? nil : inner
    }

    static func stripInlineMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Drops a wrapping code fence while text streams, so the user never sees
/// "```markdown" flash before the notes or a stray "```" after them.
struct MarkdownStreamCleaner {
    private var decided = false
    private var buffer = ""
    /// Trailing backticks (and the whitespace before them) held back until we
    /// know whether they close a fence at the very end.
    private var held = ""

    mutating func consume(_ chunk: String) -> String {
        guard decided else { return start(chunk) }
        return passThrough(chunk)
    }

    mutating func finish() -> String {
        defer { buffer = ""; held = "" }
        guard decided else { return buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        let stripped = held.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.count >= 3 && stripped.allSatisfy { $0 == "`" } ? "" : held
    }

    private mutating func start(_ chunk: String) -> String {
        buffer += chunk
        let trimmed = buffer.drop(while: \.isWhitespace)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("```") {
            guard let newline = trimmed.firstIndex(of: "\n") else { return "" }
            decided = true
            let rest = String(trimmed[trimmed.index(after: newline)...])
            buffer = ""
            return passThrough(rest)
        }
        if "```".hasPrefix(trimmed) { return "" }
        decided = true
        let out = String(trimmed)
        buffer = ""
        return passThrough(out)
    }

    private mutating func passThrough(_ chunk: String) -> String {
        let text = held + chunk
        held = ""
        // Hold back a trailing run of backticks plus the whitespace before it.
        var cut = text.endIndex
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous] == "`" else { break }
            index = previous
        }
        guard index < text.endIndex else { return text }
        cut = index
        while cut > text.startIndex, text[text.index(before: cut)].isWhitespace {
            cut = text.index(before: cut)
        }
        held = String(text[cut...])
        return String(text[..<cut])
    }
}
