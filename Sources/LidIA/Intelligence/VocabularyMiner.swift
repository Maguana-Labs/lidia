import Foundation

/// Learns the user's own vocabulary from their meetings, on this Mac.
///
/// The idea: summaries, titles and attendee lists spell domain terms right
/// ("TAPR", "Pinecrest", "Northwind"), while raw transcripts carry what the
/// speech engine heard ("taper", "north wind"). A term is a candidate when it
/// recurs in the written text; a transcript word is a mishearing of it when
/// it sounds alike (same consonant skeleton, or the same letters split into
/// words) and turns up mostly in the meetings that talk about the term.
enum VocabularyMiner {
    /// One meeting's text.
    struct Document: Sendable {
        var id: UUID
        /// What was written: title, summary, notes, attendee names and companies.
        var written: String
        /// What was heard: the transcript.
        var heard: String
        /// The title, which names what matters most.
        var title: String = ""
    }

    /// A term the user's meetings use, and how the transcript tends to mishear it.
    struct Suggestion: Identifiable, Hashable, Sendable {
        /// The right spelling ("TAPR").
        var term: String
        /// The most common mishearing ("taper"), nil when the transcript gets it right.
        var heardAs: String?
        /// Every mishearing seen, most frequent first.
        var variants: [String]
        /// Times the mishearings occur.
        var heardCount: Int
        /// Meetings whose written text uses the term.
        var meetingCount: Int
        var kind: Kind
        var score: Double

        enum Kind: String, Sendable { case acronym, name }

        /// Stable key for dismissing.
        var id: String { (heardAs.map { ProjectCatalog.fold($0) } ?? "") + "→" + term }

        var reason: String {
            if let heardAs {
                let times = heardCount == 1 ? "once" : "\(heardCount) times"
                return "Heard as “\(heardAs)” \(times) in meetings about \(term)"
            }
            return "Spelled this way in \(meetingCount) meetings"
        }
    }

    /// Common acronyms that every speech engine already gets right, or that aren't domain terms.
    static let commonAcronyms: Set<String> = [
        "THE", "AND", "FOR", "YOU", "NOT", "BUT", "ARE", "API", "URL", "PDF", "CEO", "CTO", "CFO", "COO", "USA",
        "USD", "EUR", "GBP", "FAQ", "ETA", "TBD", "ASAP", "FYI", "AKA", "DIY", "OK", "PM", "AM", "UTC", "GMT",
        "CPU", "GPU", "RAM", "SSD", "USB", "HTML", "CSS", "JSON", "XML", "HTTP", "HTTPS", "SQL", "VAT", "KPI",
        "OKR", "ROI", "NDA", "MVP", "POC", "QA", "UI", "UX", "AI", "LLM", "ML", "IT", "HR", "PR", "TV", "ID",
        "NEXT", "STEPS", "TODO", "NOTE", "NOTES", "AWS", "CLI", "SDK", "IDE", "CRM", "ERP", "SLA", "SSO",
    ]

    /// Ordinary words that are never worth correcting to (or from).
    static let stopWords: Set<String> = [
        "about", "after", "again", "also", "because", "before", "being", "between", "could", "every", "first",
        "from", "have", "into", "just", "like", "make", "more", "most", "need", "only", "other", "over", "really",
        "should", "some", "such", "than", "that", "their", "them", "then", "there", "these", "they", "thing",
        "think", "this", "those", "through", "very", "want", "well", "were", "what", "when", "where", "which",
        "while", "will", "with", "would", "your", "yeah", "okay", "right", "know", "mean", "going", "something",
        "microphone", "system", "audio", "meeting", "meetings", "nor", "not", "but", "for", "her", "his", "him",
        "she", "the", "and", "are", "was", "has", "had", "can", "cell", "sell", "self", "seal", "said", "same",
    ]

