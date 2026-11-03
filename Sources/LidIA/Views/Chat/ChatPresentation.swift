import Foundation

// Pure presentation logic for the chat / Ask surfaces: model labels, sources,
// citations, mentions, slash commands, starters and step chips. No SwiftUI,
// so every piece is unit-tested (ChatPresentationTests).

// MARK: - Model label

/// "Qwen 3.5 4B · On this Mac" or "Claude Sonnet 4.5 · Anthropic". Never a raw
/// repository ID.
enum ChatModelLabel {
    /// A readable name for a model ID or label ("mlx-community/gemma-3-4b-it-4bit"
    /// → "Gemma 3 4B"). Catalog names win; labels that are already readable pass.
    static func pretty(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Automatic" }
        if let entry = ModelCatalog.entry(for: trimmed) { return entry.displayName }
        // Already a display name ("Qwen 3.5 4B", "Apple Intelligence (on-device)").
        if trimmed.contains(" "), !trimmed.contains("/") {
            return trimmed.replacingOccurrences(of: " (on-device)", with: "")
        }

        var name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        // Ollama tags: "qwen3:4b" → "qwen3-4b"; ":latest" goes.
        name = name.replacingOccurrences(of: ":latest", with: "").replacingOccurrences(of: ":", with: "-")
        var parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let noise: Set<String> = [
            "4bit", "8bit", "3bit", "6bit", "bf16", "fp16", "f16", "mlx", "gguf", "instruct", "it", "chat",
            "q4", "q8", "q4_k_m", "q5_k_m", "k", "m", "dwq", "awq", "hf", "optimized", "preview",
        ]
        parts.removeAll { part in
            let lower = part.lowercased()
            return noise.contains(lower) || lower.hasPrefix("q4") || lower.hasPrefix("q8")
                || (lower.count == 8 && lower.allSatisfy(\.isNumber)) // date stamps
        }
        guard !parts.isEmpty else { return trimmed }

        // "claude sonnet 4 5" → "Claude Sonnet 4.5"; "qwen3" → "Qwen 3".
        var words: [String] = []
        for part in parts {
            let lower = part.lowercased()
            if let previous = words.last, previous.allSatisfy(\.isNumber), lower.count == 1, lower.allSatisfy(\.isNumber) {
                words[words.count - 1] = previous + "." + lower
                continue
            }
            if words.last == "GPT", lower.first?.isNumber == true {
                words[words.count - 1] = "GPT-" + lower
                continue
            }
            words.append(prettyWord(lower))
        }
        return words.joined(separator: " ")
    }

    private static let brands: [String: String] = [
        "qwen": "Qwen", "gemma": "Gemma", "llama": "Llama", "mistral": "Mistral", "phi": "Phi",
        "deepseek": "DeepSeek", "gpt": "GPT", "claude": "Claude", "lfm": "LFM", "lfm2": "LFM 2",
        "sonnet": "Sonnet", "opus": "Opus", "haiku": "Haiku", "mini": "mini", "nano": "nano",
        "granite": "Granite", "smollm": "SmolLM", "olmo": "OLMo", "grok": "Grok", "kimi": "Kimi",
        "nemotron": "Nemotron", "gemini": "Gemini", "codex": "Codex", "coder": "Coder",
    ]

