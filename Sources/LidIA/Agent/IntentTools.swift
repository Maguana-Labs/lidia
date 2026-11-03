import Foundation
import SwiftData

/// What the intent tools read and what they drafted, for one run. Drafting
/// tools only write here: nothing is sent or changed.
@MainActor
final class IntentToolBox {
    struct Draft: Equatable, Sendable {
        var channel: String
        var to: String?
        var subject: String
        var body: String
    }

    struct EventChange: Equatable, Sendable {
        var eventID: String
        var start: Date
        var end: Date
    }

    /// Meeting ID → speaker turns.
    var turns: [UUID: [TranscriptTurn]] = [:]
    var meetingStarts: [UUID: Date] = [:]
    var calendar: (any IntentCalendarSource)?
    var userName = ""
    var now: Date = .now
    private(set) var drafts: [Draft] = []
    private(set) var eventChanges: [EventChange] = []

    func record(_ draft: Draft) { drafts.append(draft) }
    func record(_ change: EventChange) { eventChanges.append(change) }

    /// Turns for a meeting, read from the library when not given.
    func turns(for meeting: Meeting) -> [TranscriptTurn] {
        if let cached = turns[meeting.id] { return cached }
        let words = meeting.rawTranscript
        let built = words.isEmpty
            ? TranscriptTimeline.turns(fromText: LidIATools.transcriptText(meeting), userName: userName)
            : TranscriptTimeline.turns(from: words, userName: userName)
        turns[meeting.id] = built
        meetingStarts[meeting.id] = meeting.date
        return built
    }
}

/// Agent tools for preparing an action item's next step: find the moment
/// it was said, find free time, and draft (never send) a message or a
/// calendar change. Additive to `LidIATools`; offered only in intent runs.
@MainActor
enum IntentTools {
    static func all(box: IntentToolBox) -> AgentToolRegistry {
        AgentToolRegistry([findEvidence(box), findFreeSlots(box), proposeEventChange(box), draftMessage(box)])
    }

    // MARK: - find_evidence

    static func findEvidence(_ box: IntentToolBox) -> AgentTool {
        AgentTool(
            spec: AgentToolSpec(
                name: "find_evidence",
                description: "Find where something was said in a meeting's transcript: quotes with speaker and time.",
                parameters: [
                    AgentParameter(name: "query", kind: .string, description: "What was said, in a few words", required: true),
                    AgentParameter(name: "meeting_id", kind: .string, description: "The meeting's id", required: true),
                ]
            ),
            effect: .readOnly
        ) { arguments, context in
            guard let meeting = LidIATools.findMeeting(arguments.string("meeting_id") ?? "", in: context.modelContext) else {
                return AgentToolOutput("No meeting with that id.")
            }
            let turns = box.turns(for: meeting)
            let matches = EvidenceMatcher.matches(for: arguments.string("query") ?? "", in: turns, limit: 3)
            guard !matches.isEmpty else { return AgentToolOutput("Nothing in the transcript matches.", resultCount: 0) }
            let lines = matches.map { match in
                let time = match.turn.start.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "?"
                let who = match.turn.isUser == true ? "\(match.turn.speaker ?? "Me") (the user)" : (match.turn.speaker ?? "unknown speaker")
                return "[\(time)] \(who): \"\(match.quote)\" (match \(Int(match.score * 100))%)"
            }
            return AgentToolOutput(lines.joined(separator: "\n"), meetings: [LidIATools.ref(meeting, excerpt: nil)], resultCount: matches.count)
        }
    }

    // MARK: - find_free_slots