    /// Mines suggestions. `existing` holds terms already in Custom vocabulary
    /// ("replace with" values) and `exclude` words never to suggest (the
    /// user's own name); both are skipped.
    static func mine(_ documents: [Document], existing: Set<String> = [], exclude: Set<String> = [], limit: Int = 12) -> [Suggestion] {
        let skipped = Set((existing.union(exclude)).map { $0.lowercased() })

        // 1. Candidate terms from the written text, with the meetings using them.
        var termMeetings: [String: Set<UUID>] = [:]
        var termSpelling: [String: [String: Int]] = [:]
        var inTitles: Set<String> = []
        var lowercaseUses: [String: Int] = [:]
        for document in documents {
            for (term, kind) in candidateTerms(in: document.written) {
                let key = term.lowercased()
                termMeetings[key, default: []].insert(document.id)
                termSpelling[key, default: [:]][term, default: 0] += kind == .acronym ? 2 : 1
            }
            for (term, _) in candidateTerms(in: document.title) { inTitles.insert(term.lowercased()) }
            // Email addresses are lowercase by convention; they don't make a name an ordinary word.
            let prose = document.written.replacing(/\S+@\S+/, with: " ")
            for word in prose.components(separatedBy: CharacterSet.letters.inverted)
            where word.count >= 4 && word.first?.isLowercase == true {
                lowercaseUses[word, default: 0] += 1
            }
        }

        // 2. Transcript vocabulary per meeting: single words and joined pairs.
        struct Heard { var counts: [String: Int] = [:]; var pairs: [String: (text: String, count: Int)] = [:] }
        var heardByMeeting: [UUID: Heard] = [:]
        for document in documents where !document.heard.isEmpty {
            var heard = Heard()
            let words = transcriptWords(document.heard)
            for word in words { heard.counts[word, default: 0] += 1 }
            for (a, b) in zip(words, words.dropFirst()) {
                let joined = a + b
                heard.pairs[joined] = ("\(a) \(b)", (heard.pairs[joined]?.count ?? 0) + 1)
            }
            heardByMeeting[document.id] = heard
        }

        var suggestions: [Suggestion] = []
        for (key, meetings) in termMeetings {
            guard let spelling = termSpelling[key]?.max(by: { $0.value < $1.value })?.key,
                  !skipped.contains(key) else { continue }
            let kind: Suggestion.Kind = isAcronym(spelling) ? .acronym : .name
            let writtenUses = termSpelling[key]?.values.reduce(0, +) ?? 0
            // Recurring: names in two meetings, acronyms in two or used often in one.
            guard meetings.count >= 2 || (kind == .acronym && writtenUses >= 6) else { continue }
            // A word written in lowercase just as often is an ordinary word ("Manual").
            if kind == .name, Double(lowercaseUses[key] ?? 0) >= max(2, Double(writtenUses) * 0.5) { continue }

            // 3. Mishearings: sound-alike words heard in the term's meetings.
            // Short acronyms are spelled out (C-L-I), so only word-like ones ("TAPR") have sound-alikes.
            let termLetters = key.filter { $0.isLetter || $0.isNumber }
            let matchesWords = kind == .name || termLetters.count >= 4
            var inside: [String: Int] = [:]
            var outside: [String: Int] = [:]
            var display: [String: String] = [:]
            for (meetingID, heard) in heardByMeeting {
                let isTermMeeting = meetings.contains(meetingID)
                if matchesWords {
                    for (word, count) in heard.counts
                    where word != termLetters && !EnglishWords.isCommon(word) && soundsAlike(word, termLetters, kind: kind) {
                        if isTermMeeting { inside[word, default: 0] += count } else { outside[word, default: 0] += count }
                        display[word] = word
                    }
                }
                // "north wind" for "Northwind".
                if termLetters.count >= 6, let pair = heard.pairs[termLetters] {
                    if isTermMeeting { inside[termLetters + " ", default: 0] += pair.count } else { outside[termLetters + " ", default: 0] += pair.count }
                    display[termLetters + " "] = pair.text
                }
            }
            let variants = inside
                .filter { word, count in
                    // Mostly heard where the term is discussed, so it's this term and not a real word.
                    let out = outside[word] ?? 0
                    return Double(count) >= Double(count + out) * 0.6
                }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let heardCount = variants.reduce(0) { $0 + $1.value }

            let score: Double
            let heardAs: String?
            if let top = variants.first, heardCount >= 2 || (heardCount >= 1 && meetings.count >= 3) {
                heardAs = display[top.key]
                score = Double(heardCount) * 2 + Double(meetings.count)
            } else {
                // Spelled right already: worth a glossary line when it names
                // something (in a title) or keeps coming up.
                guard (inTitles.contains(key) && meetings.count >= 2) || meetings.count >= 4 else { continue }
                heardAs = nil
                score = Double(meetings.count) * 0.5 + (inTitles.contains(key) ? 2 : 0)
            }
            suggestions.append(Suggestion(
                term: spelling,
                heardAs: heardAs,
                variants: variants.compactMap { display[$0.key] },
                heardCount: heardCount,
                meetingCount: meetings.count,
                kind: kind,
                score: score
            ))
        }
        return Array(
            suggestions
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.term < $1.term }
                .prefix(limit)
        )
    }

    // MARK: - Pieces (internal for tests)

    /// Acronyms ("TAPR", "EC2") and proper names ("Pinecrest") in written text.
    static func candidateTerms(in text: String) -> [(String, Suggestion.Kind)] {
        var result: [(String, Suggestion.Kind)] = []
        // Skip markdown markers and quotes that glue to words.
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        for word in words {
            if isAcronym(word) {
                guard !commonAcronyms.contains(word), word.count <= 6, word.contains(where: \.isLetter) else { continue }
                result.append((word, .acronym))
            } else if let first = word.first, first.isUppercase, word.dropFirst().allSatisfy({ $0.isLowercase }),
                      word.count >= 4, !stopWords.contains(word.lowercased()) {
                result.append((word, .name))
            }
        }
        return result.filter { term, kind in
            // Ordinary capitalised words ("Dashboard") are common; names aren't English words.
            kind == .acronym || !EnglishWords.isCommon(term.lowercased())
        }
    }

    static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isUppercase || $0.isNumber } && word.contains(where: \.isUppercase)
    }

    /// Lowercased transcript words, without speaker labels and timestamps.
    static func transcriptWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && !stopWords.contains($0) }
    }

    /// "taper" ~ "tapr": the same consonant skeleton and a small edit distance.
    static func soundsAlike(_ heard: String, _ term: String, kind: Suggestion.Kind) -> Bool {
        guard heard.count >= 3, term.count >= 3, heard.first == term.first else { return false }
        guard skeleton(heard) == skeleton(term) else { return false }
        let distance = editDistance(heard, term)
        let allowed = kind == .acronym ? 2 : max(1, term.count / 3)
        return distance > 0 && distance <= allowed
    }

    /// Letters without vowels or doubled letters ("taper" → "tpr").
    static func skeleton(_ word: String) -> String {
        var result = ""
        for character in word.lowercased() where !"aeiouy".contains(character) {
            if result.last != character { result.append(character) }
        }
        return result
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// A small list of very common English words, so ordinary capitalised words
/// in summaries ("Dashboard", "Pricing") aren't taken for names.
enum EnglishWords {
    static func isCommon(_ word: String) -> Bool { common.contains(word) }

    static let common: Set<String> = [
        "about", "above", "access", "account", "accounts", "action", "actions", "added", "agenda", "agreed",
        "alignment", "already", "also", "analysis", "answer", "application", "approach", "approval", "architecture",
        "area", "areas", "automation", "available", "backend", "based", "being", "best", "better", "billing",
        "budget", "build", "building", "business", "call", "cards", "case", "cases", "change", "changes", "check",
        "clarification", "client", "clients", "cloud", "code", "company", "completed", "concerns", "confirm",
        "confirmed", "context", "cost", "costs", "current", "customer", "customers", "dashboard", "data", "database",
        "date", "deadline", "decision", "decisions", "delivery", "demo", "deployed", "deployment", "design",
        "details", "development", "discussion", "document", "documentation", "done", "draft", "each", "email",
        "engineering", "environment", "every", "example", "existing", "expected", "feedback", "final", "first",
        "focus", "follow", "frontend", "funding", "future", "goal", "goals", "good", "great", "health", "help",
        "high", "however", "impact", "important", "including", "information", "infrastructure", "initial",
        "integration", "issue", "issues", "item", "items", "alex", "just", "keep", "key", "last", "launch",
        "lead", "least", "level", "like", "line", "list", "long", "look", "made", "main", "make", "management",
        "many", "meeting", "migration", "model", "monday", "month", "monthly", "more", "most", "much", "must",
        "need", "needed", "needs", "network", "next", "note", "notes", "number", "offer", "once", "only", "open",
        "option", "options", "order", "other", "overall", "owner", "page", "part", "partner", "payment", "people",
        "performance", "phase", "pipeline", "plan", "planning", "platform", "point", "points", "possible",
        "previous", "price", "pricing", "priority", "problem", "process", "product", "production", "profit",
        "progress", "project", "projects", "proposal", "provide", "quarter", "question", "questions", "quick",
        "ready", "really", "reason", "recording", "related", "release", "report", "request", "required",
        "requirements", "research", "review", "revenue", "risk", "risks", "role", "roles", "sales", "same",
        "schedule", "scope", "security", "send", "service", "services", "session", "setup", "share", "should",
        "since", "slack", "small", "solution", "some", "source", "specific", "stage", "start", "status", "step",
        "steps", "still", "storage", "strategy", "structure", "summary", "support", "sure", "system", "systems",
        "talk", "target", "task", "tasks", "team", "teams", "technical", "test", "testing", "that", "their",
        "them", "then", "there", "these", "they", "thing", "things", "this", "those", "three", "through", "thursday",
        "time", "timeline", "today", "tool", "tools", "topic", "topics", "total", "tuesday", "update", "updates",
        "upload", "usage", "user", "users", "using", "value", "version", "very", "want", "week", "weekly", "well",
        "were", "what", "when", "where", "which", "while", "will", "with", "work", "workflow", "workflows",
        "working", "would", "year", "your", "friday", "wednesday", "saturday", "sunday", "january", "february",
        "march", "april", "june", "july", "august", "september", "october", "november", "december",
        "yesterday", "tomorrow", "morning", "afternoon", "evening", "agent", "agents", "agentic", "card",
        "approved", "sent", "processed", "invoice", "invoices", "editor", "mockup", "manager", "current",
        "three", "four", "five", "repeat", "expansion", "card", "profit", "sheet", "google", "microsoft",
        "amazon", "apple", "cash", "buffers", "credits", "satisfaction", "outlook", "sprint", "standup",
        "manual", "manually", "cell", "water", "later", "letter", "never", "number",
    ]
}