    private static func prettyWord(_ lower: String) -> String {
        if let brand = brands[lower] { return brand }
        // "4b", "0.6b", "e4b", "30b" → sizes.
        if lower.wholeMatch(of: /e?\d+(\.\d+)?[bm]/) != nil { return lower.uppercased() }
        if lower.wholeMatch(of: /a\d+(\.\d+)?b/) != nil { return lower.uppercased() }
        // "qwen3" / "gemma3n" → "Qwen 3" / "Gemma 3n".
        if let match = lower.wholeMatch(of: /([a-z]+)(\d+(?:\.\d+)?[a-z]?)/), let brand = brands[String(match.1)] {
            return brand + (brand == "GPT" ? "-" : " ") + String(match.2)
        }
        if lower.first?.isNumber == true { return lower }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// Where it ran, short: "On this Mac", "Your server", or the provider.
    static func place(locality: DataLocality, providerName: String) -> String {
        switch locality {
        case .onDevice: "On this Mac"
        case .localNetwork: "Your server"
        case .cloud: providerName.isEmpty ? "Cloud" : providerName
        }
    }

    static func line(model: String, locality: DataLocality, providerName: String) -> String {
        "\(pretty(model)) · \(place(locality: locality, providerName: providerName))"
    }

    /// A stored label ("mlx-community/x · On this Mac", "Anthropic: claude-… ·
    /// Cloud provider, your key") made presentable.
    static func line(stored: String) -> String {
        var text = stored
        var provider: String?
        if let colon = text.range(of: ": "), !text[..<colon.lowerBound].contains("/") {
            provider = String(text[..<colon.lowerBound])
            text = String(text[colon.upperBound...])
        }
        let parts = text.components(separatedBy: " · ")
        let model = pretty(parts.first ?? text)
        guard parts.count > 1 else { return model }
        let place = parts.dropFirst().joined(separator: " · ")
        let locality = DataLocality.allCases.first { $0.label == place }
        switch locality {
        case .onDevice: return "\(model) · On this Mac"
        case .localNetwork: return "\(model) · Your server"
        case .cloud: return "\(model) · \(provider ?? "Cloud")"
        case nil: return "\(model) · \(place)"
        }
    }
}

// MARK: - Sources

enum ChatSources {
    /// One card per meeting: by ID, then recordings of the same meeting on the
    /// same day (same title) fold together, keeping the first excerpt found.
    static func dedupe(_ refs: [AgentMeetingRef], calendar: Calendar = .current) -> [AgentMeetingRef] {
        var result: [AgentMeetingRef] = []
        for ref in refs {
            if let index = result.firstIndex(where: { existing in
                existing.id == ref.id
                    || (fold(existing.title) == fold(ref.title) && calendar.isDate(existing.date, inSameDayAs: ref.date))
            }) {
                if (result[index].excerpt ?? "").isEmpty, let excerpt = ref.excerpt, !excerpt.isEmpty {
                    result[index].excerpt = excerpt
                }
                continue
            }
            result.append(ref)
        }
        return result
    }

    /// The first transcript timestamp in an excerpt ("[12:34] Leo: …").
    static func timestamp(in excerpt: String?) -> TimeInterval? {
        guard let excerpt, let match = excerpt.firstMatch(of: /\[(\d{1,2}:\d{2}(?::\d{2})?)\]/) else { return nil }
        return TranscriptChatModel.seconds(String(match.1))
    }

    /// An excerpt for a card: one line, no ellipses at the ends.
    static func cleanExcerpt(_ excerpt: String?) -> String? {
        guard var text = excerpt?.replacingOccurrences(of: "\n", with: " ") else { return nil }
        text = text.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("…") || text.hasPrefix("...") { text = String(text.drop { $0 == "…" || $0 == "." || $0 == " " }) }
        while text.hasSuffix("…") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The 8-character ID tools show the model (same as `LidIATools.shortID`).
    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tool-style dates ("2026-10-28") in display text become "28 Oct".
    static func prettifyDates(_ text: String, now: Date = .now) -> String {
        text.replacing(/\b(\d{4}-\d{2}-\d{2})\b/) { match in
            AgentDates.parse(String(match.1)).map { dayMonth($0, now: now) } ?? String(match.0)
        }
    }

    /// "28 Oct" (with the year when it isn't this year), never relative, for use mid-sentence.
    static func dayMonth(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// "Today", "Yesterday", "Tue", "28 Oct", or "28 Oct 2025".
    static func shortDate(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }
}

// MARK: - Citations

/// Inline numbered citations. Sources are numbered by their position in the
/// sources row. The answer's own markers ("[1]", "[^2]", a meeting's short ID)
/// become links, and a source the answer names (by title, or by date when the
/// title repeats) gets one at the end of that sentence.
enum ChatCitations {
    static let scheme = "lidia-cite"

    struct Result: Equatable {
        /// Markdown with citations as `[n](lidia-cite://n)` links.
        var markdown: String
        /// Source numbers (1-based) in order of first appearance.
        var cited: [Int]
    }

    static func url(_ number: Int) -> URL { URL(string: "\(scheme)://\(number)")! }

    static func number(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.host() ?? "")
    }

    static func link(_ text: String, sources: [AgentMeetingRef]) -> Result {
        guard !sources.isEmpty, !text.isEmpty else { return Result(markdown: text, cited: []) }
        var cited: [Int] = []
        func note(_ n: Int) { if !cited.contains(n) { cited.append(n) } }
        func marker(_ n: Int) -> String { "[\(n)](\(scheme)://\(n))" }

        var lines = text.components(separatedBy: "\n")
        var inCode = false
        var codeLines = Set<Int>()
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); codeLines.insert(index); continue }
            if inCode { codeLines.insert(index) }
        }