    static func findFreeSlots(_ box: IntentToolBox) -> AgentTool {
        AgentTool(
            spec: AgentToolSpec(
                name: "find_free_slots",
                description: "Free times in the user's calendar (weekdays, 9:00-18:00).",
                parameters: [
                    AgentParameter(name: "duration_minutes", kind: .integer, description: "Length of the meeting", required: true),
                    AgentParameter(name: "from", kind: .date, description: "First day to search (default tomorrow)"),
                    AgentParameter(name: "to", kind: .date, description: "Last day to search (default a week later)"),
                    AgentParameter(name: "avoid_day", kind: .date, description: "A day to leave free"),
                ]
            ),
            effect: .readOnly
        ) { arguments, _ in
            guard let source = box.calendar, source.isAvailable else {
                return AgentToolOutput("The calendar isn't available to LidIA.")
            }
            let calendar = Calendar.current
            let from = arguments.date("from") ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: box.now))!
            let to = arguments.date("to").map { calendar.date(byAdding: .day, value: 1, to: $0)! } ?? calendar.date(byAdding: .day, value: 7, to: from)!
            let busy = source.events(from: from, to: to).filter { !$0.isAllDay }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            let slots = SlotFinder.freeSlots(
                busy: busy,
                duration: TimeInterval(max(15, arguments.integer("duration_minutes") ?? 30) * 60),
                from: max(from, box.now), to: to,
                avoidDays: arguments.date("avoid_day").map { [$0] } ?? []
            )
            guard !slots.isEmpty else { return AgentToolOutput("No free time in that range.", resultCount: 0) }
            return AgentToolOutput(slots.map { "- \(slotLine($0))" }.joined(separator: "\n"), resultCount: slots.count)
        }
    }

    // MARK: - propose_event_change

    static func proposeEventChange(_ box: IntentToolBox) -> AgentTool {
        AgentTool(
            spec: AgentToolSpec(
                name: "propose_event_change",
                description: "Draft moving a calendar event to a new time. Nothing changes until the user confirms.",
                parameters: [
                    AgentParameter(name: "event_id", kind: .string, description: "The event's id", required: true),
                    AgentParameter(name: "start", kind: .string, description: "New start, YYYY-MM-DD HH:MM", required: true),
                    AgentParameter(name: "duration_minutes", kind: .integer, description: "Length (default: unchanged)"),
                ]
            ),
            effect: .proposal
        ) { arguments, _ in
            guard let start = parseDateTime(arguments.string("start") ?? "") else {
                return AgentToolOutput("Give start as YYYY-MM-DD HH:MM.")
            }
            let eventID = arguments.string("event_id") ?? ""
            let current = box.calendar?.events(from: box.now.addingTimeInterval(-86_400), to: box.now.addingTimeInterval(30 * 86_400)).first { $0.id == eventID }
            let length = arguments.integer("duration_minutes").map { TimeInterval($0 * 60) } ?? current.map { $0.end.timeIntervalSince($0.start) } ?? 1800
            box.record(IntentToolBox.EventChange(eventID: eventID, start: start, end: start.addingTimeInterval(length)))
            return AgentToolOutput("Drafted: move \(current?.title ?? "the event") to \(slotLine(ActionIntent.Slot(start: start, end: start.addingTimeInterval(length)))). It happens only when the user confirms.")
        }
    }

    // MARK: - draft_message

    static func draftMessage(_ box: IntentToolBox) -> AgentTool {
        AgentTool(
            spec: AgentToolSpec(
                name: "draft_message",
                description: "Save a draft message, page or ticket for the user to review. Nothing is sent.",
                parameters: [
                    AgentParameter(name: "channel", kind: .oneOf(["email", "slack", "notion", "ticket", "reminder"]), description: "Where it will go", required: true),
                    AgentParameter(name: "to", kind: .string, description: "Recipient names"),
                    AgentParameter(name: "subject", kind: .string, description: "Subject or title", required: true),
                    AgentParameter(name: "body", kind: .string, description: "The full text, ready to send", required: true),
                ]
            ),
            effect: .proposal
        ) { arguments, _ in
            let draft = IntentToolBox.Draft(
                channel: arguments.string("channel") ?? "email",
                to: arguments.string("to"),
                subject: arguments.string("subject") ?? "",
                body: arguments.string("body") ?? ""
            )
            guard !draft.body.isEmpty else { return AgentToolOutput("The draft needs a body.") }
            box.record(draft)
            return AgentToolOutput("Draft saved for the user to review. Reply \"done\".")
        }
    }

    // MARK: - Helpers

    static func slotLine(_ slot: ActionIntent.Slot, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        let end = DateFormatter()
        end.locale = formatter.locale
        end.timeZone = calendar.timeZone
        end.dateFormat = "HH:mm"
        return "\(formatter.string(from: slot.start))-\(end.string(from: slot.end))"
    }

    static func parseDateTime(_ text: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }
}
