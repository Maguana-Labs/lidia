import Foundation

/// A meeting as Ask sees it: plain values, so retrieval is testable without SwiftData.
public struct MeetingDocument: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var summary: String
    public var notes: String
    public var transcript: String
    public var openActionItems: [String]
    public var attendees: [String]

    public init(
        id: UUID, title: String, date: Date, summary: String = "", notes: String = "",
        transcript: String = "", openActionItems: [String] = [], attendees: [String] = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.summary = summary
        self.notes = notes
        self.transcript = transcript
        self.openActionItems = openActionItems
        self.attendees = attendees
    }
}

/// A meeting an answer drew on, numbered as cited in the answer ("[2]").
public struct AskSource: Sendable, Hashable, Identifiable {
    public var id: UUID { meetingID }
    public var label: Int
    public var meetingID: UUID
    public var title: String
    public var date: Date
}

/// Picks the meetings relevant to a question. Keyword overlap with field
/// weights plus a recency nudge; no embeddings yet (see the Mac's roadmap).
public enum MeetingRetrieval {
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "what", "who", "when", "where", "which", "did", "does", "about",
        "from", "that", "this", "have", "has", "had", "was", "were", "are", "you", "your", "our",
        "any", "all", "how", "why", "can", "could", "should", "would", "tell", "give", "show",
        "meeting", "meetings", "said", "say", "into", "there", "their", "them", "they", "will",
        "que", "qué", "con", "por", "para", "los", "las", "una", "del", "sobre", "cuál", "quién",
    ]

    public static func terms(in query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// Date window implied by the question ("today", "this week", "last week").
    public static func window(for query: String, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        let q = query.lowercased()
        let startOfToday = calendar.startOfDay(for: now)
        if q.contains("today") || q.contains("hoy") {
            return DateInterval(start: startOfToday, end: now.addingTimeInterval(86_400))
        }
        if q.contains("yesterday") || q.contains("ayer") {
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return DateInterval(start: start, end: startOfToday)
        }
        if q.contains("last week") || q.contains("semana pasada") {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
            let start = calendar.date(byAdding: .day, value: -7, to: thisWeek)!
            return DateInterval(start: start, end: thisWeek)
        }
        if q.contains("this week") || q.contains("esta semana") {
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
            return DateInterval(start: start, end: now.addingTimeInterval(86_400))
        }
        return nil
    }

    public static func rank(query: String, documents: [MeetingDocument], limit: Int = 4, now: Date = .now) -> [MeetingDocument] {
        let terms = terms(in: query)
        var pool = documents
        if let window = window(for: query, now: now) {
            let inWindow = documents.filter { window.contains($0.date) }
            if !inWindow.isEmpty { pool = inWindow }
        }
        let scored = pool.map { doc -> (MeetingDocument, Double) in
            var score = 0.0
            for term in terms {
                score += 4 * occurrences(term, in: doc.title, cap: 2)
                score += 3 * occurrences(term, in: doc.attendees.joined(separator: " "), cap: 2)
                score += 3 * occurrences(term, in: doc.openActionItems.joined(separator: " "), cap: 3)
                score += 2 * occurrences(term, in: doc.summary, cap: 4)
                score += 2 * occurrences(term, in: doc.notes, cap: 3)
                score += 1 * occurrences(term, in: doc.transcript, cap: 5)
            }
            let days = max(0, now.timeIntervalSince(doc.date) / 86_400)
            score += 1.5 / (1 + days / 14)
            return (doc, score)
        }
        let hasMatches = terms.isEmpty || scored.contains { $0.1 > 1.5 }
        let ordered = hasMatches
            ? scored.sorted { $0.1 > $1.1 }
            : scored.sorted { $0.0.date > $1.0.date }
        return ordered.prefix(limit).map(\.0)
    }

    static func occurrences(_ term: String, in text: String, cap: Int) -> Double {
        guard !text.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while count < cap, let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return Double(count)
    }

    /// Numbered excerpts that fit `tokenBudget`, and the sources they came from.
    public static func context(for documents: [MeetingDocument], tokenBudget: Int) -> (text: String, sources: [AskSource]) {
        guard !documents.isEmpty else { return ("", []) }
        // ~2.5 characters per token: under the 3 the estimate assumes, for margin.
        let perDocChars = max(300, tokenBudget * 5 / 2 / documents.count)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var blocks: [String] = []
        var sources: [AskSource] = []
        for (index, doc) in documents.enumerated() {
            let label = index + 1
            var body = ""
            let primary = !doc.summary.isEmpty ? doc.summary : doc.transcript
            body += String(primary.prefix(perDocChars))
            if !doc.notes.isEmpty, body.count < perDocChars {
                body += "\nMy notes: " + String(doc.notes.prefix(perDocChars - body.count))
            }
            if !doc.openActionItems.isEmpty {
                body += "\nOpen action items: " + doc.openActionItems.prefix(6).joined(separator: "; ")
            }
            let people = doc.attendees.isEmpty ? "" : " — with \(doc.attendees.prefix(6).joined(separator: ", "))"
            blocks.append("[\(label)] \(doc.title) (\(formatter.string(from: doc.date)))\(people)\n\(body)")
            sources.append(AskSource(label: label, meetingID: doc.id, title: doc.title, date: doc.date))
        }
        return (blocks.joined(separator: "\n\n"), sources)
    }
}

/// Answers questions about meetings with any `TextGenerator`, citing sources.
public struct AskEngine: Sendable {
    public static let answerTokens = 700

    public let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    public struct Turn: Sendable, Hashable {
        public var isUser: Bool
        public var text: String
        public init(isUser: Bool, text: String) {
            self.isUser = isUser
            self.text = text
        }
    }

    /// Picks sources and starts streaming the answer.
    public func answer(
        question: String,
        history: [Turn] = [],
        documents: [MeetingDocument],
        userName: String? = nil,
        scope: UUID? = nil
    ) async throws -> (sources: [AskSource], stream: AsyncThrowingStream<String, Error>) {
        let instructions = MeetingPrompts.askInstructions(userName: userName)
        let recentHistory = history.suffix(4).map { ($0.isUser ? "User: " : "Assistant: ") + String($0.text.prefix(400)) }
        let historyBlock = recentHistory.isEmpty ? "" : "Conversation so far:\n" + recentHistory.joined(separator: "\n") + "\n\n"
        let fixed = try await generator.countTokens(instructions + historyBlock + question)
        let budget = max(400, generator.contextTokens - Self.answerTokens - fixed - 96)

        let candidates: [MeetingDocument]
        if let scope, let doc = documents.first(where: { $0.id == scope }) {
            candidates = [doc]
        } else {
            candidates = MeetingRetrieval.rank(query: question + " " + history.suffix(2).map(\.text).joined(separator: " "), documents: documents)
        }
        let (context, sources) = MeetingRetrieval.context(for: candidates, tokenBudget: budget)
        let prompt = "Meeting excerpts:\n\(context)\n\n\(historyBlock)Question: \(question)"
        let stream = generator.stream(instructions: instructions, prompt: prompt, maxTokens: Self.answerTokens, temperature: 0.3)
        return (sources, stream)
    }
}
