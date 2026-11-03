import Foundation

/// An action item extracted from notes.
public struct ExtractedActionItem: Sendable, Hashable, Codable {
    public var title: String
    public var assignee: String?
    public var deadline: String?
    public var sourceQuote: String?

    public init(title: String, assignee: String? = nil, deadline: String? = nil, sourceQuote: String? = nil) {
        self.title = title
        self.assignee = assignee
        self.deadline = deadline
        self.sourceQuote = sourceQuote
    }
}

/// Reads the streamed markdown notes. Ported from the Mac's
/// `SummaryMarkdownParser` (Sources/LidIA/Pipeline/SummaryMarkdown.swift).
public enum NotesMarkdown {
    public struct Section: Sendable, Hashable {
        public var heading: String
        public var bullets: [Bullet]
    }

    public struct Bullet: Sendable, Hashable {
        public var text: String
        /// 0 for top level, 1 for "  - nested".
        public var depth: Int
    }

    /// Removes a code fence or "Here are the notes:" preamble some models add.
    public static func clean(_ markdown: String) -> String {
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
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           lines.count > 1,
           !first.hasPrefix("#"), !first.hasPrefix("-"), !first.hasPrefix("*"),
           first.hasSuffix(":"), first.count < 80 {
            text = lines.dropFirst().joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sections in order, keeping one level of nesting for display. Text
    /// before the first heading goes under `leadHeading`.
    public static func sections(in markdown: String, leadHeading: String = "Summary") -> [Section] {
        var sections: [Section] = []
        var heading: String?
        var bullets: [Bullet] = []

        func flush() {
            if !bullets.isEmpty {
                sections.append(Section(heading: heading ?? leadHeading, bullets: bullets))
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
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let text = bulletText(line) ?? line
            guard !text.isEmpty else { continue }
            bullets.append(Bullet(text: text, depth: indent >= 2 ? 1 : 0))
        }
        flush()
        return sections
    }

    /// Bullets that record a decision ("Decided: …"), with the prefix removed.
    public static func decisions(in markdown: String) -> [String] {
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
    public static func nextSteps(in markdown: String) -> [ExtractedActionItem] {
        let headings = ["next steps", "next step", "action items", "próximos pasos", "siguientes pasos"]
        var inSection = false
        var items: [ExtractedActionItem] = []
        for raw in clean(markdown).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || boldHeading(line) != nil {
                let title = (boldHeading(line) ?? stripInlineMarkup(String(line.drop(while: { $0 == "#" }))))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                inSection = headings.contains(title)
                continue
            }
            guard inSection, !raw.hasPrefix("  "), !raw.hasPrefix("\t"),
                  let text = bulletText(line).map(stripInlineMarkup), !text.isEmpty else { continue }
            items.append(parseTask(text))
        }
        return items
    }

    /// "Alex: send the deck (by Friday)" → title "Send the deck", assignee "Alex", deadline "by Friday".
    public static func parseTask(_ text: String) -> ExtractedActionItem {
        var assignee: String?
        var body = text
        if let colon = text.firstIndex(of: ":") {
            let owner = text[..<colon].trimmingCharacters(in: .whitespaces)
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
        return ExtractedActionItem(title: body, assignee: assignee, deadline: deadline)
    }

    /// The first topic heading, used as a title fallback.
    public static func firstHeading(in markdown: String) -> String? {
        sections(in: markdown).first { $0.heading != "Summary" && $0.heading.lowercased() != "next steps" }?.heading
    }

    /// A one-line plain preview of the notes (first top-level bullet).
    public static func preview(of markdown: String) -> String? {
        for section in sections(in: markdown) where section.heading.lowercased() != "next steps" {
            if let bullet = section.bullets.first(where: { $0.depth == 0 }) {
                return stripInlineMarkup(bullet.text)
            }
        }
        return nil
    }

    // MARK: - Line helpers

    public static func bulletText(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func boldHeading(_ line: String) -> String? {
        guard line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"), line.count > 4 else { return nil }
        let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "*: "))
        return inner.contains("**") || inner.isEmpty ? nil : inner
    }

    public static func stripInlineMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Drops a wrapping code fence while text streams, so the user never sees
/// "```markdown" flash before the notes. Ported from the Mac.
public struct MarkdownStreamCleaner: Sendable {
    private var decided = false
    private var buffer = ""
    private var held = ""

    public init() {}

    public mutating func consume(_ chunk: String) -> String {
        guard decided else { return start(chunk) }
        return passThrough(chunk)
    }

    public mutating func finish() -> String {
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
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous] == "`" else { break }
            index = previous
        }
        guard index < text.endIndex else { return text }
        var cut = index
        while cut > text.startIndex, text[text.index(before: cut)].isWhitespace {
            cut = text.index(before: cut)
        }
        held = String(text[cut...])
        return String(text[..<cut])
    }
}
