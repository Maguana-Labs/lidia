import Foundation
import LidIAKit
import SwiftData
import os

/// What's left of the old text-marker tool calls: the personalization prompt
/// and a cleaner for `<tool>…</tool>` blocks in older saved answers. Tools
/// now go through the agent harness (`Sources/LidIA/Agent/`), never through
/// markers parsed out of free text.
@MainActor
struct VoiceToolExecutor {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "VoiceToolExecutor")

    struct Result {
        let spokenResponse: String
        let executedActions: [String]
    }

    /// Builds a personalization prefix for system prompts.
    /// Combines settings (name, personality) with user preferences file (~/.lidia/soul.md).
    static func personalizationPrompt(settings: AppSettings) -> String {
        var parts: [String] = []
        let name = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            parts.append("The user's name is \(name). Address them by name occasionally.")
        }
        parts.append(settings.assistantPersonality.promptFragment)

        // Integration status — so the assistant can guide the user
        let integrations = integrationStatus(settings: settings)
        if !integrations.isEmpty {
            parts.append("\nIntegration status (if the user asks you to do something requiring an unconfigured integration, tell them to set it up in Settings):\n\(integrations)")
        }

        // Load SOUL.md — user-edited personality and instructions
        let soulContent = loadFile(LidIAFiles.soulFilePath, maxChars: 2000)
        if !soulContent.isEmpty {
            parts.append("\nSOUL.md (the user's personality and instructions for you — follow these closely):\n\(soulContent)")
        }

        // Load MEMORY.md — things you've remembered about the user
        let memoryContent = loadFile(LidIAFiles.memoryFilePath, maxChars: 2000)
        if !memoryContent.isEmpty {
            parts.append("\nMEMORY.md (things you've learned about this user — reference naturally):\n\(memoryContent)")
        }

        return parts.joined(separator: " ")
    }

    /// Returns a summary of which integrations are configured.
    private static func integrationStatus(settings: AppSettings) -> String {
        var lines: [String] = []
        lines.append("- Notion: \(!settings.notionAPIKey.isEmpty ? "configured" : "not configured")")
        lines.append("- Google Calendar: \(settings.googleCalendarEnabled && GoogleOAuthCredentials.resolve(settings: settings) != nil ?"configured" : "not configured")")
        lines.append("- Apple Calendar: \(settings.calendarEnabled ? "enabled" : "not enabled")")
        lines.append("- Apple Reminders: \(settings.remindersEnabled ? "enabled" : "not enabled")")
        lines.append("- n8n Webhooks: \(settings.n8nEnabled && !settings.n8nWebhookURL.isEmpty ? "configured" : "not configured")")
        lines.append("- OpenAI API: \(!settings.openaiAPIKey.isEmpty ? "configured" : "not configured")")
        lines.append("- Anthropic API: \(!settings.anthropicAPIKey.isEmpty ? "configured" : "not configured")")
        return lines.joined(separator: "\n")
    }

    /// Reads a file if it exists, capped at maxChars.
    private static func loadFile(_ path: String, maxChars: Int) -> String {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return String(content.prefix(maxChars))
    }

    // MARK: - Tool Marker Stripping

    /// Strips `<tool>...</tool>` blocks from text, returning only the spoken content.
    /// Used by sentence-level TTS to avoid synthesizing tool call JSON.
    nonisolated static func stripToolMarkers(_ text: String) -> String {
        let pattern = #"<tool>\s*\{.*?\}\s*</tool>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
