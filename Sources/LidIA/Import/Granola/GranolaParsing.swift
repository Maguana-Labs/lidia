import Foundation

// MARK: - Parsed values

/// One person listed on a Granola meeting.
struct GranolaParticipant: Equatable, Sendable {
    var name: String?
    var email: String?
    var company: String?
    var isNoteCreator: Bool

    /// The form `Meeting.calendarAttendees` uses: "Name <email>", or whichever half is known.
    var attendeeString: String? {
        switch (name, email) {
        case let (name?, email?): "\(name) <\(email)>"
        case let (name?, nil): name
        case let (nil, email?): email
        case (nil, nil): nil
        }
    }
}

/// A meeting as `list_meetings` describes it.
struct GranolaMeetingListing: Equatable, Sendable {
    var id: String
    var title: String
    var meetingAt: Date?
    var url: String?
    /// `nil` when the server didn't say.
    var capturedByMe: Bool?
    var participants: [GranolaParticipant]
}

struct GranolaPagination: Equatable, Sendable {
    var hasMore: Bool
    var totalCount: Int?
    var remainingCount: Int?
    var nextCursor: String?
}

struct GranolaListPage: Equatable, Sendable {
    var meetings: [GranolaMeetingListing]
    /// `nil` when the response had no pagination element (a single page).
    var pagination: GranolaPagination?
}

/// A meeting as `get_meetings` describes it.
struct GranolaMeetingDetail: Equatable, Sendable {
    var id: String
    var title: String
    var meetingAt: Date?
    var participants: [GranolaParticipant]
    /// Empty when the user has no private notes or they belong to someone else.
    var privateNotes: String
    /// The `status` attribute of `<private_notes>` ("empty", "not_included"), if any.
    var privateNotesStatus: String?
    var summary: String
    /// `nil` when the response didn't say.
    var transcriptAvailable: Bool?
}

/// One page of `get_meeting_transcript`.
struct GranolaTranscriptPage: Equatable, Sendable {
    var transcript: String?
    var truncated: Bool
    var nextOffset: Int?
    var totalChars: Int?
    var endsMidUtterance: Bool
    var startsMidUtterance: Bool
    /// "transcript_pending", "not_happened_yet", "no_transcript", "transcript_deleted", …
    var unavailableReason: String?
}

/// A tool result that asks the caller to wait before retrying.
struct GranolaRateLimit: Equatable, Sendable {
    var retryAfterSeconds: Double
}

// MARK: - Parser

/// Tolerant readers for the text Granola's MCP tools return.
///
/// The tool results are XML-like text wrapped in prose. These readers look for
/// the elements they need and ignore everything else: unknown attributes and
/// elements, advisory sentences, and attribute order. Attribute values and
/// element text are XML-unescaped.
enum GranolaParser {
    // MARK: list_meetings

