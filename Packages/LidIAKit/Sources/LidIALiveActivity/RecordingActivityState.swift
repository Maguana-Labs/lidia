import Foundation

/// What a recording shows outside the main window (the menu bar panel today, a Live
/// Activity once ActivityKit is available on macOS). Shaped like an ActivityKit
/// `ContentState`: plain Codable values, display-ready, and nothing that changes every
/// second (a live level meter is drawn by the panel from the session, and can't be part
/// of a Live Activity within its update budget). The elapsed time is a `timerStart` the view counts from
/// (`Text(timerInterval:pauseTime:)`), so a running timer needs no updates.
public struct RecordingActivityState: Codable, Hashable, Sendable {
    /// The latest utterance of the live transcript.
    public struct Line: Codable, Hashable, Sendable {
        public var text: String
        /// Said on this Mac's microphone (you), rather than by the others.
        public var isLocal: Bool

        public init(text: String, isLocal: Bool) {
            self.text = text
            self.isLocal = isLocal
        }
    }

    public var title: String
    /// When the elapsed counter reads zero. Pauses push it forward, so
    /// `now - timerStart` is the recorded time while running.
    public var timerStart: Date
    /// The frozen elapsed time while paused; nil while recording.
    public var pausedElapsed: TimeInterval?
    public var lastLine: Line?
    /// The first problem worth knowing about, as one plain sentence.
    public var warning: String?
    /// Why live words aren't appearing (engine switched, model downloading).
    public var transcriptNotice: String?

    public init(
        title: String,
        timerStart: Date,
        pausedElapsed: TimeInterval? = nil,
        lastLine: Line? = nil,
        warning: String? = nil,
        transcriptNotice: String? = nil
    ) {
        self.title = title
        self.timerStart = timerStart
        self.pausedElapsed = pausedElapsed
        self.lastLine = lastLine
        self.warning = warning
        self.transcriptNotice = transcriptNotice
    }

    public static let untitled = "Untitled Meeting"
    /// Longest last line shown; longer ones keep their end (the newest words).
    public static let lineLimit = 120

    public var isPaused: Bool { pausedElapsed != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        pausedElapsed ?? max(0, now.timeIntervalSince(timerStart))
    }

    /// For `Text(timerInterval:pauseTime:countsDown: false)`.
    public var timerInterval: ClosedRange<Date> { timerStart...Date.distantFuture }

    /// Where the timer stops while paused.
    public var pauseTime: Date? { pausedElapsed.map { timerStart.addingTimeInterval($0) } }

    /// Builds the state from a recording's current values. `previous` keeps `timerStart`
    /// steady: a fresh `now - elapsed` drifts by a fraction of a second on every call,
    /// which would make every state "new" and cost an update.
    public static func make(
        title: String,
        elapsed: TimeInterval,
        isPaused: Bool,
        lastLine: Line?,
        warning: String?,
        transcriptNotice: String?,
        now: Date,
        previous: RecordingActivityState?
    ) -> RecordingActivityState {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = now.addingTimeInterval(-max(0, elapsed))
        if let previous, !previous.isPaused, !isPaused,
           abs(previous.timerStart.timeIntervalSince(start)) < 1.5 {
            start = previous.timerStart
        } else if isPaused, let previous, previous.isPaused, let frozen = previous.pausedElapsed,
                  abs(frozen - elapsed) < 0.5 {
            start = previous.timerStart
        }
        let line = lastLine.flatMap { line -> Line? in
            let text = clip(line.text)
            return text.isEmpty ? nil : Line(text: text, isLocal: line.isLocal)
        }
        return RecordingActivityState(
            title: trimmed.isEmpty ? untitled : trimmed,
            timerStart: start,
            pausedElapsed: isPaused ? max(0, elapsed) : nil,
            lastLine: line,
            warning: warning,
            transcriptNotice: transcriptNotice
        )
    }

    /// The end of `text` (the newest words), cut at a word boundary, with a leading "…".
    public static func clip(_ text: String, limit: Int = lineLimit) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let tail = collapsed.suffix(limit)
        let cut = tail.firstIndex(of: " ").map { tail[tail.index(after: $0)...] } ?? tail
        return "…" + cut
    }
}
