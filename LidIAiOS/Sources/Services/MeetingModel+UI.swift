import Foundation
import LidIAKit
import SwiftUI

extension Meeting {
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }

    /// Notes as the user sees them: their edit if any, else the AI's.
    var summaryText: String {
        if let edited = userEditedSummary, !edited.isEmpty { return edited }
        return summary
    }

    var transcriptText: String {
        if let edited = userEditedTranscript, !edited.isEmpty { return edited }
        if !refinedTranscript.isEmpty { return refinedTranscript }
        return rawTranscript.map(\.word).joined(separator: " ")
    }

    var attendeeNames: [String] {
        (calendarAttendees ?? []).map(Format.displayName)
    }

    var openItems: [ActionItem] {
        actionItems.filter { !$0.isCompleted }.sorted { ($0.deadlineDate ?? .distantFuture) < ($1.deadlineDate ?? .distantFuture) }
    }

    /// Recorded on this iPhone. `audioFilePath` alone isn't enough: with iCloud sync a
    /// Mac meeting arrives with the Mac's path, so the meeting must also be this device's.
    var recordedOnThisDevice: Bool { audioFilePath != nil && isOwnedByThisDevice }

    var audioURL: URL? {
        guard recordedOnThisDevice, let audioFilePath else { return nil }
        let url = AudioStorage.url(forStoredPath: audioFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Recurring meetings share a normalised title ("Weekly sync #12" → "weekly sync").
    var seriesKey: String { Self.seriesKey(for: displayTitle) }

    static func seriesKey(for title: String) -> String {
        let lowered = title.lowercased()
        let cleaned = lowered
            .replacingOccurrences(of: #"#\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{1,2}[/.-]\d{1,2}([/.-]\d{2,4})?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    var tint: Color {
        Tint.color(for: folder ?? seriesKey)
    }

    var symbol: String {
        switch status {
        case .recording: return "record.circle"
        case .processing, .queued: return "sparkles"
        case .failed: return "exclamationmark.triangle.fill"
        case .complete: break
        }
        let count = calendarAttendees?.count ?? 0
        if count == 0 { return recordedOnThisDevice ? "mic.fill" : "waveform" }
        if count <= 2 { return "person.2.fill" }
        return "person.3.fill"
    }

    /// "42 min · 3 to do"
    var detailLine: String {
        var parts: [String] = []
        switch status {
        case .recording: parts.append("Recording")
        case .processing, .queued: parts.append("Writing notes…")
        case .failed: parts.append("Notes need attention")
        case .complete:
            if duration > 0 { parts.append(Format.duration(duration)) }
            let open = openItems.count
            if open > 0 { parts.append("\(open) to do") }
            if let folder, !folder.isEmpty { parts.append(folder) }
        }
        return parts.joined(separator: " · ")
    }

    var timeLabel: String {
        Calendar.current.isDateInToday(date) ? Format.time(date) : Format.day(date)
    }
}

extension ActionItem {
    enum Due: Int, Comparable {
        case overdue, today, thisWeek, later, none

        static func < (lhs: Due, rhs: Due) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .thisWeek: "This week"
            case .later: "Later"
            case .none: "No date"
            }
        }
    }

    var due: Due {
        guard let deadlineDate else { return .none }
        let calendar = Calendar.current
        if deadlineDate < calendar.startOfDay(for: .now) { return .overdue }
        if calendar.isDateInToday(deadlineDate) { return .today }
        if let week = calendar.dateInterval(of: .weekOfYear, for: .now), week.contains(deadlineDate) { return .thisWeek }
        return .later
    }

    var dueLabel: String? {
        guard let deadlineDate else { return displayDeadline }
        switch due {
        case .overdue:
            let days = Calendar.current.dateComponents([.day], from: deadlineDate, to: .now).day ?? 0
            return days <= 1 ? "Yesterday" : "\(days) days late"
        case .today: return "Today"
        default: return Format.day(deadlineDate)
        }
    }

    var dueTint: Color {
        switch due {
        case .overdue: .red
        case .today: .orange
        default: .secondary
        }
    }

    /// Days since the meeting that produced it.
    var ageInDays: Int {
        guard let meeting else { return 0 }
        return Calendar.current.dateComponents([.day], from: meeting.date, to: .now).day ?? 0
    }

    static func fingerprint(title: String, assignee: String?, deadline: String?) -> String {
        [title, assignee ?? "", deadline ?? ""].joined(separator: "|")
    }
}

/// Where recordings live: Documents/Recordings, stored as relative paths so
/// they survive container moves (reinstalls, restores).
enum AudioStorage {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newRecordingURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).caf")
    }

    static func storedPath(for url: URL) -> String {
        "Recordings/" + url.lastPathComponent
    }

    static func url(forStoredPath path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(path)
    }
}
