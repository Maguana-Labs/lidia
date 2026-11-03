import Foundation

struct StructuredSummary: Codable, Sendable {
    var title: String
    var sections: [SummarySection]
    var decisions: [String]
    var actionItems: [SummaryActionItem]

    struct SummarySection: Codable, Sendable, Identifiable {
        var id: String { heading }
        var heading: String
        var bullets: [SummaryBullet]
    }

    struct SummaryBullet: Codable, Sendable, Identifiable {
        let id: UUID
        var text: String
        var sourceQuote: String?
        /// True when this bullet is a point the user typed in their own notes
        /// (kept verbatim). AI-written detail bullets that follow it are `false`.
        /// Decodes as `false` when absent (LLM output and summaries saved before this field).
        var fromUserNotes: Bool

        init(text: String, sourceQuote: String? = nil, fromUserNotes: Bool = false) {
            self.id = UUID()
            self.text = text
            self.sourceQuote = sourceQuote
            self.fromUserNotes = fromUserNotes
        }

        enum CodingKeys: String, CodingKey {
            case text
            case sourceQuote = "source_quote"
            case fromUserNotes = "from_user_notes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.text = try container.decode(String.self, forKey: .text)
            self.sourceQuote = try container.decodeIfPresent(String.self, forKey: .sourceQuote)
            self.fromUserNotes = (try? container.decodeIfPresent(Bool.self, forKey: .fromUserNotes)) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(sourceQuote, forKey: .sourceQuote)
            try container.encode(fromUserNotes, forKey: .fromUserNotes)
        }
    }

    struct SummaryActionItem: Codable, Sendable {
        var title: String
        var assignee: String?
        var deadline: String?
        var sourceQuote: String?
        /// True when the action item came from the user's own notes. Decodes as `false` when absent.
        var fromUserNotes: Bool

        init(title: String, assignee: String? = nil, deadline: String? = nil, sourceQuote: String? = nil, fromUserNotes: Bool = false) {
            self.title = title
            self.assignee = assignee
            self.deadline = deadline
            self.sourceQuote = sourceQuote
            self.fromUserNotes = fromUserNotes
        }

        enum CodingKeys: String, CodingKey {
            case title, assignee, deadline
            case sourceQuote = "source_quote"
            case fromUserNotes = "from_user_notes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try container.decode(String.self, forKey: .title)
            self.assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
            self.deadline = try container.decodeIfPresent(String.self, forKey: .deadline)
            self.sourceQuote = try container.decodeIfPresent(String.self, forKey: .sourceQuote)
            self.fromUserNotes = (try? container.decodeIfPresent(Bool.self, forKey: .fromUserNotes)) ?? false
        }
    }

    /// Convert to flat markdown for backward compatibility.
    var markdownSummary: String {
        var lines: [String] = []
        for section in sections {
            lines.append("### \(section.heading)")
            // AI detail that follows a user-notes point is nested under it.
            var underUserPoint = false
            for bullet in section.bullets {
                if bullet.fromUserNotes {
                    underUserPoint = true
                    lines.append("- \(bullet.text)")
                } else {
                    lines.append(underUserPoint ? "  - \(bullet.text)" : "- \(bullet.text)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
