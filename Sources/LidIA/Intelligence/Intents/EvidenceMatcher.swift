import Foundation

/// A transcript as speaker turns with times: the unit evidence is quoted from.
struct TranscriptTurn: Sendable, Equatable {
    var speaker: String?
    /// The microphone, i.e. the person recording ("Me"), or a speaker named
    /// as the user.
    var isUser: Bool?
    var start: TimeInterval?
    var text: String
}

enum TranscriptTimeline {
    /// Turns from timed words (speaker labels as the pipeline writes them).
    static func turns(from words: [TranscriptWord], userName: String = "") -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var current: TranscriptTurn?
        var currentCount = 0
        var lastWord: TranscriptWord?
        let userFirst = IntentText.firstName(userName)
        for word in words {
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = SpeakerTranscriptFormatter.label(for: word)
            // A long monologue becomes passages of a few sentences, so evidence
            // points at the moment, not at fifteen minutes of one speaker.
            let sentenceEnded = lastWord.map { [".", "?", "!"].contains($0.word.trimmingCharacters(in: .whitespaces).last.map(String.init) ?? "") } ?? false
            let paused = lastWord.map { word.start - $0.end >= 1.5 } ?? false
            let longEnough = currentCount >= maxPassageWords || (currentCount >= passageWords && (sentenceEnded || paused))
            defer { lastWord = word }
            if current == nil || label != current?.speaker || longEnough {
                currentCount = 1
                if let current { turns.append(current) }
                var isUser: Bool? = word.isLocalSpeaker
                if let label, !userFirst.isEmpty, IntentText.fold(label).hasPrefix(userFirst) { isUser = true }
                current = TranscriptTurn(speaker: label, isUser: isUser, start: word.start, text: text)
            } else {
                current?.text += " " + text
                currentCount += 1
            }
        }
        if let current { turns.append(current) }
        return mergeFragments(turns)
    }

    /// Passage length: split after this many words at a sentence end or pause…
    static let passageWords = 45
    /// …and always by this many.
    static let maxPassageWords = 90

    /// Turns from a text transcript: "Me: …" lines, or Granola's
    /// "[3:41] System audio (Mateo K): …" / "[3:47] Microphone: …".
    static func turns(fromText text: String, userName: String = "") -> [TranscriptTurn] {
        let userFirst = IntentText.firstName(userName)
        let parsed = text.components(separatedBy: .newlines).compactMap { raw -> TranscriptTurn? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            var start: TimeInterval?
            if let match = line.firstMatch(of: /^\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]\s*/) {
                let a = Double(match.1) ?? 0, b = Double(match.2) ?? 0
                start = match.3.flatMap { Double($0) }.map { a * 3600 + b * 60 + $0 } ?? (a * 60 + b)
                line = String(line[match.range.upperBound...])
            }
            if let match = line.firstMatch(of: /^(Microphone|System audio)(?:\s*\(([^)]+)\))?:\s*(.+)$/) {
                let isMic = match.1 == "Microphone"
                let name = match.2.map(String.init)
                return TranscriptTurn(speaker: isMic ? SpeakerTranscriptFormatter.localLabel : (name ?? SpeakerTranscriptFormatter.remoteLabel),
                                      isUser: isMic, start: start, text: String(match.3))
            }
            var turn = plainLine(line, userFirst: userFirst)
            turn?.start = start
            return turn
        }
        return mergeFragments(parsed)
    }

    private static func plainLine(_ line: String, userFirst: String) -> TranscriptTurn? {
        do {
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 30 {
                let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, label.split(separator: " ").count <= 3, !rest.isEmpty {
                    let isUser = label == SpeakerTranscriptFormatter.localLabel || (!userFirst.isEmpty && IntentText.fold(label).hasPrefix(userFirst))
                    return TranscriptTurn(speaker: label, isUser: isUser ? true : (label == SpeakerTranscriptFormatter.remoteLabel ? false : nil), start: nil, text: rest)
                }
            }
            return TranscriptTurn(speaker: nil, isUser: nil, start: nil, text: line)
        }
    }

    /// Crosstalk splits a sentence into one-word turns ("Me: the", "Them:
    /// did you…"). A turn of three words or fewer between two turns of the
    /// same other speaker is folded into its neighbour so quotes read whole.
    static func mergeFragments(_ turns: [TranscriptTurn]) -> [TranscriptTurn] {
        guard turns.count > 2 else { return turns }
        var pending = turns
        var kept: [TranscriptTurn] = []
        for index in pending.indices {
            let turn = pending[index]
            // Judged on the original turn: carried fragments don't add up to a turn.
            let isFragment = turns[index].text.split(separator: " ").count <= 3
            if isFragment, let next = (index + 1..<min(pending.count, index + 5)).first(where: { pending[$0].speaker == turn.speaker }) {
                // Carry the fragment into the same speaker's next turn.
                pending[next].text = turn.text + " " + pending[next].text
                if let start = turn.start { pending[next].start = min(start, pending[next].start ?? start) }
                continue
            }
            kept.append(turn)
        }
        var result: [TranscriptTurn] = []
        for turn in kept {
            if var last = result.last, last.speaker == turn.speaker,
               last.text.split(separator: " ").count + turn.text.split(separator: " ").count <= maxPassageWords {
                last.text += " " + turn.text
                result[result.count - 1] = last
            } else {
                result.append(turn)
            }
        }
        return result
    }
}