        // 1. The answer's own markers.
        for index in lines.indices where !codeLines.contains(index) {
            var line = lines[index]
            // [1], [1, 2], [^1] — not link text ("[1](…)").
            line = line.replacing(/\[\^?(\d{1,2}(?:\s*,\s*\d{1,2})*)\](?!\()/) { match in
                let numbers = String(match.1).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let valid = numbers.filter { (1...sources.count).contains($0) }
                guard !valid.isEmpty else { return String(match.0) }
                valid.forEach(note)
                return valid.map(marker).joined()
            }
            // [a1b2c3d4]: a meeting's short ID. Not a source: drop the raw ID.
            line = line.replacing(/\s?\[([0-9a-fA-F]{8})\](?!\()/) { match in
                let id = String(match.1).lowercased()
                if let n = sources.firstIndex(where: { ChatSources.shortID($0.id) == id }).map({ $0 + 1 }) {
                    note(n)
                    return " " + marker(n)
                }
                return ""
            }
            lines[index] = line
        }

        // 2. Sources the answer names.
        let titleCounts = Dictionary(sources.map { (ChatSources.fold($0.title), 1) }, uniquingKeysWith: +)
        for (offset, source) in sources.enumerated() {
            let n = offset + 1
            guard !cited.contains(n) else { continue }
            let title = source.title.trimmingCharacters(in: .whitespaces)
            let shared = titleCounts[ChatSources.fold(title), default: 0] > 1
            for index in lines.indices where !codeLines.contains(index) {
                let line = lines[index]
                // A citation would add a column to a table row.
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { continue }
                var anchor: Range<String.Index>?
                if title.count >= 4, let range = wordRange(of: title, in: line), !shared || mentionsDate(source.date, in: line) {
                    anchor = range
                } else if let range = dateRange(source.date, in: line), shared || title.count < 4 || !line.localizedCaseInsensitiveContains(title) {
                    // A date alone cites only when no other source shares it.
                    let sameDay = sources.filter { Calendar.current.isDate($0.date, inSameDayAs: source.date) }.count
                    if sameDay == 1 { anchor = range }
                }
                guard let anchor else { continue }
                let insertAt = sentenceEnd(in: line, after: anchor.upperBound)
                var updated = line
                let before = String(updated[..<insertAt])
                let followsCitation = before.firstMatch(of: /\]\(lidia-cite:\/\/\d+\)$/) != nil
                let glue = followsCitation || before.last == " " || before.isEmpty ? "" : " "
                updated.insert(contentsOf: glue + marker(n), at: insertAt)
                lines[index] = updated
                note(n)
                break
            }
        }
        let markdown = lines.joined(separator: "\n")
        // Report numbers in reading order.
        var ordered: [Int] = []
        for match in markdown.matches(of: /\]\(lidia-cite:\/\/(\d+)\)/) {
            if let n = Int(match.1), !ordered.contains(n) { ordered.append(n) }
        }
        return Result(markdown: markdown, cited: ordered)
    }

    /// `needle` in `line` at word boundaries, ignoring case and accents.
    static func wordRange(of needle: String, in line: String) -> Range<String.Index>? {
        var searchStart = line.startIndex
        while let range = line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<line.endIndex) {
            let beforeOK = range.lowerBound == line.startIndex || !line[line.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == line.endIndex || !line[range.upperBound].isLetter
            if beforeOK && afterOK { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func dayString(_ date: Date) -> String { AgentDates.day(date) }

    /// The date as "2026-10-28", "28 Oct", "Oct 28" or "October 28".
    static func dateRange(_ date: Date, in line: String) -> Range<String.Index>? {
        if let range = line.range(of: dayString(date)) { return range }
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)
        let symbols = DateFormatter()
        symbols.locale = Locale(identifier: "en_US_POSIX")
        let names = [symbols.shortMonthSymbols[month - 1], symbols.monthSymbols[month - 1]]
        for name in names {
            for pattern in ["\(day) \(name)", "\(name) \(day)"] {
                if let range = wordRange(of: pattern, in: line) {
                    // "Oct 2" must not match inside "Oct 28".
                    if range.upperBound < line.endIndex, line[range.upperBound].isNumber { continue }
                    return range
                }
            }
        }
        return nil
    }

    static func mentionsDate(_ date: Date, in line: String) -> Bool { dateRange(date, in: line) != nil }

    /// Where a citation goes: before the sentence's closing punctuation, or at
    /// the end of the line.
    static func sentenceEnd(in line: String, after start: String.Index) -> String.Index {
        var index = start
        // Skip a date or parenthetical right after the title.
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            let atBoundary = next == line.endIndex || line[next] == " "
            if (character == "." || character == ";" || character == "?" || character == "!") && atBoundary {
                // Keep inline markup closed ("**Title**." → after the "**").
                return index
            }
            index = next
        }
        // Trailing markup ("**") stays before the citation.
        return line.endIndex
    }
}

