import AppKit
import UniformTypeIdentifiers

enum ExportService {
    static func meetingToMarkdown(_ meeting: Meeting) -> String {
        var md = "# \(meeting.title)\n\n"
        md += "**Date:** \(meeting.date.formatted(date: .complete, time: .shortened))\n"
        md += "**Duration:** \(formatDuration(meeting.duration))\n"

        if let attendees = meeting.calendarAttendees, !attendees.isEmpty {
            md += "**Attendees:** \(attendees.joined(separator: ", "))\n"
        }

        if !meeting.summary.isEmpty {
            md += "\n## Summary\n\n\(meeting.summary)\n"
        }

        if !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n## Notes\n\n\(meeting.notes)\n"
        }

        if !meeting.actionItems.isEmpty {
            md += "\n## Action Items\n\n"
            for item in meeting.actionItems {
                let check = item.isCompleted ? "[x]" : "[ ]"
                md += "- \(check) \(item.title)"
                if let assignee = item.assignee { md += " → \(assignee)" }
                if let deadline = item.displayDeadline { md += " (due: \(deadline))" }
                md += "\n"
            }
        }

        if !meeting.refinedTranscript.isEmpty {
            md += "\n## Transcript\n\n\(meeting.refinedTranscript)\n"
        }

        return md
    }

    static func summaryToMarkdown(_ meeting: Meeting) -> String {
        var md = "# \(meeting.title)\n\n"
        md += "**Date:** \(meeting.date.formatted(date: .complete, time: .shortened))\n"
        md += "**Duration:** \(formatDuration(meeting.duration))\n"

        if let attendees = meeting.calendarAttendees, !attendees.isEmpty {
            md += "**Attendees:** \(attendees.joined(separator: ", "))\n"
        }

        md += "\n\(meeting.summary)\n"

        if !meeting.actionItems.isEmpty {
            md += "\n## Action Items\n\n"
            for item in meeting.actionItems {
                let check = item.isCompleted ? "[x]" : "[ ]"
                md += "- \(check) \(item.title)"
                if let assignee = item.assignee { md += " → \(assignee)" }
                if let deadline = item.displayDeadline { md += " (due: \(deadline))" }
                md += "\n"
            }
        }

        return md
    }

    static func actionItemsToMarkdown(_ meeting: Meeting) -> String {
        meeting.actionItems.map { item in
            let check = item.isCompleted ? "[x]" : "[ ]"
            var line = "- \(check) \(item.title)"
            if let assignee = item.assignee { line += " → \(assignee)" }
            if let deadline = item.displayDeadline { line += " (due: \(deadline))" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - File export

    /// A filesystem-safe default name such as "2026-11-02 Weekly sync.md".
    static func suggestedFilename(title: String, date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let datePart = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = title
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let name = cleaned.isEmpty ? "Untitled meeting" : String(cleaned.prefix(80))
        return "\(datePart) \(name).md"
    }

    /// Writes the full meeting as Markdown to `url` (UTF-8, atomic).
    static func writeMarkdown(_ meeting: Meeting, to url: URL) throws {
        try meetingToMarkdown(meeting).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Asks where to save, then writes the meeting as Markdown.
    /// Returns the saved file URL, or nil if the user cancelled.
    /// Throws if the file could not be written.
    @MainActor
    @discardableResult
    static func exportToFile(_ meeting: Meeting) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Meeting"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedFilename(title: meeting.title, date: meeting.date)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try writeMarkdown(meeting, to: url)
        return url
    }

    /// Export with the error shown in an alert, for menu and context-menu callers.
    @MainActor
    static func exportToFileShowingErrors(_ meeting: Meeting) {
        do {
            try exportToFile(meeting)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t export “\(meeting.title.isEmpty ? "Untitled" : meeting.title)”"
            alert.runModal()
        }
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
