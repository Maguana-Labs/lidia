import Foundation

/// A speaker-attributed, time-bounded run of transcript words shown as one line
/// in the transcript inspector.
struct TranscriptSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: Int?
    let speakerName: String?
    let isLocalSpeaker: Bool?

    /// Whether this segment was spoken by the user. Prefers the capture-side
    /// mic/system tag and falls back to diarization speaker 0.
    var isLocal: Bool {
        if let isLocalSpeaker { return isLocalSpeaker }
        if let speaker { return speaker == 0 }
        return false
    }

    /// Human-readable speaker label, or nil when the transcript has no speaker data.
    func speakerLabel(localName: String) -> String? {
        if let speakerName, !speakerName.trimmingCharacters(in: .whitespaces).isEmpty {
            return speakerName
        }
        guard isLocalSpeaker != nil || speaker != nil else { return nil }
        return SpeakerAttribution.label(isLocalSpeaker: isLocalSpeaker, speaker: speaker, speakerName: nil, localName: localName)
    }
}

/// Pure transcript grouping and lookup logic used by the meeting page.
enum TranscriptSegmenter {
    /// Max seconds a single segment may span before it is split.
    static let maxSegmentDuration: TimeInterval = 12
    /// Max words in a single segment.
    static let maxSegmentWords = 40
    /// Gap needed before a mic/system change splits a segment (dual-stream words interleave).
    static let localChangeGap: TimeInterval = 1.5

    /// Sorts words by start time and rebases absolute host-clock timestamps to zero.
    static func normalizedWords(_ words: [TranscriptWord], meetingDuration: TimeInterval) -> [TranscriptWord] {
        guard !words.isEmpty else { return [] }
        var result = words
        if let minStart = result.map(\.start).min(),
           minStart > max(10_000, meetingDuration + 60) {
            for i in result.indices {
                result[i].start -= minStart
                result[i].end -= minStart
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func segments(from rawWords: [TranscriptWord], meetingDuration: TimeInterval) -> [TranscriptSegment] {
        let words = normalizedWords(rawWords, meetingDuration: meetingDuration)
        guard let first = words.first else { return [] }
        let hasPunctuation = words.contains { $0.word.last.map { ".?!".contains($0) } ?? false }

        var segments: [TranscriptSegment] = []
        var currentWords: [String] = []
        var segmentStart = max(0, first.start)
        var segmentEnd = max(segmentStart, first.end)
        var currentSpeaker = first.speaker
        var currentSpeakerName = first.speakerName
        var currentIsLocal = first.isLocalSpeaker

        func flush() {
            guard !currentWords.isEmpty else { return }
            segments.append(TranscriptSegment(
                id: segments.count,
                start: segmentStart,
                end: segmentEnd,
                text: currentWords.joined(separator: " "),
                speaker: currentSpeaker,
                speakerName: currentSpeakerName,
                isLocalSpeaker: currentIsLocal
            ))
            currentWords.removeAll(keepingCapacity: true)
        }

        for word in words {
            let wordStart = max(0, word.start)
            let wordEnd = max(wordStart, word.end)
            // Long turns split where a sentence ends ("…help articles." stays whole); only
            // unpunctuated text is cut at the limit itself, and nothing runs past twice it.
            let atSentenceEnd = currentWords.last.map { $0.last.map { ".?!".contains($0) } ?? false } ?? false
            let span = wordEnd - segmentStart
            let hitDurationLimit = !currentWords.isEmpty
                && ((span > maxSegmentDuration && (atSentenceEnd || !hasPunctuation)) || span > maxSegmentDuration * 2.5)
            let hitWordLimit = (currentWords.count >= maxSegmentWords && (atSentenceEnd || !hasPunctuation))
                || currentWords.count >= maxSegmentWords * 2
            let speakerChanged = word.speaker != nil && word.speaker != currentSpeaker
            let localChanged = word.isLocalSpeaker != currentIsLocal && (wordStart - segmentEnd) > localChangeGap

            if hitDurationLimit || hitWordLimit || speakerChanged || localChanged {
                flush()
                segmentStart = wordStart
                currentSpeaker = word.speaker
                currentSpeakerName = word.speakerName
                currentIsLocal = word.isLocalSpeaker
            }

            currentWords.append(word.word)
            segmentEnd = wordEnd
        }
        flush()
        return segments
    }

    /// True when any segment carries speaker attribution.
    static func hasSpeakerInfo(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { $0.speaker != nil || $0.speakerName != nil || $0.isLocalSpeaker != nil }
    }

    /// Indices of segments containing `query` (case/diacritic-insensitive). Empty query → no matches.
    static func matchingIndices(in segments: [TranscriptSegment], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return segments.indices.filter { segments[$0].text.localizedStandardContains(needle) }
    }

    /// Index of the segment being spoken at `time`, used to highlight during playback.
    static func activeIndex(in segments: [TranscriptSegment], at time: TimeInterval) -> Int? {
        guard !segments.isEmpty, time >= 0 else { return nil }
        // Last segment whose start is <= time.
        var low = 0
        var high = segments.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}
