import Foundation

/// Fast, deterministic cleanup of dictated text. No model, no network, no
/// added latency (well under a millisecond for a paragraph).
///
/// In order: spoken "new line" / "new paragraph", filler words, self-corrections
/// ("Tuesday, no wait, Thursday" → "Thursday"), stutters ("the the"), the
/// user's personal vocabulary, spoken lists ("first … second …") and finally
/// spacing, punctuation and capitals.
///
/// The rules are conservative on purpose: when a phrase is ambiguous ("I like
/// it", "I mean it") it is left alone. "Polish with AI" handles the rest.
struct DictationTextCleaner: Sendable {
    struct Options: Sendable, Equatable {
        /// Fillers, self-corrections, stutters and lists. Vocabulary and
        /// punctuation are always applied.
        var tidy = true
        /// Primary language code ("en", "es"); picks filler and marker lists.
        var languageCode = "en"
    }

    var vocabulary: [AppSettings.VocabularyEntry] = []
    /// Extra terms whose spelling should be kept exactly (for example names
    /// and acronyms learned from meetings): "tapr" becomes "TAPR".
    var personalTerms: [String] = []
    var options = Options()

    func clean(_ raw: String) -> String {
        var text = Self.normalizeWhitespace(raw)
        guard !text.isEmpty else { return "" }
        let spanish = options.languageCode.hasPrefix("es")

        text = Self.applyVoiceCommands(text, spanish: spanish)
        if options.tidy {
            text = Self.removeFillers(text, spanish: spanish)
            text = Self.applySelfCorrections(text, spanish: spanish)
            text = Self.removeStutters(text)
        }
        text = applyVocabulary(text)
        text = Self.tidyPunctuation(text)
        if options.tidy {
            text = Self.mergeDanglingSentences(text, keepCapitalized: Set(canonicalTerms.map { $0.lowercased() }))
        }
        var isList = false
        if options.tidy, let list = Self.formatList(text, spanish: spanish) {
            text = list
            isList = true
        }
        text = Self.capitalize(text, english: !spanish)
        if !isList {
            text = Self.addTerminalPunctuation(text)
        }
        return text
    }

    // MARK: - Vocabulary

