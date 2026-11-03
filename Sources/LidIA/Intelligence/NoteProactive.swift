import Foundation
import Observation

// MARK: - Auto title

/// Gives notes and recordings with a placeholder title a real one, written
/// from their content once the user pauses typing. Never touches a title
/// the user typed.
enum NoteAutoTitle {
    /// Placeholder titles (folded).
    static let placeholders: Set<String> = [
        "", "new note", "nueva nota", "untitled", "untitled note", "untitled meeting", "sin titulo",
        "new recording", "recording", "meeting", "quick note", "note", "meeting notes", "nueva grabacion",
    ]

    /// Fewer characters of content than this aren't worth a title.
    static let minimumContent = 16
    /// An AI title is rewritten once the content has grown this much.
    static let regrowthFactor = 2.0

    static func isPlaceholder(_ title: String) -> Bool {
        placeholders.contains(IntentText.fold(title.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Whether to (re)write the title now.
    static func shouldTitle(currentTitle: String, contentLength: Int, aiTitle: IntentStore.AITitle?, userTitled: Bool) -> Bool {
        guard !userTitled, contentLength >= minimumContent else { return false }
        if isPlaceholder(currentTitle) { return true }
        // Our own title, on a note that has since grown a lot: refresh it.
        if let aiTitle, aiTitle.title == currentTitle {
            return Double(contentLength) >= Double(max(1, aiTitle.contentLength)) * regrowthFactor + 40
        }
        return false
    }

    /// A title change the user made (not ours, not a placeholder).
    static func isUserEdit(newTitle: String, aiTitle: IntentStore.AITitle?) -> Bool {
        !isPlaceholder(newTitle) && newTitle != aiTitle?.title
    }

    static let systemPrompt = """
        You title notes in a notes app. Reply with ONLY the title: 3 to 6 words saying what the \
        note is about, in the note's language. Keep the one name or code that identifies it (in \
        parentheses if it helps); leave out amounts and other details. No quotes, no trailing \
        period, no words like "Note" or "Summary".
        """

    /// Cleans a model's reply into a title, or nil.
    static func clean(_ reply: String) -> String? {
        var title = ReasoningFilter.strip(reply)
            .components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*#.:"))
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !title.isEmpty, title.count <= 80, !isPlaceholder(title) else { return nil }
        return title
    }

    /// Asks the local route (Hybrid keeps titles on this Mac) for a title.
    @MainActor
    static func generate(content: String, settings: AppSettings, modelManager: ModelManager?) async -> String? {
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .actionItems)
        let model = effectiveModel(for: .query, settings: settings, taskType: .actionItems)
        guard !model.isEmpty else { return nil }
        let reply = try? await client.chat(
            messages: [
                LLMChatMessage(role: "system", content: systemPrompt),
                LLMChatMessage(role: "user", content: String(content.prefix(2_000))),
            ],
            model: model,
            format: nil
        )
        return reply.flatMap(clean)
    }
}

/// Runs an action once input has stopped changing for `delay`.
@MainActor
final class Debouncer {
    let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) { self.delay = delay }

    /// Restarts the wait; `action` runs only if nothing else arrives in time.
    func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let delay = delay
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Transcribe new notes

/// "Transcribe when I create a note".
enum NoteTranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case duringMeetings
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duringMeetings: "Automatically during meetings"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// Whether New Note starts transcribing, offers to, or stays a plain note.
enum NoteTranscriptionPolicy {
    enum Decision: Equatable {
        /// Start now, with a visible "Transcribing · Stop" chip.
        case start
        /// Show a one-tap "Start transcribing" chip.
        case offer
        case none
    }

    static func decide(mode: NoteTranscriptionMode, calendarMeetingNow: Bool, meetingAppOnMic: Bool, alreadyRecording: Bool) -> Decision {
        if alreadyRecording { return .none }
        switch mode {
        case .never: return .none
        case .always: return .start
        case .duringMeetings: return calendarMeetingNow || meetingAppOnMic ? .start : .offer
        }
    }
}

/// Notes that started transcribing from New Note, and notes offered the chip
/// (this session only).
@MainActor
@Observable
final class NoteTranscriptionState {
    static let shared = NoteTranscriptionState()
    var startedFromNote: Set<UUID> = []
    var offered: Set<UUID> = []
}
