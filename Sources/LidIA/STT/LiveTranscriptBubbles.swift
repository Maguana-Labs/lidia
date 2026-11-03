import Foundation

/// One source's current guess while someone speaks; refined in place until final.
struct LiveVolatileLine: Equatable, Sendable {
    var text: String
    /// Seconds into the recording where the guess starts, when the engine says.
    var start: TimeInterval?
    var isLocalSpeaker: Bool
}

/// A paragraph bubble in the live transcript: consecutive words of one speaker.
struct LiveBubble: Identifiable, Equatable, Sendable {
    enum Speaker: Hashable, Sendable {
        case you
        case others
        /// A remote voice diarization told apart: "Speaker N".
        case numbered(Int)
    }

    /// Stable while the bubble grows: the index of its first final word, or a negative
    /// number for a bubble that has only a guess so far.
    let id: Int
    let speaker: Speaker
    /// Seconds into the recording.
    let start: TimeInterval
    /// Final words. Only ever grows at the end.
    var text: String
    /// The current guess after the final words, shown lighter; empty when none.
    var volatileText: String = ""
    /// Someone on this side is speaking and nothing is recognised yet: show "…".
    var isTyping = false

    var isLocal: Bool { speaker == .you }

    func label(localName: String) -> String {
        switch speaker {
        case .you: localName
        case .others: "Others"
        case .numbered(let n): "Speaker \(n + 1)"
        }
    }
}

/// Builds the live transcript's bubbles the way Granola shows them: one paragraph per run
/// of the same speaker, a timestamp per bubble, the guess refining at the end of the
/// speaker's bubble, and "…" while someone speaks before words appear.
enum LiveTranscriptBubbles {
    /// A pause this long starts a new bubble even for the same speaker.
    static let newBubbleAfterPause: TimeInterval = 30

    static func speaker(of word: TranscriptWord) -> LiveBubble.Speaker {
        switch word.isLocalSpeaker {
        case false?:
            if let speaker = word.speaker, speaker > 0 { return .numbered(speaker) }
            return .others
        default:
            return .you
        }
    }

    static func speaker(of lane: AudioSource) -> LiveBubble.Speaker {
        lane == .system ? .others : .you
    }

    /// - Parameters:
    ///   - words: final words in the order they were finalized (not re-sorted, so a
    ///     bubble on screen never changes except by growing at the end).
    ///   - volatile: each source's current guess.
    ///   - speaking: sources with speech-level audio right now.
    ///   - now: seconds into the recording, for a bubble that has no time yet.
    static func bubbles(
        words: [TranscriptWord],
        volatile: [AudioSource: LiveVolatileLine] = [:],
        speaking: Set<AudioSource> = [],
        now: TimeInterval = 0
    ) -> [LiveBubble] {
        var result: [LiveBubble] = []
        var lastEnd: TimeInterval = -.infinity
        for (index, word) in words.enumerated() {
            let who = speaker(of: word)
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let pause = word.start - lastEnd
            if var last = result.last, last.speaker == who, pause < newBubbleAfterPause {
                last.text += " " + text
                result[result.count - 1] = last
            } else {
                result.append(LiveBubble(id: index, speaker: who, start: max(0, word.start), text: text))
            }
            lastEnd = max(lastEnd, word.end)
        }

        // Guesses: on the speaker's last bubble when they're still talking, else a new one.
        let lanes = volatile
            .filter { !$0.value.text.isEmpty }
            .sorted { ($0.value.start ?? now, $0.key == .mic ? 0 : 1) < ($1.value.start ?? now, $1.key == .mic ? 0 : 1) }
        for (lane, line) in lanes {
            attach(to: &result, speaker: speaker(of: lane), pendingID: pendingID(lane), start: line.start ?? now) {
                $0.volatileText = line.text
            }
        }
        for lane in [AudioSource.mic, .system] where speaking.contains(lane) && (volatile[lane]?.text.isEmpty ?? true) {
            attach(to: &result, speaker: speaker(of: lane), pendingID: pendingID(lane), start: now) {
                $0.isTyping = true
            }
        }
        return result
    }

    private static func pendingID(_ lane: AudioSource) -> Int {
        lane == .system ? -2 : -1
    }

    private static func attach(
        to bubbles: inout [LiveBubble],
        speaker: LiveBubble.Speaker,
        pendingID: Int,
        start: TimeInterval,
        update: (inout LiveBubble) -> Void
    ) {
        if var last = bubbles.last, last.speaker == speaker {
            update(&last)
            bubbles[bubbles.count - 1] = last
        } else if let i = bubbles.lastIndex(where: { $0.id == pendingID }) {
            update(&bubbles[i])
        } else {
            var bubble = LiveBubble(id: pendingID, speaker: speaker, start: max(0, start), text: "")
            update(&bubble)
            bubbles.append(bubble)
        }
    }
}
