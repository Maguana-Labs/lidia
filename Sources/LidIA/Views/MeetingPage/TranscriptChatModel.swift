import Foundation

/// One chat bubble in the transcript: a speaker's line with its start time.
struct TranscriptBubble: Identifiable, Equatable, Sendable {
    let id: Int
    let start: TimeInterval?
    var text: String
    /// Shown above the bubble; "You" for the user, nil when unknown.
    let speaker: String?
    let isLocal: Bool
}

/// Builds chat-style transcript bubbles from word-level segments or from
/// plain transcript text ("[0:12] System audio (Leo): Hello").
enum TranscriptChatModel {
    /// One bubble per segment, so playback and search keep segment IDs.
    static func bubbles(from segments: [TranscriptSegment], localName: String) -> [TranscriptBubble] {
        let hasSpeakers = TranscriptSegmenter.hasSpeakerInfo(segments)
        return segments.map { segment in
            let label = hasSpeakers ? segment.speakerLabel(localName: localName) : nil
            return TranscriptBubble(
                id: segment.id,
                start: segment.start,
                text: segment.text,
                speaker: segment.isLocal && hasSpeakers ? "You" : label,
                isLocal: hasSpeakers && segment.isLocal
            )
        }
    }

    /// Parses timestamped, speaker-labelled lines. Consecutive lines from the
    /// same speaker merge into one bubble (up to `mergeLimit` characters).
    /// Text without that shape comes back as paragraphs with no speaker.
    static func bubbles(fromText text: String, localNames: Set<String> = [], mergeLimit: Int = 600) -> [TranscriptBubble] {
        let locals = Set(["microphone", "mic", "me", "you"]).union(localNames.map { $0.lowercased() })
        var result: [TranscriptBubble] = []
        var sawStructuredLine = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let parsed = parseLine(line) {
                sawStructuredLine = true
                let (speaker, isLocal) = speakerName(parsed.speaker, locals: locals)
                if var last = result.last, last.speaker == speaker, last.isLocal == isLocal,
                   last.text.count + parsed.text.count < mergeLimit {
                    last.text += " " + parsed.text
                    result[result.count - 1] = last
                } else {
                    result.append(TranscriptBubble(
                        id: result.count,
                        start: parsed.start,
                        text: parsed.text,
                        speaker: speaker,
                        isLocal: isLocal
                    ))
                }
            } else if sawStructuredLine, var last = result.last {
                // A wrapped continuation of the previous line.
                last.text += " " + line
                result[result.count - 1] = last
            } else {
                result.append(TranscriptBubble(id: result.count, start: nil, text: line, speaker: nil, isLocal: false))
            }
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    struct ParsedLine: Equatable {
        let start: TimeInterval?
        let speaker: String
        let text: String
    }

    /// "[1:02] Speaker: text", "[01:02:03] Speaker: text" or "Speaker: text".
    static func parseLine(_ line: String) -> ParsedLine? {
        if let match = line.wholeMatch(of: /\[(\d{1,2}(?::\d{2}){1,2})\]\s*([^:\[\]]{1,80}?):\s*(.*)/) {
            return ParsedLine(start: seconds(String(match.1)), speaker: String(match.2), text: String(match.3))
        }
        if let match = line.wholeMatch(of: /([A-Z][^:\[\]]{0,40}?):\s+(.+)/),
           String(match.1).split(separator: " ").count <= 5 {
            return ParsedLine(start: nil, speaker: String(match.1), text: String(match.2))
        }
        return nil
    }

    /// "1:02" → 62, "1:02:03" → 3723.
    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }

    /// "System audio (Leo)" → ("Leo", false); "Microphone" → ("You", true).
    static func speakerName(_ raw: String, locals: Set<String>) -> (String, Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if locals.contains(trimmed.lowercased()) { return ("You", true) }
        if let match = trimmed.wholeMatch(of: /(?i)system audio\s*\((.+)\)/) {
            let name = String(match.1).trimmingCharacters(in: .whitespaces)
            if locals.contains(name.lowercased()) { return ("You", true) }
            return (name, false)
        }
        if trimmed.lowercased() == "system audio" || trimmed.lowercased() == "them" { return ("Them", false) }
        return (trimmed, false)
    }

    /// Indices of bubbles containing `query` (case/diacritic-insensitive).
    static func matchingIndices(in bubbles: [TranscriptBubble], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return bubbles.indices.filter { bubbles[$0].text.localizedStandardContains(needle) }
    }
}
