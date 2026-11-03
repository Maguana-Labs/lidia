import Foundation

/// Block-level markdown for chat answers: headings, paragraphs, nested and
/// ordered lists, task lists, tables, fenced code, quotes and rules. Inline
/// markup is left to `AttributedString(markdown:)`. Lists of action items
/// (task lists, or a list under an "Action items" / "Next steps" heading)
/// become `.actionItems` so they render as interactive rows.
enum ChatMarkdown {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    struct ListItem: Equatable, Sendable {
        var indent: Int
        var text: String
        /// nil: a plain item; true/false: a task item and whether it's done.
        var task: Bool?
        /// The number of an ordered item.
        var number: Int?
    }

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [ListItem])
        case table(header: [String], alignments: [Alignment], rows: [[String]])
        case code(language: String?, code: String)
        case quote(String)
        case rule
        case actionItems([ChatActionItemDraft])
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code (an unclosed fence while streaming runs to the end).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushParagraph(); index += 1; continue }

            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1, "-*_".contains(trimmed.first!) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = trimmed.wholeMatch(of: /(#{1,6})\s+(.+?)\s*#*/) {
                flushParagraph()
                blocks.append(.heading(level: min(heading.1.count, 4), text: String(heading.2)))
                index += 1
                continue
            }

            // Tables: a header row, then a separator row.
            if trimmed.hasPrefix("|") || (trimmed.contains("|") && index + 1 < lines.count && isSeparatorRow(lines[index + 1])),
               index + 1 < lines.count, isSeparatorRow(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                let alignments = alignmentsOf(lines[index + 1], count: header.count)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var values = cells(row)
                    if values.count < header.count { values += Array(repeating: "", count: header.count - values.count) }
                    rows.append(Array(values.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quote.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                var ordered = false
                while index < lines.count {
                    let current = lines[index]
                    if let (item, isOrdered) = listItem(current) {
                        if items.isEmpty { ordered = isOrdered }
                        items.append(item)
                        index += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix("  "), !items.isEmpty {
                        // A wrapped continuation of the previous item.
                        items[items.count - 1].text += " " + current.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return promoteActionItems(blocks)
    }

    // MARK: - Lists

    static func listItem(_ line: String) -> (ListItem, Bool)? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let spaces = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(spaces)
        let indent = spaces / 2
        if let match = rest.wholeMatch(of: /[-*+•]\s+(.*)/) {
            return (item(indent: indent, body: String(match.1), number: nil), false)
        }
        if let match = rest.wholeMatch(of: /(\d{1,3})[.)]\s+(.*)/) {
            return (item(indent: indent, body: String(match.2), number: Int(match.1)), true)
        }
        return nil
    }

    private static func item(indent: Int, body: String, number: Int?) -> ListItem {
        if let task = body.wholeMatch(of: /\[([ xX])\]\s+(.*)/) {
            return ListItem(indent: indent, text: String(task.2), task: task.1 != " ", number: number)
        }
        return ListItem(indent: indent, text: body, task: nil, number: number)
    }

    // MARK: - Tables

    static func isSeparatorRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return false }
        let parts = cells(trimmed)
        return !parts.isEmpty && parts.allSatisfy { $0.wholeMatch(of: /:?-{2,}:?/) != nil }
    }

    static func cells(_ row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func alignmentsOf(_ separator: String, count: Int) -> [Alignment] {
        let parts = cells(separator)
        return (0..<count).map { index in
            guard index < parts.count else { return .leading }
            let part = parts[index]
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    // MARK: - Action items

    /// Headings or lead-in lines that introduce action items.
    static func introducesActionItems(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["action item", "next step", "to-do", "todo", "to do", "follow-up", "follow up", "tasks", "owners"]
            .contains { lower.contains($0) }
    }

    private static func promoteActionItems(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        for block in blocks {
            guard case .list(_, let items) = block else { result.append(block); continue }
            let topLevel = items.filter { $0.indent == 0 }
            let allTasks = !topLevel.isEmpty && topLevel.allSatisfy { $0.task != nil }
            var introduced = false
            if let previous = result.last {
                switch previous {
                case .heading(_, let text): introduced = introducesActionItems(text)
                case .paragraph(let text): introduced = text.hasSuffix(":") && introducesActionItems(text)
                default: break
                }
            }
            if allTasks || introduced {
                result.append(.actionItems(topLevel.map { ChatActionItemDraft.parse($0.text, done: $0.task ?? false) }))
            } else {
                result.append(block)
            }
        }
        return result
    }
}

/// One action item in an answer: title, owner and due date pulled from the
/// usual ways models write them.
struct ChatActionItemDraft: Equatable, Sendable, Identifiable {
    var title: String
    var assignee: String?
    var due: String?
    var done: Bool

    var id: String { title }

    static func parse(_ raw: String, done: Bool = false) -> ChatActionItemDraft {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var assignee: String?
        var due: String?
        var done = done

        // IDs and board statuses the tools return: "[a1b2c3d4] [todo] …".
        text = text.replacing(/\[[0-9a-fA-F]{8}\]\s*/, with: "")
        if let status = text.firstMatch(of: /^\[(todo|in progress|in_progress|waiting|done|blocked)\]\s*/.ignoresCase()) {
            if status.1.lowercased() == "done" { done = true }
            text.removeSubrange(status.range)
        }

        // "(Owner: Daniel, due 2026-11-05)" and similar.
        if let match = text.firstMatch(of: /(?i)\(?\b(?:owner|assignee|assigned to)\s*:?\s*([^,;)\]]+)/) {
            assignee = clean(String(match.1))
            text.removeSubrange(match.range)
        }
        if let match = text.firstMatch(of: /(?i)[,;(]?\s*\b(?:due|deadline|by)\s*:?\s+((?:\d{4}-\d{2}-\d{2})|(?:(?:mon|tues|wednes|thurs|fri|satur|sun)day|today|tomorrow|end of (?:day|week|month)|next week|(?:\d{1,2}\s+)?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?(?:\s+\d{1,2})?))\)?/) {
            due = clean(String(match.1))
            text.removeSubrange(match.range)
        }
        // "**Daniel**: …" / "Daniel: …" (a name of up to three words).
        if assignee == nil, let match = text.firstMatch(of: /^\*{0,2}([A-Z][\p{L}.'-]+(?:\s[A-Z][\p{L}.'-]+){0,2})\*{0,2}\s*[:—–]\s+/) {
            assignee = String(match.1)
            text.removeSubrange(match.range)
        }
        // "… — Daniel" / "… - Daniel" at the end.
        if assignee == nil, let match = text.firstMatch(of: /\s+[—–-]\s+\*{0,2}([A-Z][\p{L}.'-]+(?:\s[A-Z][\p{L}.'-]+){0,2})\*{0,2}\s*$/) {
            assignee = String(match.1)
            text.removeSubrange(match.range)
        }
        // "@Daniel …".
        if assignee == nil, let match = text.firstMatch(of: /@([A-Z][\p{L}.'-]+)/) {
            assignee = String(match.1)
            text.removeSubrange(match.range)
        }

        text = text.replacingOccurrences(of: "()", with: "")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-").union(.whitespaces))
        if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 { text = String(text.dropFirst(2).dropLast(2)) }
        return ChatActionItemDraft(title: text, assignee: assignee, due: due, done: done)
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " *_().,;").union(.whitespaces))
    }
}
