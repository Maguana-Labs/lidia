import Foundation

/// A meeting's content: what `SiriContentPolicy` guards.
public struct SiriMeetingContent: Sendable, Equatable {
    public var summary: String
    public var decisions: [String]
    public var notes: String

    public init(summary: String, decisions: [String] = [], notes: String = "") {
        self.summary = summary
        self.decisions = decisions
        self.notes = notes
    }
}

/// The recap Siri reads out or hands to Mail and Messages: plain text and HTML,
/// with the content left out when the policy says so.
public enum SiriRecap {
    // MARK: Decisions

    private struct DecisionsOnly: Decodable { var decisions: [String]? }

    /// Decisions from the Mac's structured summary JSON, if it has any.
    public static func decisions(fromStructuredSummary data: Data?) -> [String] {
        guard let data, let decoded = try? JSONDecoder().decode(DecisionsOnly.self, from: data) else { return [] }
        return (decoded.decisions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let decisionHeadings = ["decision", "decided", "agreed", "agreement", "decisiones", "acuerdo", "acordado"]

    /// Top-level bullets under a "Decisions" (or "Agreed", "Acuerdos") heading.
    public static func decisions(fromMarkdown markdown: String) -> [String] {
        var result: [String] = []
        var inDecisions = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = SiriText.fold(String(line.drop(while: { $0 == "#" })))
                inDecisions = decisionHeadings.contains { heading.contains($0) }
                continue
            }
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                let heading = SiriText.fold(String(line.dropFirst(2).dropLast(2)))
                inDecisions = decisionHeadings.contains { heading.contains($0) }
                continue
            }
            guard inDecisions, rawLine.hasPrefix("- ") || rawLine.hasPrefix("* ") else { continue }
            let text = clean(String(line.dropFirst(2)))
            if !text.isEmpty { result.append(text) }
        }
        return result
    }

    /// Markdown emphasis and links stripped, for speech and plain text.
    public static func clean(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "`", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The summary as plain sentences: headings and bullets without markup.
    public static func plainSummary(_ markdown: String) -> String {
        markdown.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") { return clean(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)) + ":" }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return "• " + clean(String(line.dropFirst(2))) }
            return clean(line)
        }
        .joined(separator: "\n")
    }

    // MARK: Recap

    static func dateLine(_ date: Date, duration: TimeInterval) -> String {
        var line = date.formatted(date: .complete, time: .shortened)
        if duration >= 60 { line += " · \(Int((duration / 60).rounded())) min" }
        return line
    }

    static func itemLine(_ item: SiriActionItemRecord) -> String {
        var line = item.title
        var details: [String] = []
        if let owner = item.owner, !owner.isEmpty { details.append(owner) }
        if let due = item.dueDate { details.append("due " + due.formatted(date: .abbreviated, time: .omitted)) }
        else if let due = item.dueText, !due.isEmpty { details.append("due " + due) }
        if item.status == .done { details.append("done") }
        if !details.isEmpty { line += " (" + details.joined(separator: ", ") + ")" }
        return line
    }

    /// The recap as plain text. `content` nil means the policy blocked it; the
    /// recap then says so instead of including the summary.
    public static func plainText(
        meeting: SiriMeetingRecord,
        content: SiriMeetingContent?,
        items: [SiriActionItemRecord],
        blockedMessage: String? = nil
    ) -> String {
        var parts: [String] = [meeting.displayTitle, dateLine(meeting.date, duration: meeting.duration)]
        let people = meeting.others.map(\.displayName).filter { !$0.isEmpty }
        if !people.isEmpty { parts.append("With " + people.joined(separator: ", ")) }
        if let project = meeting.project { parts.append("Project: " + project) }
        if let content {
            let summary = plainSummary(content.summary)
            if !summary.isEmpty { parts.append("\nSummary\n" + summary) }
            if !content.decisions.isEmpty {
                parts.append("\nDecisions\n" + content.decisions.map { "• " + clean($0) }.joined(separator: "\n"))
            }
        } else if let blockedMessage {
            parts.append("\n" + blockedMessage)
        }
        if !items.isEmpty {
            parts.append("\nAction items\n" + items.map { "• " + itemLine($0) }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The recap as a small HTML document (headings and lists), for Mail.
    public static func html(
        meeting: SiriMeetingRecord,
        content: SiriMeetingContent?,
        items: [SiriActionItemRecord],
        blockedMessage: String? = nil
    ) -> String {
        var body = "<h2>\(escape(meeting.displayTitle))</h2>\n<p>\(escape(dateLine(meeting.date, duration: meeting.duration)))"
        let people = meeting.others.map(\.displayName).filter { !$0.isEmpty }
        if !people.isEmpty { body += "<br>With \(escape(people.joined(separator: ", ")))" }
        if let project = meeting.project { body += "<br>Project: \(escape(project))" }
        body += "</p>\n"
        if let content {
            let lines = content.summary.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.isEmpty {
                body += "<h3>Summary</h3>\n"
                var inList = false
                for line in lines {
                    let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
                    if isBullet, !inList { body += "<ul>\n"; inList = true }
                    if !isBullet, inList { body += "</ul>\n"; inList = false }
                    if line.hasPrefix("#") {
                        body += "<h4>\(escape(clean(String(line.drop(while: { $0 == "#" })))))</h4>\n"
                    } else if isBullet {
                        body += "<li>\(escape(clean(String(line.dropFirst(2)))))</li>\n"
                    } else {
                        body += "<p>\(escape(clean(line)))</p>\n"
                    }
                }
                if inList { body += "</ul>\n" }
            }
            if !content.decisions.isEmpty {
                body += "<h3>Decisions</h3>\n<ul>\n" + content.decisions.map { "<li>\(escape(clean($0)))</li>" }.joined(separator: "\n") + "\n</ul>\n"
            }
        } else if let blockedMessage {
            body += "<p><em>\(escape(blockedMessage))</em></p>\n"
        }
        if !items.isEmpty {
            body += "<h3>Action items</h3>\n<ul>\n" + items.map { "<li>\(escape(itemLine($0)))</li>" }.joined(separator: "\n") + "\n</ul>\n"
        }
        return "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>\(escape(meeting.displayTitle))</title></head><body>\n\(body)</body></html>\n"
    }

    /// One action item as plain text (for Messages, Reminders, Mail).
    public static func plainText(item: SiriActionItemRecord) -> String {
        var lines = [item.title]
        if let owner = item.owner, !owner.isEmpty { lines.append("Owner: " + owner) }
        if let due = item.dueDate { lines.append("Due: " + due.formatted(date: .abbreviated, time: .omitted)) }
        else if let due = item.dueText, !due.isEmpty { lines.append("Due: " + due) }
        lines.append("Status: " + item.status.title)
        if let meeting = item.meetingTitle {
            var from = "From: " + meeting
            if let date = item.meetingDate { from += " (" + date.formatted(date: .abbreviated, time: .omitted) + ")" }
            lines.append(from)
        }
        return lines.joined(separator: "\n")
    }

    public static func html(item: SiriActionItemRecord) -> String {
        let rows = plainText(item: item).components(separatedBy: "\n")
        let head = rows.first.map { "<h3>\(escape($0))</h3>" } ?? ""
        let rest = rows.dropFirst().map { "<p>\(escape($0))</p>" }.joined(separator: "\n")
        return "<!doctype html>\n<html><head><meta charset=\"utf-8\"></head><body>\n\(head)\n\(rest)\n</body></html>\n"
    }
}