    /// Terms whose exact casing is enforced: replacements with unusual casing
    /// (acronyms, camel case, digits) plus `personalTerms`.
    var canonicalTerms: [String] {
        let fromVocabulary = vocabulary.map(\.replaceTo).filter(Self.hasDistinctiveCasing)
        return (fromVocabulary + personalTerms)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Words worth handing to the recogniser as hints.
    var recognitionHints: [String] {
        var seen = Set<String>()
        return (vocabulary.map(\.replaceTo) + personalTerms)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func applyVocabulary(_ text: String) -> String {
        var result = text
        for entry in vocabulary {
            let heard = entry.heardAs.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, heard != entry.replaceTo else { continue }
            result = Self.replaceWholeWords(heard, with: entry.replaceTo, in: result, caseSensitive: entry.caseSensitive)
        }
        for term in canonicalTerms {
            result = Self.replaceWholeWords(term, with: term, in: result, caseSensitive: false)
        }
        return result
    }

    static func hasDistinctiveCasing(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if term.contains(where: \.isNumber) { return true }
        // Any capital after the first letter: "TAPR", "iPhone", "McKinsey".
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    static func replaceWholeWords(_ phrase: String, with replacement: String, in text: String, caseSensitive: Bool) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    // MARK: - Voice commands

    static func applyVoiceCommands(_ text: String, spanish: Bool) -> String {
        var result = text
        let paragraph = spanish ? "(?:nuevo párrafo|new paragraph)" : "new paragraph"
        let line = spanish ? "(?:nueva línea|new line)" : "new line"
        result = replace("[,.]?\\s*\\b\(paragraph)\\b[,.]?\\s*", in: result, with: "\n\n")
        result = replace("[,.]?\\s*\\b\(line)\\b[,.]?\\s*", in: result, with: "\n")
        return result
    }

    // MARK: - Fillers

    static func removeFillers(_ text: String, spanish: Bool) -> String {
        var result = text
        var words = ["um+", "umm+", "uh+", "uhm+", "erm+", "er", "ah+", "hmm+", "mhm", "mm+"]
        if spanish { words += ["eh+", "em+", "este", "o sea", "pues"] }
        let alternation = words.joined(separator: "|")
        // A filler at the start of a sentence, with its comma: "Um, so…" → "So…".
        result = replace("(?<=^|[.!?\\n]\\s|[.!?\\n])\\s*(?:\(alternation))[,.…]*\\s+", in: result, with: "")
        // Elsewhere: "on, uh, Tuesday" → "on, Tuesday" (punctuation tidied later).
        let midFillers = spanish ? words.filter { !["este", "o sea", "pues"].contains($0) } : words
        result = replace(",?\\s*(?<![\\p{L}\\p{N}'’])(?:\(midFillers.joined(separator: "|")))(?![\\p{L}\\p{N}'’])[,…]?", in: result, with: "")
        // Comma-wrapped "you know" / "like" / Spanish "este": "it was, like, great".
        // ("I mean" is left for the self-correction step.)
        let wrapped = spanish ? "(?:o sea|este|pues|sabes)" : "(?:you know|like|kind of|sort of)"
        result = replace(",\\s*\(wrapped),\\s*", in: result, with: " ")
        result = replace("(?<=^|[.!?\\n]\\s)(?:You know|Like),\\s*", in: result, with: "", caseInsensitive: false)
        return result
    }

    // MARK: - Self-corrections

    private static let strongMarkersEN = ["no wait", "no, wait", "wait, no", "wait no", "actually no", "no, actually", "or rather", "scratch that"]
    private static let weakMarkersEN = ["sorry", "I mean", "make that"]
    private static let strongMarkersES = ["no, espera", "no espera", "mejor dicho", "borra eso"]
    private static let weakMarkersES = ["perdón", "digo", "quiero decir"]

    static func applySelfCorrections(_ text: String, spanish: Bool) -> String {
        var result = text
        let strong = strongMarkersEN + (spanish ? strongMarkersES : [])
        let weak = weakMarkersEN + (spanish ? weakMarkersES : [])
        for _ in 0..<6 {
            guard let next = applyFirstCorrection(result, strong: strong, weak: weak) else { break }
            result = next
        }
        return result
    }

    private static let clauseBoundaries: Set<Character> = [",", ";", ":", ".", "!", "?", "\n"]
    private static let sentenceBoundaries: Set<Character> = [".", "!", "?", "\n"]

    private static func applyFirstCorrection(_ text: String, strong: [String], weak: [String]) -> String? {
        // "no wait", "no, wait" and "no,  wait" are the same marker.
        let markers = Set((strong + weak).map(normalizeMarker)).map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: ",?\\s+")
        }
        // Text without any punctuation (an engine that doesn't punctuate) has no
        // pauses to look for, so strong markers count on their own there.
        let unpunctuated = !text.contains(where: { ",.;!?".contains($0) })
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(markers.joined(separator: "|")))(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text) else { continue }
            let marker = normalizeMarker(String(text[range]))
            let before = String(text[..<range.lowerBound])
            let after = String(text[range.upperBound...])

            // Content earlier in the same sentence is required, so "I mean, …"
            // opening a sentence is never treated as a correction.
            let sentenceStart = before.lastIndex(where: { sentenceBoundaries.contains($0) }).map { before.index(after: $0) } ?? before.startIndex
            let sentenceBefore = before[sentenceStart...].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            let isStrong = strong.map(normalizeMarker).contains(normalizeMarker(marker))

            if marker == "scratch that" || marker == "borra eso" {
                let rest = after.drop { $0 == "," || $0 == "." || $0 == " " }
                var head = String(before[..<sentenceStart])
                if sentenceBefore.isEmpty {
                    // "… Thursday. Scratch that." drops the previous sentence.
                    let trimmed = head.trimmingCharacters(in: .whitespaces)
                    let withoutEnd = trimmed.dropLast(trimmed.last.map { sentenceBoundaries.contains($0) } == true ? 1 : 0)
                    let previousStart = withoutEnd.lastIndex(where: { sentenceBoundaries.contains($0) }).map { withoutEnd.index(after: $0) } ?? withoutEnd.startIndex
                    head = String(withoutEnd[..<previousStart])
                }
                return join(head, String(rest))
            }

            guard !sentenceBefore.isEmpty else { continue }
            // A marker only counts at a pause ("Tuesday, no wait, Thursday"), so
            // "there's no wait time" or "sorry I missed it" are left alone.
            let prevChar = before.trimmingCharacters(in: .whitespaces).last
            let nextChar = after.first
            let atPause = prevChar == "," || prevChar == "." || nextChar == "," || nextChar == "."
            guard atPause || (isStrong && unpunctuated) else { continue }

            var replacement = Substring(after).drop { $0 == "," || $0 == "." || $0 == " " || $0 == "…" }
            guard !replacement.isEmpty else { continue }
            let headEnd = replacement.firstIndex(where: { clauseBoundaries.contains($0) }) ?? replacement.endIndex
            let replacementHead = replacement[..<headEnd].split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard !replacementHead.isEmpty else { continue }

            // The clause being corrected: words since the last boundary before the marker.
            var trimmedBefore = Substring(before)
            while let last = trimmedBefore.last, last == " " || last == "," { trimmedBefore = trimmedBefore.dropLast() }
            let clauseStart = trimmedBefore.lastIndex(where: { clauseBoundaries.contains($0) }).map { trimmedBefore.index(after: $0) } ?? trimmedBefore.startIndex
            let clause = trimmedBefore[clauseStart...]
            var clauseWords = clause.split(whereSeparator: \.isWhitespace)
            guard !clauseWords.isEmpty else { continue }

            // Align on a repeated word ("to John, sorry, to Mary"), else drop as
            // many words as the correction has, at most the whole clause.
            let normalized = clauseWords.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if let anchor = normalized.lastIndex(of: replacementHead[0]) {
                clauseWords.removeSubrange(anchor...)
            } else {
                clauseWords.removeLast(min(replacementHead.count, clauseWords.count))
            }
            let kept = String(trimmedBefore[..<clauseStart]) + (clauseWords.isEmpty ? "" : (clauseStart == trimmedBefore.startIndex ? "" : " ") + clauseWords.joined(separator: " "))
            replacement = replacement.drop { $0 == " " }
            return join(kept, String(replacement))
        }
        return nil
    }

    private static func normalizeMarker(_ marker: String) -> String {
        marker.lowercased()
            .replacingOccurrences(of: ",", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func join(_ head: String, _ tail: String) -> String {
        var head = head
        while let last = head.last, last == " " || last == "," { head.removeLast() }
        let tail = tail.trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }

    // MARK: - Stutters

    private static let intentionalRepeats: Set<String> = ["had", "that", "very", "so", "no", "bye", "ha", "really", "many", "more", "much", "go", "now", "yeah", "yes", "is"]

    static func removeStutters(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}'])(\\p{L}+)(?:\\s+\\1)+(?![\\p{L}\\p{N}'])", options: [.caseInsensitive]) else { return text }
        var result = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range(at: 1))
            guard !intentionalRepeats.contains(word.lowercased()),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: word)
        }
        return result
    }

    // MARK: - Sentences broken at a pause

    private static let danglingWords: Set<String> = [
        "a", "an", "the", "to", "of", "on", "at", "in", "for", "with", "from", "by", "and", "or", "but",
        "is", "are", "was", "were", "my", "your", "our", "their", "his", "her", "its", "this", "that",
        "el", "la", "los", "las", "un", "una", "de", "del", "en", "con", "para", "por", "y", "o", "que", "es", "mi", "tu", "su",
    ]

    private static let properWords: Set<String> = [
        "i", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    /// "is on. Thursday at 3." → "is on Thursday at 3." The recogniser puts a
    /// full stop at every pause; a sentence can't end on "on" or "the".
    static func mergeDanglingSentences(_ text: String, keepCapitalized: Set<String> = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(\\p{L}+)\\.\\s+(\\p{L}[\\p{L}\\p{N}'’]*)") else { return text }
        var result = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let last = ns.substring(with: match.range(at: 1))
            guard danglingWords.contains(last.lowercased()) else { continue }
            var next = ns.substring(with: match.range(at: 2))
            let lowered = next.lowercased()
            let isAcronym = next.count > 1 && next == next.uppercased()
            if !properWords.contains(lowered) && !keepCapitalized.contains(lowered) && !isAcronym {
                next = lowered
            } else if lowered == "i" {
                next = "I"
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "\(last) \(next)")
        }
        return result
    }

    // MARK: - Lists

    private static let ordinalsEN = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let numbersEN = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinalsES = ["primero", "segundo", "tercero", "cuarto", "quinto", "sexto", "séptimo", "octavo", "noveno", "décimo"]

    /// "Three things. First, buy milk. Second, call John." →
    /// "Three things:\n1. Buy milk\n2. Call John". Needs at least two items in order.
    static func formatList(_ text: String, spanish: Bool) -> String? {
        var markerPatterns: [String] = []
        for i in 0..<10 {
            var alternatives = ["\(ordinalsEN[i])(?:ly)?", "number \(numbersEN[i])"]
            if spanish { alternatives.append(ordinalsES[i]) }
            markerPatterns.append("(?:\(alternatives.joined(separator: "|")))")
        }
        let any = markerPatterns.enumerated().map { "(?<m\($0.offset)>\($0.element))" }.joined(separator: "|")
        // Ordinals count after a pause; "number one/two" anywhere (it's unambiguous).
        let pattern = "(?:^|(?<=[.!?:;,\\n]\\s)|(?<=[.!?:;,\\n])|(?<=\\s)(?=number\\s))\\s*(?:and\\s+|y\\s+)?(?:\(any))\\b[,:]?\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        // Keep the first run of consecutive ordinals starting at "first".
        var run: [(index: Int, range: NSRange)] = []
        for match in matches {
            guard let index = (0..<10).first(where: { match.range(withName: "m\($0)").location != NSNotFound }) else { continue }
            if index == run.count {
                run.append((index, match.range))
            } else if index == 0 && run.count < 2 {
                run = [(0, match.range)]
            }
        }
        guard run.count >= 2 else { return nil }

        let intro = ns.substring(to: run[0].range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        var items: [String] = []
        for (offset, entry) in run.enumerated() {
            let start = entry.range.location + entry.range.length
            let end = offset + 1 < run.count ? run[offset + 1].range.location : ns.length
            guard end > start else { return nil }
            var item = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            item = replace("(?:,?\\s+(?:and|y))$", in: item, with: "", caseInsensitive: true)
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
            guard !item.isEmpty else { return nil }
            items.append(capitalizeFirst(item))
        }
        let body = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? body : "\(capitalizeFirst(intro)):\n\(body)"
    }

    // MARK: - Punctuation and capitals

    static func tidyPunctuation(_ text: String) -> String {
        var result = text
        result = replace("[ \\t]+([,.;:!?…])", in: result, with: "$1")          // "word ," → "word,"
        result = replace(",\\s*([.!?;:])", in: result, with: "$1")               // ",." → "."
        result = replace("([.!?;:]),+", in: result, with: "$1")                  // ".," → "."
        result = replace(",(\\s*,)+", in: result, with: ",")                     // ",," → ","
        result = replace("\\.{2,}(?!\\.)", in: result, with: ".")
        result = replace("([,;:])(?=\\p{L})", in: result, with: "$1 ")             // "a,b" → "a, b" (not "3:30")
        result = replace("(?m)^[ \\t]*[,.;:]+[ \\t]*", in: result, with: "")      // leading punctuation
        result = replace("[ \\t]{2,}", in: result, with: " ")
        result = replace("(?m)[ \\t]+$", in: result, with: "")
        result = replace("(?m)^[ \\t]+", in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalize(_ text: String, english: Bool) -> String {
        var result = text
        if english {
            result = replace("(?<![\\p{L}\\p{N}])i(?=(?:['’](?:m|ll|ve|d|s))?(?![\\p{L}\\p{N}]))", in: result, with: "I", caseInsensitive: false)
        }
        var chars = Array(result)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                // Leave camel-case words ("iPhone") alone.
                let nextIsUpper = i + 1 < chars.count && chars[i + 1].isUppercase
                if !nextIsUpper { chars[i] = Character(c.uppercased()) }
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                // "3.5" isn't a sentence end.
                let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
                if !nextIsDigit { capitalizeNext = true }
            } else if !c.isWhitespace && c != "¿" && c != "¡" && c != "\"" && c != "(" {
                capitalizeNext = false
            }
        }
        result = String(chars)
        return result
    }

    private static let questionStarters: Set<String> = [
        "what", "why", "how", "when", "where", "who", "which", "can", "could", "would", "should",
        "is", "are", "do", "does", "did", "will", "shall", "have", "has", "may",
    ]

    /// A final full stop on dictations of three words or more ("ok thanks" stays bare);
    /// a question mark when the text opens like a question.
    static func addTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return text }
        let lastSentenceStart = text.lastIndex(where: { sentenceBoundaries.contains($0) }).map { text.index(after: $0) } ?? text.startIndex
        let firstWord = text[lastSentenceStart...].split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        return text + (questionStarters.contains(firstWord) ? "?" : ".")
    }

    // MARK: - Helpers

    static func normalizeWhitespace(_ text: String) -> String {
        replace("[ \\t]+", in: text.replacingOccurrences(of: "\r\n", with: "\n"), with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        if text.count > 1, text[text.index(after: text.startIndex)].isUppercase { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func replace(_ pattern: String, in text: String, with template: String, caseInsensitive: Bool = true) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            assertionFailure("Bad pattern: \(pattern)")
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
