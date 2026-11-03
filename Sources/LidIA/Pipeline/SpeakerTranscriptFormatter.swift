import Foundation

/// Turns timed words into a speaker-labelled transcript for the LLM.
///
/// Labels, in order of preference:
/// 1. `speakerName` set by diarization or the user
/// 2. `isLocalSpeaker == true` → "Me" (the microphone, i.e. the person recording)
/// 3. `isLocalSpeaker == false` → "Them", or "Speaker N" when diarization split the remote side
/// 4. `speaker` index alone → "Speaker N"
/// Words without any label stay with the current turn. When no word has a label the
/// transcript is returned unlabelled, split into paragraphs on long pauses.
enum SpeakerTranscriptFormatter {
    static let localLabel = "Me"
    static let remoteLabel = "Them"

    /// Pause (seconds) that starts a new paragraph within the same speaker's turn.
    static let paragraphPause: TimeInterval = 2.0

    static func label(for word: TranscriptWord) -> String? {
        if let name = word.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        switch word.isLocalSpeaker {
        case true?:
            return localLabel
        case false?:
            if let speaker = word.speaker { return "Speaker \(speaker + 1)" }
            return remoteLabel
        case nil:
            if let speaker = word.speaker { return "Speaker \(speaker + 1)" }
            return nil
        }
    }

    /// True when at least two distinct speakers are identifiable.
    static func hasSpeakerLabels(_ words: [TranscriptWord]) -> Bool {
        var seen = Set<String>()
        for word in words {
            if let label = label(for: word) {
                seen.insert(label)
                if seen.count > 1 { return true }
            }
        }
        // A single labelled speaker is still useful if it's the Me/Them split.
        return seen.contains(localLabel) || seen.contains(remoteLabel)
    }

    static func format(_ words: [TranscriptWord]) -> String {
        let cleaned = words.filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cleaned.isEmpty else { return "" }
        let labelled = hasSpeakerLabels(cleaned)

        var lines: [String] = []
        var currentLabel: String?
        var currentWords: [String] = []
        var lastEnd: TimeInterval?

        func flush() {
            guard !currentWords.isEmpty else { return }
            let text = currentWords.joined(separator: " ")
            if labelled, let currentLabel {
                lines.append("\(currentLabel): \(text)")
            } else {
                lines.append(text)
            }
            currentWords = []
        }

        for word in cleaned {
            let wordLabel = labelled ? label(for: word) : nil
            let pause = lastEnd.map { word.start - $0 } ?? 0
            if let wordLabel, wordLabel != currentLabel {
                flush()
                currentLabel = wordLabel
            } else if pause >= paragraphPause, !currentWords.isEmpty {
                flush()
            }
            currentWords.append(word.word.trimmingCharacters(in: .whitespacesAndNewlines))
            lastEnd = max(lastEnd ?? word.end, word.end)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Short preamble that tells the model what the labels mean, so it never guesses.
    static func legend(for words: [TranscriptWord], attendees: [String]?, userName: String = "") -> String? {
        guard hasSpeakerLabels(words) else { return nil }
        var labels: [String] = []
        for word in words {
            if let l = label(for: word), !labels.contains(l) { labels.append(l) }
        }
        var lines = ["SPEAKER LABELS (already identified — do not re-guess who is speaking):"]
        let user = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if labels.contains(localLabel) {
            lines.append(user.isEmpty
                ? "- \"\(localLabel)\" is the user who recorded this meeting (their microphone)."
                : "- \"\(localLabel)\" is \(user), who recorded this meeting (their microphone). When others say \"you\" to \(localLabel), they mean \(user).")
        }
        if labels.contains(remoteLabel) {
            lines.append("- \"\(remoteLabel)\" is everyone heard through the computer's audio (the other participant(s)).")
        }
        let others = labels.filter { $0 != localLabel && $0 != remoteLabel }
        if !others.isEmpty {
            lines.append("- Other labels: \(others.joined(separator: ", ")).")
        }
        if let attendees, !attendees.isEmpty, labels.contains(remoteLabel) {
            lines.append("- Calendar attendees: \(attendees.joined(separator: ", ")). Only map \"\(remoteLabel)\" to a name when the transcript makes it explicit.")
        }
        return lines.joined(separator: "\n")
    }
}