// MARK: - Mentions

/// Something the user @-mentioned to scope a question.
struct ChatMention: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case meeting, person, project

        var icon: String {
            switch self {
            case .meeting: "calendar"
            case .person: "person.crop.circle"
            case .project: "folder"
            }
        }
    }

    var kind: Kind
    /// A meeting's UUID string, or the person's / project's name.
    var key: String
    var label: String
    var date: Date?

    var id: String { "\(kind.rawValue):\(key)" }

    var meetingID: UUID? { kind == .meeting ? UUID(uuidString: key) : nil }
}

enum ChatMentions {
    static let scheme = "lidia-mention"

    /// The "@query" or "/query" being typed at the end of `text`.
    struct Trigger: Equatable {
        var symbol: Character
        var query: String
        /// Where the trigger starts (the "@" or "/").
        var start: String.Index
    }

    static func activeTrigger(in text: String) -> Trigger? {
        guard let last = text.lastIndex(where: { $0 == "@" || $0 == "/" }) else { return nil }
        let symbol = text[last]
        let before = last == text.startIndex ? nil : text[text.index(before: last)]
        guard before == nil || before!.isWhitespace else { return nil }
        // Slash commands only start a message.
        if symbol == "/", !text[..<last].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let query = String(text[text.index(after: last)...])
        guard !query.contains(where: \.isNewline), query.count <= 40 else { return nil }
        // "@North wind": a space ends a mention query unless it keeps matching.
        if symbol == "/", query.contains(" ") { return nil }
        if query.hasPrefix(" ") { return nil }
        return Trigger(symbol: symbol, query: query, start: last)
    }

    /// Replaces the trigger with "@Label " (mentions) or "/command " (commands).
    static func complete(_ text: String, trigger: Trigger, with replacement: String) -> String {
        String(text[..<trigger.start]) + String(trigger.symbol) + replacement + " "
    }

    /// The text to store: each "@Label" of a picked mention becomes a link
    /// that carries what it is, so the thread keeps the scope.
    static func encode(_ text: String, mentions: [ChatMention]) -> String {
        var result = text
        // Longest first, so "@Northwind x Harborcloud" wins over "@Northwind".
        for mention in mentions.sorted(by: { $0.label.count > $1.label.count }) {
            let token = "@" + mention.label
            guard let range = result.range(of: token) else { continue }
            let link = "[@\(escape(mention.label))](\(url(for: mention).absoluteString))"
            result.replaceSubrange(range, with: link)
        }
        return result
    }

