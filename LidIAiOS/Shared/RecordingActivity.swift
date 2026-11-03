import ActivityKit
import AppIntents
import Foundation

/// The recording Live Activity (Lock Screen + Dynamic Island).
///
/// iOS-only for now; the Mac's Live Activity attributes live elsewhere and the
/// two will be unified later.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            case paused
            case saving
            case saved
        }

        var phase: Phase
        /// `now - elapsed` while recording, so `Text(timerInterval:)` ticks on its own.
        var timerAnchor: Date
        /// Elapsed seconds, shown frozen while paused or saved.
        var elapsed: TimeInterval
        /// The latest transcript line, already trimmed for the island.
        var lastLine: String
    }

    var title: String
    var meetingID: UUID
}

extension RecordingActivityAttributes.ContentState {
    var isLive: Bool { phase == .recording }

    var elapsedText: String {
        let total = Int(elapsed.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Intents (buttons in the Live Activity)

/// Routes Live Activity buttons to the recorder. The intents run in the app's
/// process (`LiveActivityIntent`), where the recorder installs `handler`.
@MainActor
enum RecordingIntentBridge {
    enum Command: Sendable {
        case pause
        case resume
        case stop
        /// Mark the current moment.
        case bookmark
        /// Add a line to the live meeting's notes.
        case note(String)
    }

    /// Returns false when nothing is recording (the command did nothing).
    static var handler: ((Command) -> Bool)?

    @discardableResult
    static func send(_ command: Command) -> Bool {
        handler?(command) ?? false
    }
}

/// What Siri says when there's no recording to act on. (The widget extension
/// doesn't link LidIAKit, so this can't use the shared intents' errors.)
struct NotRecordingError: Error, LocalizedError {
    var errorDescription: String? { "LidIA isn't recording a meeting right now." }
}

struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Recording"
    static let description = IntentDescription("Pauses the meeting LidIA is recording.")

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.send(.pause)
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    static let description = IntentDescription("Resumes the paused meeting recording.")

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.send(.resume)
        return .result()
    }
}

// siri-27.3: @AppIntent(.tool)
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the meeting LidIA is recording on this iPhone, then writes the notes and action items on the iPhone.")

    init() {}

    func perform() async throws -> some IntentResult {
        guard await RecordingIntentBridge.send(.stop) else { throw NotRecordingError() }
        return .result()
    }
}

/// "Bookmark this" while recording: works from Siri without naming the app
/// while the recording Live Activity is up.
// siri-27.3: @AppIntent(.tool)
struct BookmarkMomentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Bookmark This Moment"
    static let description = IntentDescription("Marks the current moment in the meeting LidIA is recording, so it's easy to find in the notes later.")

    init() {}

    func perform() async throws -> some IntentResult {
        guard await RecordingIntentBridge.send(.bookmark) else { throw NotRecordingError() }
        return .result()
    }
}

/// "Note that we agreed on Friday" while recording.
// siri-27.3: @AppIntent(.tool)
struct AddMeetingNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add Note to Live Meeting"
    static let description = IntentDescription("Adds a line to the notes of the meeting LidIA is recording, stamped with the time in the recording.")

    @Parameter(title: "Note", description: "What to write down, in the user's words.", requestValueDialog: "What should I write down?")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to the live meeting's notes")
    }

    func perform() async throws -> some IntentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw $text.needsValueError("What should I write down?") }
        guard await RecordingIntentBridge.send(.note(trimmed)) else { throw NotRecordingError() }
        return .result()
    }
}
