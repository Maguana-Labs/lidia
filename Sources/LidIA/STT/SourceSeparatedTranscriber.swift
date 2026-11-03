import Foundation

/// A live update from one audio source.
struct LiveLaneEvent: Sendable, Equatable {
    /// `.mic` or `.system`.
    var lane: AudioSource
    /// Times are seconds on the recording timeline; finalized words carry the lane's
    /// speaker label.
    var event: LiveSTTEvent
}

/// Transcribes the capture stream with one STT engine per audio source.
///
/// The capture stream interleaves mic and system chunks (often at different sample rates).
/// Feeding that into one engine garbles both sides. This splits the stream by source, runs
/// a separate engine instance on each, and labels words from the mic as the local speaker
/// ("You") and words from system audio as the remote side ("Others").
///
/// Word times are converted to seconds on the recording timeline, the same timeline the
/// recorded audio files use.
struct SourceSeparatedTranscriber: Sendable {
    /// Creates a fresh engine for one source lane.
    let makeEngine: @Sendable () -> any STTEngine
    /// When false (mic-only capture), everything goes to one engine (the mic lane).
    let separateSources: Bool
    /// Wall-clock time → seconds into the recording.
    let timeline: @Sendable (TimeInterval) -> TimeInterval
    /// Current wall-clock time; injectable for tests.
    var now: @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }

    /// Final words only.
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptWord> {
        let events = transcribeLive(input)
        return AsyncStream { output in
            let task = Task {
                for await laneEvent in events {
                    if case .finalized(let words) = laneEvent.event {
                        for word in words { output.yield(word) }
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    func transcribeLive(_ input: AsyncStream<AudioChunk>) -> AsyncStream<LiveLaneEvent> {
        let makeEngine = makeEngine
        let separate = separateSources
        let timeline = timeline
        let now = now
        return AsyncStream { output in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    var lanes: [AudioSource: AsyncStream<AudioChunk>.Continuation] = [:]
                    for await chunk in input {
                        let lane = Self.lane(for: chunk.source, separate: separate)
                        if lanes[lane] == nil {
                            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
                            lanes[lane] = continuation
                            let streamStart = timeline(chunk.timestamp - chunk.duration)
                            let label = Self.isLocalSpeaker(lane: lane)
                            let engine = makeEngine()
                            group.addTask {
                                for await event in engine.liveEvents(audioStream: stream) {
                                    switch event {
                                    case .finalized(let words):
                                        let arrival = timeline(now())
                                        let normalized = words.map { word -> TranscriptWord in
                                            var w = LiveWordTiming.normalize(
                                                word,
                                                streamStart: streamStart,
                                                arrival: arrival,
                                                timeline: timeline
                                            )
                                            w.isLocalSpeaker = label
                                            return w
                                        }
                                        output.yield(LiveLaneEvent(lane: lane, event: .finalized(normalized)))
                                    case .volatile(let text, let start):
                                        let placed = start.map { LiveWordTiming.normalizeTime($0, streamStart: streamStart, timeline: timeline) }
                                        output.yield(LiveLaneEvent(lane: lane, event: .volatile(text: text, start: placed)))
                                    }
                                }
                            }
                        }
                        lanes[lane]?.yield(chunk)
                    }
                    for continuation in lanes.values {
                        continuation.finish()
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    static func lane(for source: AudioSource, separate: Bool) -> AudioSource {
        separate && source == .system ? .system : .mic
    }

    /// The microphone is the person using LidIA ("You"), as in Granola, also when system
    /// audio isn't captured: the recording is their side of the call. System audio is
    /// everyone else. Diarization after the meeting can still tell other voices on the mic
    /// apart (an in-room meeting).
    static func isLocalSpeaker(lane: AudioSource) -> Bool {
        lane != .system
    }
}

/// Puts engine word timings on the recording timeline.
///
/// Engines report time differently: Apple Speech relative to the audio it was fed,
/// WhisperKit as wall-clock seconds, and Parakeet streaming not at all (0/0).
enum LiveWordTiming {
    /// Anything above this is a Unix timestamp rather than an offset.
    static let epochThreshold: TimeInterval = 1_000_000_000

    static func normalize(
        _ word: TranscriptWord,
        streamStart: TimeInterval,
        arrival: TimeInterval,
        timeline: (TimeInterval) -> TimeInterval
    ) -> TranscriptWord {
        var w = word
        if w.start == 0 && w.end == 0 {
            // No timing from the engine: use when the word arrived.
            w.start = arrival
            w.end = arrival
        } else if w.start > epochThreshold {
            w.start = timeline(w.start)
            w.end = timeline(max(w.end, word.start))
        } else {
            w.start += streamStart
            w.end += streamStart
        }
        if w.end < w.start { w.end = w.start }
        return w
    }

    /// One engine time (offset into the lane's audio, or a Unix time) on the recording timeline.
    static func normalizeTime(
        _ time: TimeInterval,
        streamStart: TimeInterval,
        timeline: (TimeInterval) -> TimeInterval
    ) -> TimeInterval {
        time > epochThreshold ? timeline(time) : time + streamStart
    }
}

/// Merges separately transcribed mic and system words into one transcript.
enum SpeakerStreamMerger {
    /// Labels mic words as the local speaker and system words as remote, drops mic words
    /// that are just the other side leaking from the speakers into the mic, and sorts by time.
    static func merge(mic: [TranscriptWord], system: [TranscriptWord]) -> [TranscriptWord] {
        var micWords = mic.map { w -> TranscriptWord in
            var w = w
            w.isLocalSpeaker = true
            return w
        }
        let systemWords = system.map { w -> TranscriptWord in
            var w = w
            w.isLocalSpeaker = false
            return w
        }
        micWords = suppressEchoes(mic: micWords, system: systemWords)
        return (micWords + systemWords).sorted { lhs, rhs in
            lhs.start == rhs.start ? (lhs.isLocalSpeaker == true && rhs.isLocalSpeaker != true) : lhs.start < rhs.start
        }
    }

    /// Removes runs of mic words that repeat system words at about the same time.
    ///
    /// Without headphones, the mic picks up the other participants from the speakers, so the
    /// mic lane transcribes them too. A single matching word is common by chance ("the",
    /// "yes"), so only runs of at least `minRun` consecutive echoed words are dropped.
    static func suppressEchoes(
        mic: [TranscriptWord],
        system: [TranscriptWord],
        window: TimeInterval = 1.5,
        minRun: Int = 3
    ) -> [TranscriptWord] {
        guard !mic.isEmpty, !system.isEmpty else { return mic }
        let systemByStart = system
            .map { (start: $0.start, key: normalizedKey($0.word)) }
            .filter { !$0.key.isEmpty }
            .sorted { $0.start < $1.start }
        let starts = systemByStart.map(\.start)

        func isEcho(_ word: TranscriptWord) -> Bool {
            let key = normalizedKey(word.word)
            guard !key.isEmpty else { return false }
            var i = lowerBound(starts, word.start - window)
            while i < systemByStart.count, systemByStart[i].start <= word.start + window {
                if systemByStart[i].key == key { return true }
                i += 1
            }
            return false
        }

        let echoes = mic.map(isEcho)
        var keep = [Bool](repeating: true, count: mic.count)
        var runStart = 0
        for i in 0...mic.count {
            let inRun = i < mic.count && echoes[i]
            if !inRun {
                if i - runStart >= minRun {
                    for j in runStart..<i { keep[j] = false }
                }
                runStart = i + 1
            }
        }
        return zip(mic, keep).compactMap { $1 ? $0 : nil }
    }

    static func normalizedKey(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func lowerBound(_ values: [TimeInterval], _ target: TimeInterval) -> Int {
        var lo = 0
        var hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