    static func url(for mention: ChatMention) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = mention.kind.rawValue
        components.path = "/" + mention.key
        if let date = mention.date { components.queryItems = [URLQueryItem(name: "date", value: AgentDates.day(date))] }
        return components.url!
    }

    static func mention(from url: URL, label: String) -> ChatMention? {
        guard url.scheme == scheme, let host = url.host(), let kind = ChatMention.Kind(rawValue: host) else { return nil }
        let key = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !key.isEmpty else { return nil }
        let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "date" }?.value.flatMap(AgentDates.parse)
        return ChatMention(kind: kind, key: key, label: label, date: date)
    }

    /// Plain text (mentions as their label) and the mentions in it.
    static func decode(_ text: String) -> (plain: String, mentions: [ChatMention]) {
        var mentions: [ChatMention] = []
        let plain = text.replacing(/\[@((?:\\.|[^\]\\])+)\]\((lidia-mention:[^)\s]+)\)/) { match in
            let label = unescape(String(match.1))
            if let url = URL(string: String(match.2)), let mention = mention(from: url, label: label), !mentions.contains(mention) {
                mentions.append(mention)
            }
            return label
        }
        return (plain, mentions)
    }

    /// What the agent is told about the mentions (all visible in the transcript).
    static func scopeNote(_ mentions: [ChatMention]) -> String? {
        guard !mentions.isEmpty else { return nil }
        let parts = mentions.map { mention -> String in
            switch mention.kind {
            case .meeting:
                let id = mention.meetingID.map { "[\(ChatSources.shortID($0))] " } ?? ""
                let date = mention.date.map { ", \(AgentDates.day($0))" } ?? ""
                return "meeting \(id)“\(mention.label)”\(date)"
            case .person: return "person \(mention.label)"
            case .project: return "project \(mention.label)"
            }
        }
        return "(Scope: " + parts.joined(separator: "; ") + ". Use only these unless I say otherwise.)"
    }

    private static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
    }

    private static func unescape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\]", with: "]").replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Candidates for "@query", meetings first, best matches first.
    static func filter(_ candidates: [ChatMention], query: String, limit: Int = 8) -> [ChatMention] {
        let needle = ChatSources.fold(query)
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        let scored = candidates.compactMap { candidate -> (ChatMention, Int)? in
            let label = ChatSources.fold(candidate.label)
            if label.hasPrefix(needle) { return (candidate, 0) }
            if label.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return (candidate, 1) }
            if label.contains(needle) { return (candidate, 2) }
            return nil
        }
        return scored.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .prefix(limit)
            .map(\.element.0)
    }
}

// MARK: - Slash commands

enum ChatCommand: String, CaseIterable, Identifiable, Sendable {
    case summarize
    case followUp = "follow-up"
    case actions
    case prep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summarize: "Summarize"
        case .followUp: "Follow-up email"
        case .actions: "Action items"
        case .prep: "Prep for a meeting"
        }
    }

    var detail: String {
        switch self {
        case .summarize: "Decisions, open questions and next steps"
        case .followUp: "Draft a recap email with owners"
        case .actions: "Open items with owner and due date"
        case .prep: "What happened last time and what to ask"
        }
    }

    var icon: String {
        switch self {
        case .summarize: "text.badge.star"
        case .followUp: "envelope"
        case .actions: "checklist"
        case .prep: "calendar.badge.clock"
        }
    }

    /// The prompt the agent gets. `argument` is what follows the command.
    func prompt(argument: String) -> String {
        let topic = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .summarize:
            return "Summarize \(topic.isEmpty ? "my most recent meeting" : topic): the decisions, open questions and next steps."
        case .followUp:
            return "Draft a follow-up email for \(topic.isEmpty ? "my most recent meeting" : topic): thank them, recap what we agreed, and list next steps with owners."
        case .actions:
            return "List my open action items\(topic.isEmpty ? "" : " for \(topic)") with owner and due date, overdue first."
        case .prep:
            return "Prep me for \(topic.isEmpty ? "my next meeting" : topic): what we discussed last time, open items, and questions to ask."
        }
    }

    /// "/summarize Northwind" → (.summarize, "Northwind"). Unknown commands → nil.
    static func parse(_ text: String) -> (command: ChatCommand, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }.lowercased()
        let aliases: [String: ChatCommand] = ["followup": .followUp, "follow": .followUp, "action": .actions, "todo": .actions, "summary": .summarize]
        guard let command = ChatCommand(rawValue: name) ?? aliases[name] else { return nil }
        let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, argument)
    }

    static func matching(_ query: String) -> [ChatCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return allCases }
        return allCases.filter { $0.rawValue.hasPrefix(needle) || $0.title.lowercased().hasPrefix(needle) }
    }
}