/// Finds the passage that backs an action item: speaker turns scored by how
/// many of the item's distinctive words they contain. Pure and on-device.
enum EvidenceMatcher {
    struct Match: Sendable, Equatable {
        var turnIndex: Int
        var turn: TranscriptTurn
        var quote: String
        var score: Double
        var matched: [String]
        var keywords: [String]
    }

    /// Below this, nothing in the transcript says it.
    static let notFoundBelow = 0.34
    /// From this, the transcript clearly backs it.
    static let supportedFrom = 0.6

    /// Best passages for `title`, best first. `exclude` drops words that
    /// can't be evidence (the user's own name: "explain X to Alex").
    static func matches(for title: String, in turns: [TranscriptTurn], exclude: [String] = [], limit: Int = 3) -> [Match] {
        let excluded = Set(exclude.map(IntentText.fold).flatMap { $0.split(separator: " ").map(String.init) })
        let keywords = IntentText.keywords(title).filter { !excluded.contains($0) }
        guard !keywords.isEmpty, !turns.isEmpty else { return [] }
        let stems = keywords.map(IntentText.stem)
        // Words found in many turns say little: weight by rarity.
        let folded = turns.map { Set(IntentText.words($0.text).map(IntentText.stem)) }
        let weights = stems.map { stem -> Double in
            // A word the transcript never uses weighs like a rare one, not more.
            let frequency = max(1, folded.filter { set in set.contains { IntentText.stemMatches($0, stem) } }.count)
            return 1 / (1 + log(1 + Double(frequency)))
        }
        let total = weights.reduce(0, +)
        var results: [Match] = []
        for index in turns.indices {
            // A turn with its neighbour: a request and its answer.
            let windowWords = folded[index].union(index + 1 < turns.count && turns[index + 1].speaker == turns[index].speaker ? folded[index + 1] : [])
            var score = 0.0
            var matched: [String] = []
            for (offset, stem) in stems.enumerated() where windowWords.contains(where: { IntentText.stemMatches($0, stem) }) {
                score += weights[offset]
                matched.append(keywords[offset])
            }
            guard !matched.isEmpty else { continue }
            let normalized = total > 0 ? score / total : 0
            results.append(Match(
                turnIndex: index, turn: turns[index],
                quote: quote(turns[index].text, around: matched),
                score: normalized, matched: matched, keywords: keywords
            ))
        }
        return Array(results.sorted { $0.score != $1.score ? $0.score > $1.score : $0.turnIndex < $1.turnIndex }.prefix(limit))
    }

    static func verdict(for score: Double?) -> ActionIntent.Verdict {
        guard let score else { return .notFound }
        if score >= supportedFrom { return .supported }
        if score >= notFoundBelow { return .weak }
        return .notFound
    }

    /// Up to ~28 words: the stretch with the most matched words.
    static func quote(_ text: String, around matched: [String], maxWords: Int = 28) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > maxWords else { return clean(text) }
        let stems = matched.map(IntentText.stem)
        let hits = words.map { word -> Bool in
            let folded = IntentText.stem(IntentText.words(word).first ?? "")
            return !folded.isEmpty && stems.contains { IntentText.stemMatches(folded, $0) }
        }
        var bestStart = 0
        var bestCount = -1
        for start in stride(from: 0, through: words.count - maxWords, by: 2) {
            let count = hits[start..<(start + maxWords)].filter { $0 }.count
            if count > bestCount { bestCount = count; bestStart = start }
        }
        // Lead in a little before the first hit of the stretch.
        let firstHit = hits[bestStart..<(bestStart + maxWords)].firstIndex(of: true) ?? bestStart
        let start = max(0, min(firstHit - 6, words.count - maxWords))
        let slice = words[start..<min(words.count, start + maxWords)].joined(separator: " ")
        return (start > 0 ? "…" : "") + clean(slice) + (start + maxWords < words.count ? "…" : "")
    }

    /// Drops fillers ("uh", "um") so a quote reads cleanly; never changes words.
    static func clean(_ text: String) -> String {
        text.split(separator: " ")
            .filter { !["uh", "um", "uhm", "erm"].contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            .joined(separator: " ")
    }
}

/// Small text helpers shared by the intent code.
enum IntentText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    static func firstName(_ name: String) -> String {
        fold(name).split(separator: " ").first.map(String.init) ?? ""
    }

    static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about", "at", "by", "from", "into",
        "is", "are", "be", "it", "this", "that", "their", "his", "her", "its", "our", "your", "my", "me", "we", "you",
        "they", "them", "he", "she", "i", "us", "so", "as", "up", "out", "any", "all", "some", "more", "new", "next",
        "attempt", "try", "possibly", "maybe", "should", "will", "would", "could", "can", "need", "needs",
        "el", "la", "los", "las", "de", "del", "con", "que", "en", "y", "un", "una", "por", "para",
    ]

    /// Content words of a title, in order.
    static func keywords(_ text: String) -> [String] {
        var seen = Set<String>()
        return words(text).filter { $0.count >= 3 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// "stacking" → "stack", "PRs" → "pr", "explained" → "explain".
    static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "es", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            w.removeLast(suffix.count)
            break
        }
        if w.count > 3, let last = w.last, let previous = w.dropLast().last, last == previous { w.removeLast() } // "stopp" → "stop"
        return w
    }

    static func stemMatches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        return shorter.count >= 4 && longer.hasPrefix(shorter)
    }

    /// "northwind.example" → "Northwind".
    static func company(fromDomain domain: String) -> String {
        let base = domain.split(separator: ".").dropLast().last.map(String.init) ?? domain
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}