    static func parseListMeetings(_ text: String) -> GranolaListPage {
        var meetings: [GranolaMeetingListing] = []
        for element in elements(named: "meeting", in: text) {
            guard let id = element.attributes["id"], !id.isEmpty else { continue }
            meetings.append(GranolaMeetingListing(
                id: id,
                title: element.attributes["title"] ?? "",
                meetingAt: element.attributes["meeting_at"].flatMap(parseDate),
                url: element.attributes["url"],
                capturedByMe: element.attributes["captured_by_me"].flatMap(parseBool),
                participants: element.body.flatMap { firstElement(named: "known_participants", in: $0)?.body }
                    .map(parseParticipants) ?? []
            ))
        }
        let pagination = firstElement(named: "pagination", in: text).map { element in
            GranolaPagination(
                hasMore: element.attributes["has_more"].flatMap(parseBool) ?? false,
                totalCount: element.attributes["total_count"].flatMap { Int($0) },
                remainingCount: element.attributes["remaining_count"].flatMap { Int($0) },
                nextCursor: element.attributes["next_cursor"].flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return GranolaListPage(meetings: meetings, pagination: pagination)
    }

    // MARK: get_meetings

    static func parseGetMeetings(_ text: String) -> [GranolaMeetingDetail] {
        elements(named: "meeting", in: text).compactMap { element in
            guard let id = element.attributes["id"], !id.isEmpty else { return nil }
            let body = element.body ?? ""
            let notes = firstElement(named: "private_notes", in: body)
            let summary = firstElement(named: "summary", in: body)
            let transcript = firstElement(named: "transcript", in: body)
            return GranolaMeetingDetail(
                id: id,
                title: element.attributes["title"] ?? "",
                meetingAt: element.attributes["meeting_at"].flatMap(parseDate),
                participants: firstElement(named: "known_participants", in: body)?.body.map(parseParticipants) ?? [],
                privateNotes: notes?.body.map(cleanBlock) ?? "",
                privateNotesStatus: notes?.attributes["status"],
                summary: summary?.body.map(cleanBlock) ?? "",
                transcriptAvailable: transcript?.attributes["available"].flatMap(parseBool)
            )
        }
    }

    // MARK: get_meeting_transcript

    static func parseTranscript(_ text: String) -> GranolaTranscriptPage? {
        guard let object = jsonObject(in: text) else { return nil }
        let unavailable = object["transcript_unavailable"]
        let reason: String? = {
            if let dict = unavailable as? [String: Any] { return dict["reason"] as? String ?? "unavailable" }
            if let string = unavailable as? String { return string }
            return nil
        }()
        return GranolaTranscriptPage(
            transcript: object["transcript"] as? String,
            truncated: (object["truncated"] as? Bool) ?? false,
            nextOffset: int(object["next_offset"]),
            totalChars: int(object["total_chars"]),
            endsMidUtterance: (object["ends_mid_utterance"] as? Bool) ?? false,
            startsMidUtterance: (object["starts_mid_utterance"] as? Bool) ?? false,
            unavailableReason: reason
        )
    }

    /// Joins transcript pages. A page that ended mid-utterance continues on the
    /// next page without a break; otherwise pages meet at a line break.
    static func appendTranscriptPage(_ page: String, to transcript: inout String, previousEndedMidUtterance: Bool) {
        guard !page.isEmpty else { return }
        if transcript.isEmpty || previousEndedMidUtterance
            || transcript.hasSuffix("\n") || page.hasPrefix("\n") {
            transcript += page
        } else {
            transcript += "\n" + page
        }
    }

    // MARK: Errors

    /// Recognises a rate-limit answer in a tool result's text, JSON or prose.
    static func parseRateLimit(_ text: String) -> GranolaRateLimit? {
        let lowered = text.lowercased()
        guard lowered.contains("rate_limit") || lowered.contains("rate limit") || lowered.contains("too many requests") else {
            return nil
        }
        if let object = jsonObject(in: text) {
            let error = object["error"] as? [String: Any]
            for candidate in [object, error ?? [:]] {
                if let seconds = double(candidate["retry_after_seconds"]) ?? double(candidate["retry_after"]) {
                    return GranolaRateLimit(retryAfterSeconds: seconds)
                }
            }
        }
        if let match = text.firstMatch(of: /retry_after(?:_seconds)?["']?\s*[:=]\s*"?(\d+(?:\.\d+)?)/),
           let seconds = Double(match.1) {
            return GranolaRateLimit(retryAfterSeconds: seconds)
        }
        return GranolaRateLimit(retryAfterSeconds: 10)
    }

    // MARK: Participants

    /// Reads entries such as "Sample Person (note creator) from Example (person@example.com)".
    /// Granola puts several people on one line separated by commas, so entries are
    /// split on newlines and on commas outside parentheses.
    static func parseParticipants(_ text: String) -> [GranolaParticipant] {
        unescape(text)
            .split(whereSeparator: \.isNewline)
            .flatMap(splitEntries)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap(parseParticipant)
    }

    /// Splits "A (a@x.com), B from Co (b@y.com)" into its entries.
    static func splitEntries(_ line: Substring) -> [String] {
        var entries: [String] = []
        var current = ""
        var depth = 0
        for character in line {
            switch character {
            case "(", "<": depth += 1
            case ")", ">": depth = max(0, depth - 1)
            case "," where depth == 0:
                entries.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        entries.append(current)
        return entries
    }

    static func parseParticipant(_ line: String) -> GranolaParticipant? {
        var rest = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespaces))
        guard !rest.isEmpty else { return nil }

        var email: String?
        // Email in the last "(…@…)" or "<…@…>".
        if let match = rest.firstMatch(of: /[(<]\s*([^()<>\s]+@[^()<>\s]+)\s*[)>]\s*$/) {
            email = String(match.1).lowercased()
            rest = String(rest[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else if !rest.contains(" "), rest.contains("@") {
            return GranolaParticipant(name: nil, email: rest.lowercased(), company: nil, isNoteCreator: false)
        }

        let isCreator = rest.range(of: "(note creator)", options: .caseInsensitive) != nil
        rest = rest.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)

        var company: String?
        if let range = rest.range(of: " from ", options: .backwards) {
            company = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<range.lowerBound])
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        if name.isEmpty && email == nil { return nil }
        return GranolaParticipant(
            name: name.isEmpty ? nil : name,
            email: email,
            company: company?.isEmpty == true ? nil : company,
            isNoteCreator: isCreator
        )
    }

    // MARK: - Element scanning

    struct Element: Equatable {
        var attributes: [String: String]
        /// `nil` for a self-closing element.
        var body: String?
    }

    /// Every `<name …>…</name>` or `<name … />` in `text`, in order. Elements
    /// of the same name are not nested in Granola's output, so the first
    /// closing tag ends each one.
    static func elements(named name: String, in text: String) -> [Element] {
        var results: [Element] = []
        var searchStart = text.startIndex
        let open = "<\(name)"
        let close = "</\(name)>"
        while let openRange = text.range(of: open, range: searchStart..<text.endIndex) {
            // The tag name must end here: "<meeting " but not "<meetings_data".
            guard openRange.upperBound < text.endIndex else { break }
            let next = text[openRange.upperBound]
            guard next == " " || next == ">" || next == "/" || next.isNewline || next == "\t" else {
                searchStart = openRange.upperBound
                continue
            }
            guard let tagEnd = tagEnd(in: text, from: openRange.upperBound) else { break }
            let rawAttributes = String(text[openRange.upperBound..<tagEnd])
            let selfClosing = rawAttributes.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            let attributes = parseAttributes(rawAttributes)
            let afterTag = text.index(after: tagEnd)
            if selfClosing {
                results.append(Element(attributes: attributes, body: nil))
                searchStart = afterTag
                continue
            }
            if let closeRange = text.range(of: close, range: afterTag..<text.endIndex) {
                results.append(Element(attributes: attributes, body: String(text[afterTag..<closeRange.lowerBound])))
                searchStart = closeRange.upperBound
            } else {
                // Unclosed: take the rest of the text.
                results.append(Element(attributes: attributes, body: String(text[afterTag...])))
                break
            }
        }
        return results
    }

    static func firstElement(named name: String, in text: String) -> Element? {
        // Cheap path: scan only until the first match.
        elements(named: name, in: text).first
    }

    /// Index of the `>` that ends a start tag, skipping `>` inside quoted values.
    private static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func parseAttributes(_ raw: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in raw.matches(of: /([A-Za-z_][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/) {
            let value = match.2 ?? match.3 ?? ""
            attributes[String(match.1)] = unescape(String(value))
        }
        return attributes
    }

    /// Decodes the five XML entities and numeric character references.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon]
            var decoded: String?
            switch entity {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos": decoded = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
            }
            if let decoded {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    /// Element text without the leading/trailing blank lines the server adds.
    private static func cleanBlock(_ text: String) -> String {
        unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scalars

    static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: nil
        }
    }

    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    /// The first JSON object in `text`, which may have prose around it.
    static func jsonObject(in text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