// MARK: - Starters

struct ChatStarter: Identifiable, Equatable, Sendable {
    var icon: String
    var title: String
    var subtitle: String?
    var prompt: String
    var id: String { title }
}

enum ChatStarters {
    struct MeetingInfo: Equatable, Sendable {
        var title: String
        var date: Date
    }

    /// Starter prompts from the user's own data: the next meeting, the latest
    /// one, and open action items. Falls back to generic questions.
    static func make(
        next: MeetingInfo?,
        latest: MeetingInfo?,
        openItems: Int,
        overdueItems: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ChatStarter] {
        var result: [ChatStarter] = []
        if let next {
            let when = ChatSources.shortDate(next.date, now: now, calendar: calendar)
            let time = next.date.formatted(date: .omitted, time: .shortened)
            result.append(ChatStarter(
                icon: "calendar.badge.clock",
                title: "Prep for “\(short(next.title))”",
                subtitle: "\(when) at \(time)",
                prompt: "Prep me for “\(next.title)” on \(AgentDates.day(next.date)): what we discussed last time, open items, and questions to ask."
            ))
        }
        if let latest {
            result.append(ChatStarter(
                icon: "text.badge.star",
                title: "Recap “\(short(latest.title))”",
                subtitle: ChatSources.shortDate(latest.date, now: now, calendar: calendar),
                prompt: "Summarize “\(latest.title)” from \(AgentDates.day(latest.date)): decisions, open questions and next steps."
            ))
        }
        if openItems > 0 {
            result.append(ChatStarter(
                icon: "checklist",
                title: "Review \(openItems) open action item\(openItems == 1 ? "" : "s")",
                subtitle: overdueItems > 0 ? "\(overdueItems) overdue" : "Owners and due dates",
                prompt: "List my open action items with owner and due date, overdue first."
            ))
        }
        result.append(ChatStarter(
            icon: "sparkle.magnifyingglass",
            title: "What did I commit to this week?",
            subtitle: "Across all meetings",
            prompt: "What did I commit to in this week's meetings? Group by meeting."
        ))
        if result.count < 4 {
            result.append(ChatStarter(
                icon: "tablecells",
                title: "Compare my last two meetings with the same people",
                subtitle: "As a table",
                prompt: "Compare my last two meetings with the same people in a table: decisions, open questions, next steps."
            ))
        }
        return Array(result.prefix(4))
    }

    /// Starters on a meeting's Ask: decisions, its action items, what a
    /// participant committed to, a follow-up.
    static func forMeeting(people: [String], openItems: Int) -> [ChatStarter] {
        var result = [ChatStarter(
            icon: "lightbulb",
            title: "What did we decide?",
            subtitle: "Decisions and the reasons",
            prompt: "What did we decide in this meeting, and why?"
        )]
        if openItems > 0 {
            result.append(ChatStarter(
                icon: "checklist",
                title: "Review \(openItems) action item\(openItems == 1 ? "" : "s")",
                subtitle: "Owners and due dates",
                prompt: "List this meeting's action items with owner and due date."
            ))
        } else {
            result.append(ChatStarter(
                icon: "checklist",
                title: "What are the next steps?",
                subtitle: "With owners",
                prompt: "What are the next steps from this meeting, with owners and dates?"
            ))
        }
        if let person = people.first(where: { !$0.isEmpty }) {
            let first = person.split(separator: " ").first.map(String.init) ?? person
            result.append(ChatStarter(
                icon: "person.crop.circle",
                title: "What did \(first) commit to?",
                subtitle: person,
                prompt: "What did \(person) commit to in this meeting?"
            ))
        }
        result.append(ChatStarter(
            icon: "envelope",
            title: "Draft a follow-up email",
            subtitle: "Recap and next steps",
            prompt: "Draft a follow-up email for this meeting: thank them, recap what we agreed, and list next steps with owners."
        ))
        return result
    }

