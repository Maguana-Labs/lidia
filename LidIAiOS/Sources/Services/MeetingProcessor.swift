import Foundation
import LidIAIntelligence
import LidIAKit
import Observation
import SwiftData
import os

/// Writes notes, a title and action items for a meeting after it's recorded,
/// streaming the notes so the UI can show them as they're written.
@MainActor
@Observable
final class MeetingProcessor {
    enum Phase: Equatable {
        case waiting
        case condensing(part: Int, of: Int)
        case writing
        case extracting
        case done
        case failed(String)

        var label: String {
            switch self {
            case .waiting: "Getting ready"
            case .condensing(let part, let total): "Reading part \(part) of \(total)"
            case .writing: "Writing notes"
            case .extracting: "Finding action items"
            case .done: "Notes ready"
            case .failed: "Couldn't write notes"
            }
        }
    }

    struct Progress: Equatable {
        var phase: Phase = .waiting
        var text = ""
    }

    private static let logger = Logger(subsystem: "io.lidia.ios", category: "MeetingProcessor")

    private let intelligence: Intelligence
    private(set) var progress: [UUID: Progress] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Called when a meeting finishes, to push it to the Mac.
    var onFinished: ((Meeting) -> Void)?
    /// Called when notes fail, to close the Live Activity.
    var onFailed: ((UUID) -> Void)?

    init(intelligence: Intelligence) {
        self.intelligence = intelligence
    }

    func isProcessing(_ id: UUID) -> Bool { tasks[id] != nil }

    func process(_ meeting: Meeting, in context: ModelContext) {
        let id = meeting.id
        guard tasks[id] == nil else { return }
        let transcript = meeting.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            meeting.status = .failed
            meeting.processingError = "Nothing was transcribed. The audio is saved; check the microphone and try again."
            try? context.save()
            progress[id] = Progress(phase: .failed(meeting.processingError ?? ""))
            return
        }

        let generator: any TextGenerator
        do {
            generator = try intelligence.generator()
        } catch {
            meeting.status = .failed
            meeting.processingError = error.localizedDescription
            try? context.save()
            progress[id] = Progress(phase: .failed(error.localizedDescription))
            return
        }

        meeting.status = .processing
        meeting.processingError = nil
        try? context.save()
        progress[id] = Progress()
        let attendees = meeting.attendeeNames

        tasks[id] = Task { [weak self] in
            let pipeline = MeetingNotesPipeline(generator: generator)
            do {
                let result = try await pipeline.run(
                    transcript: transcript,
                    attendees: attendees.isEmpty ? nil : attendees,
                    onPhase: { phase in
                        await MainActor.run {
                            self?.progress[id]?.phase = switch phase {
                            case .condensing(let part, let total): .condensing(part: part, of: total)
                            case .writing: .writing
                            case .extracting: .extracting
                            }
                        }
                    },
                    onText: { text in
                        await MainActor.run { self?.progress[id]?.text += text }
                    },
                    onReset: {
                        await MainActor.run { self?.progress[id]?.text = "" }
                    }
                )
                self?.apply(result, to: meeting, in: context)
            } catch {
                Self.logger.error("Notes failed: \(error.localizedDescription, privacy: .public)")
                meeting.status = .failed
                meeting.processingError = error.localizedDescription
                meeting.processingRetryCount += 1
                try? context.save()
                self?.progress[id]?.phase = .failed(error.localizedDescription)
                self?.onFailed?(id)
            }
            self?.tasks[id] = nil
        }
    }

    private func apply(_ result: MeetingNotesResult, to meeting: Meeting, in context: ModelContext) {
        meeting.summary = result.markdown
        meeting.userEditedSummary = nil
        // A title the user typed or the calendar gave wins over the model's.
        if meeting.title.trimmingCharacters(in: .whitespaces).isEmpty, !result.title.isEmpty {
            meeting.title = result.title
        }

        // Keep what the user completed, edited or added; replace untouched AI items.
        let untouched = meeting.actionItems.filter { item in
            !item.isCompleted && item.aiFingerprint == ActionItem.fingerprint(title: item.title, assignee: item.assignee, deadline: item.deadline)
        }
        for item in untouched {
            meeting.actionItems.removeAll { $0.id == item.id }
            context.delete(item)
        }
        let kept = Set(meeting.actionItems.map { $0.title.lowercased() })
        for extracted in result.actionItems where !kept.contains(extracted.title.lowercased()) {
            let item = ActionItem(title: extracted.title, assignee: extracted.assignee, deadline: extracted.deadline)
            item.deadlineDate = extracted.deadline.flatMap { DeadlineParser.date(from: $0, relativeTo: meeting.date) }
            item.sourceQuote = extracted.sourceQuote
            item.aiFingerprint = ActionItem.fingerprint(title: item.title, assignee: item.assignee, deadline: item.deadline)
            item.meeting = meeting
            context.insert(item)
            meeting.actionItems.append(item)
        }
        meeting.status = .complete
        meeting.processingError = nil
        try? context.save()
        progress[meeting.id]?.phase = .done
        onFinished?(meeting)
    }
}

/// "Friday", "next Tuesday", "Nov 14" → a date, when the text names one.
enum DeadlineParser {
    static func date(from text: String, relativeTo reference: Date) -> Date? {
        let lowered = text.lowercased()
        let calendar = Calendar.current
        if lowered.contains("today") || lowered.contains("hoy") { return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: reference) }
        if lowered.contains("tomorrow") || lowered.contains("mañana") {
            return calendar.date(byAdding: .day, value: 1, to: calendar.date(bySettingHour: 18, minute: 0, second: 0, of: reference) ?? reference)
        }
        if lowered.contains("end of week") || lowered.contains("eow") {
            return nextWeekday(6, after: reference)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in weekdays.enumerated() where lowered.contains(name) {
            return nextWeekday(index + 1, after: reference)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.date
    }

    private static func nextWeekday(_ weekday: Int, after reference: Date) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = 18
        return Calendar.current.nextDate(after: reference, matching: components, matchingPolicy: .nextTime)
    }
}
