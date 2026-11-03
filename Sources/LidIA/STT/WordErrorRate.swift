import Foundation

/// Word error rate and formatting statistics for comparing a transcript with a reference.
/// Used by the live STT harness (`LiveSTTHarnessTests`) and its write-up in
/// docs/research/2026-11-live-stt.md.
enum WordErrorRate {
    struct Result: Equatable, Sendable {
        var referenceWords: Int
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        /// For each hypothesis word, the index of the reference word it was aligned to
        /// (correct or substituted), or nil for an insertion.
        var hypothesisToReference: [Int?]

        var errors: Int { substitutions + deletions + insertions }
        var wer: Double { referenceWords == 0 ? 0 : Double(errors) / Double(referenceWords) }
    }

    /// Lowercases, drops punctuation, spells out small numbers and splits into words, so
    /// "1, 2, 3." and "one two three" compare equal and "it's" stays one word.
    static func normalizedWords(_ text: String) -> [String] {
        var cleaned = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "'" {
                cleaned.unicodeScalars.append(scalar)
            } else if scalar == "’" {
                cleaned.append("'")
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").flatMap { token -> [String] in
            let word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard !word.isEmpty else { return [] }
            if let number = Int(word), let spelled = spelledNumber(number) { return spelled }
            return [word]
        }
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func spelledNumber(_ n: Int) -> [String]? {
        guard n >= 0, n < 100 else { return nil }
        if n < 20 { return [ones[n]] }
        return n % 10 == 0 ? [tens[n / 10]] : [tens[n / 10], ones[n % 10]]
    }

    /// Levenshtein alignment over normalized words.
    ///
    /// - Parameter freeEnds: hypothesis words before the first and after the last reference
    ///   word cost nothing. For a reference that covers only part of the audio (another app
    ///   that started recording later).
    static func compute(reference: [String], hypothesis: [String], freeEnds: Bool = false) -> Result {
        let n = reference.count
        let m = hypothesis.count
        // cost[i][j]: aligning reference[0..<i] with hypothesis[0..<j].
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = freeEnds ? 0 : j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let match = cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                    let deletion = cost[i - 1][j] + 1
                    let insertion = cost[i][j - 1] + 1
                    cost[i][j] = min(match, deletion, insertion)
                }
            }
        }
        // With free ends, the alignment may stop at any hypothesis word.
        var j = m
        if freeEnds {
            // The latest hypothesis position with the lowest cost; words after it are free.
            var best = Int.max
            for k in 0...m where cost[n][k] <= best {
                best = cost[n][k]
                j = k
            }
        }
        var i = n
        var subs = 0, dels = 0, ins = 0
        var map = [Int?](repeating: nil, count: m)
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                if reference[i - 1] != hypothesis[j - 1] { subs += 1 }
                map[j - 1] = i - 1
                i -= 1; j -= 1
            } else if i > 0 && cost[i][j] == cost[i - 1][j] + 1 {
                dels += 1
                i -= 1
            } else if j > 0 {
                if !(freeEnds && i == 0) { ins += 1 }
                j -= 1
            } else {
                break
            }
        }
        return Result(referenceWords: n, substitutions: subs, deletions: dels, insertions: ins, hypothesisToReference: map)
    }

    static func compute(reference: String, hypothesis: String, freeEnds: Bool = false) -> Result {
        compute(reference: normalizedWords(reference), hypothesis: normalizedWords(hypothesis), freeEnds: freeEnds)
    }

    /// How a transcript reads: sentence punctuation, capitals, numerals and cut words.
    struct Formatting: Equatable, Sendable {
        /// Sentence-ending marks (. ? !) per 100 words.
        var sentenceMarksPer100Words: Double
        /// Commas per 100 words.
        var commasPer100Words: Double
        /// Share of sentences (text after . ? !) that start with a capital letter.
        var capitalizedSentenceShare: Double
        /// Whether any number is written with digits.
        var usesDigits: Bool

        static func measure(_ text: String) -> Formatting {
            let words = text.split(whereSeparator: \.isWhitespace)
            let count = max(1, words.count)
            let marks = text.filter { ".?!".contains($0) }.count
            let commas = text.filter { $0 == "," }.count
            let sentences = text
                .split(whereSeparator: { ".?!".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let capitalized = sentences.filter { $0.first?.isUppercase == true }.count
            return Formatting(
                sentenceMarksPer100Words: Double(marks) * 100 / Double(count),
                commasPer100Words: Double(commas) * 100 / Double(count),
                capitalizedSentenceShare: sentences.isEmpty ? 0 : Double(capitalized) / Double(sentences.count),
                usesDigits: text.contains { $0.isNumber }
            )
        }
    }

    /// Hypothesis words that are a strict prefix of the reference word they were aligned
    /// to ("wor" for "working"): the symptom of the old Parakeet stitching bug.
    static func truncatedWords(reference: [String], hypothesis: [String], alignment: Result) -> [String] {
        hypothesis.indices.compactMap { j in
            guard let i = alignment.hypothesisToReference[j] else { return nil }
            let hyp = hypothesis[j], ref = reference[i]
            return hyp != ref && hyp.count >= 2 && ref.hasPrefix(hyp) ? hyp : nil
        }
    }
}