    static func short(_ title: String, max: Int = 34) -> String {
        title.count > max ? String(title.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}

// MARK: - Steps

enum ChatStepPresentation {
    static func icon(tool: String) -> String {
        switch tool {
        case "search_meetings": "magnifyingglass"
        case "get_meeting": "doc.text"
        case "list_action_items": "checklist"
        case "list_projects": "folder"
        case "create_action_item": "plus.circle"
        case "update_action_item_status": "arrow.triangle.2.circlepath"
        case "propose_dispatch": "paperplane"
        case "ask_user": "questionmark.bubble"
        default: "wrench.and.screwdriver"
        }
    }

    /// A compact chip: "Searched 6 meetings", "Read · Northwind x Harborcloud · 28 Oct".
    static func chipTitle(tool: String, summary: String, resultCount: Int?, now: Date = .now) -> String {
        switch tool {
        case "search_meetings":
            if let count = resultCount { return "Searched \(count) meeting\(count == 1 ? "" : "s")" }
            return "Searching meetings"
        case "get_meeting":
            if let match = summary.firstMatch(of: /Read “(.+)”, (\d{4}-\d{2}-\d{2})/) {
                let date = AgentDates.parse(String(match.2)).map { ChatSources.shortDate($0, now: now) } ?? String(match.2)
                return "Read · \(ChatStarters.short(String(match.1), max: 30)) · \(date)"
            }
            return "Read a meeting"
        case "list_action_items":
            if let count = resultCount { return "Found \(count) action item\(count == 1 ? "" : "s")" }
            return "Checking action items"
        case "list_projects":
            if let count = resultCount { return "Listed \(count) project\(count == 1 ? "" : "s")" }
            return "Listing projects"
        case "create_action_item": return "Prepared an action item"
        case "update_action_item_status": return "Prepared a status change"
        case "propose_dispatch": return "Drafted a proposal"
        case "ask_user": return "Asked you"
        default: return summary.isEmpty ? tool : summary
        }
    }

    /// The live label: "Searching your meetings", "Reading “Northwind…”", "Writing".
    static func phaseLabel(phase: AgentRun.Phase, runningTool: String?, runningSummary: String?) -> String {
        switch phase {
        case .thinking: return "Thinking"
        case .searching:
            switch runningTool {
            case "search_meetings": return "Searching your meetings"
            case "get_meeting":
                if let summary = runningSummary, let match = summary.firstMatch(of: /“(.+)”/) {
                    return "Reading “\(ChatStarters.short(String(match.1), max: 28))”"
                }
                return "Reading a meeting"
            case "list_action_items": return "Checking action items"
            case "list_projects": return "Looking at projects"
            case "propose_dispatch": return "Drafting a proposal"
            case "create_action_item", "update_action_item_status": return "Preparing a change"
            case "ask_user": return "Preparing a question"
            default: return "Working"
            }
        case .answering: return "Writing"
        case .waitingForApproval: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Couldn't finish"
        case .cancelled: return "Stopped"
        }
    }

    /// "2.4s", "12s", "1m 05s".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 10 { return String(format: "%.1fs", value) }
        if value < 60 { return "\(Int(value.rounded()))s" }
        let total = Int(value.rounded())
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    static func thoughtFor(_ seconds: TimeInterval) -> String {
        let value = max(1, Int(seconds.rounded()))
        return value < 60 ? "Thought for \(value)s" : "Thought for \(value / 60)m \(value % 60)s"
    }
}

// MARK: - Recommendation evidence

/// How well a proposal is grounded, from facts the app knows (not the model's
/// self-assessment): linked to an action item, meetings read, a drafted body.
struct ChatEvidence: Equatable, Sendable {
    /// 1 to 3 bars.
    var level: Int
    var label: String
    var detail: String

    static func of(linkedToItem: Bool, meetingsRead: Int, hasBody: Bool) -> ChatEvidence {
        let level = max(1, (linkedToItem ? 1 : 0) + (meetingsRead > 0 ? 1 : 0) + (hasBody ? 1 : 0))
        let label = switch level {
        case 3: "Well grounded"
        case 2: "Partly grounded"
        default: "Needs review"
        }
        var parts: [String] = []
        if meetingsRead > 0 { parts.append("From \(meetingsRead) meeting\(meetingsRead == 1 ? "" : "s")") }
        parts.append(linkedToItem ? "Linked to an action item" : "Not linked to an action item")
        return ChatEvidence(level: level, label: label, detail: parts.joined(separator: " · "))
    }
}
