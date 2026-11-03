import Foundation

/// Who said each word, from the audio source and (after the meeting) diarization.
///
/// - Microphone words are the person using LidIA: "You" (`isLocalSpeaker == true`,
///   `speaker == 0`).
/// - System-audio words are everyone else: "Others" (`isLocalSpeaker == false`). When
///   diarization hears two or more voices on the system track, they become "Speaker 2",
///   "Speaker 3", … (`speaker` 1, 2, … in order of first appearance).
/// - With the microphone only (an in-room meeting, or system audio off), the voice with the
///   most words is "You" and other voices diarization finds are numbered the same way.
enum SpeakerAttribution {
    struct Segment: Equatable, Sendable {
        var speaker: Int
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Diarizer speaker for a word: the segment containing its midpoint, else the nearest
    /// segment within `tolerance` seconds.
    static func diarizedSpeaker(for word: TranscriptWord, in segments: [Segment], tolerance: TimeInterval = 0.75) -> Int? {
        let mid = (word.start + word.end) / 2
        if let hit = segments.first(where: { mid >= $0.start && mid <= $0.end }) { return hit.speaker }
        var best: (distance: TimeInterval, speaker: Int)?
        for segment in segments {
            let distance = mid < segment.start ? segment.start - mid : mid - segment.end
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (distance, segment.speaker)
            }
        }
        return best?.speaker
    }

    /// Labels words by source and numbers remote voices from the system track's diarization.
    /// `words` carry `isLocalSpeaker` from their lane (true = mic, false = system).
    static func labelCall(_ words: [TranscriptWord], systemSegments: [Segment]) -> [TranscriptWord] {
        let remote = words.filter { $0.isLocalSpeaker == false }
        var diarized: [Int?] = remote.map { diarizedSpeaker(for: $0, in: systemSegments) }
        let distinct = Set(diarized.compactMap { $0 })
        // One remote voice: plain "Others". Several: number them.
        let numbering = distinct.count >= 2 ? firstAppearanceNumbering(diarized, startingAt: 1) : [:]
        if numbering.isEmpty { diarized = diarized.map { _ in nil } }

        var result = words
        var remoteIndex = 0
        for i in result.indices {
            if result[i].isLocalSpeaker == false {
                result[i].speaker = diarized[remoteIndex].flatMap { numbering[$0] }
                remoteIndex += 1
            } else {
                result[i].isLocalSpeaker = true
                result[i].speaker = 0
            }
        }
        return result
    }

    /// Microphone only: the voice with the most words is "You"; other voices are numbered.
    /// Without diarization (or one voice), every word is "You".
    static func labelRoom(_ words: [TranscriptWord], segments: [Segment]) -> [TranscriptWord] {
        let diarized = words.map { diarizedSpeaker(for: $0, in: segments) }
        var counts: [Int: Int] = [:]
        for speaker in diarized.compactMap({ $0 }) { counts[speaker, default: 0] += 1 }
        guard counts.count >= 2,
              let you = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else {
            return words.map { word in
                var w = word
                w.isLocalSpeaker = true
                w.speaker = 0
                return w
            }
        }
        let others = diarized.map { $0 == you ? nil : $0 }
        let numbering = firstAppearanceNumbering(others, startingAt: 1)
        return zip(words, diarized).map { word, speaker in
            var w = word
            if let speaker, speaker != you, let number = numbering[speaker] {
                w.isLocalSpeaker = false
                w.speaker = number
            } else {
                w.isLocalSpeaker = true
                w.speaker = 0
            }
            return w
        }
    }

    /// Diarizer IDs → 1, 2, 3… in the order they're first heard.
    private static func firstAppearanceNumbering(_ ids: [Int?], startingAt first: Int) -> [Int: Int] {
        var numbering: [Int: Int] = [:]
        for id in ids.compactMap({ $0 }) where numbering[id] == nil {
            numbering[id] = first + numbering.count
        }
        return numbering
    }

    /// The label shown for a word or segment.
    static func label(isLocalSpeaker: Bool?, speaker: Int?, speakerName: String?, localName: String) -> String {
        if let speakerName, !speakerName.trimmingCharacters(in: .whitespaces).isEmpty { return speakerName }
        if isLocalSpeaker == true { return localName }
        if let speaker {
            return speaker == 0 && isLocalSpeaker == nil ? localName : "Speaker \(speaker + 1)"
        }
        if isLocalSpeaker == false { return "Others" }
        return localName
    }
}
