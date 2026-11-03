import Foundation
import SwiftData

/// An action item from a meeting. Shared by every app; see `Meeting` for the
/// CloudKit rules every model follows.
@Model
public final class ActionItem {
    public var id: UUID = UUID()
    public var title: String = ""
    public var assignee: String?
    public var deadline: String?
    public var deadlineDate: Date?
    public var isCompleted: Bool = false
    public var notionBlockID: String?
    public var notionTaskPageID: String?
    public var reminderID: String?
    /// Verbatim quote from transcript that sourced this action item. Used for transcript linking.
    public var sourceQuote: String?
    /// Priority: "critical", "high", "medium", "low", "none"
    public var priority: String = "none"
    /// LLM-suggested destination: "clickup", "notion", "reminder", "n8n", "none"
    public var suggestedDestination: String?
    /// User-confirmed destination (same values as suggestedDestination)
    public var confirmedDestination: String?
    /// Snapshot of the item's user-editable fields taken when the AI pipeline created it.
    /// `nil` for items the user (or sync/voice) created. If the current fields no longer
    /// match, the user has touched the item and Regenerate must keep it. It syncs with the
    /// item, so an edit made on another device also marks the item as the user's.
    /// See `ActionItem.isUntouchedAIItem` in the Mac's `Pipeline/ActionItemProvenance.swift`.
    public var aiFingerprint: String? = nil
    /// Board column for open items: "todo", "inProgress" or "waiting" (see
    /// `ActionItemStatus`). `isCompleted` stays the source of truth for done:
    /// read and write the column through `boardStatus`, which keeps both in step.
    public var workflowStatus: String = "todo"
    /// Inverse of `Meeting.actionItemsStorage`.
    public var meeting: Meeting?

    public init(
        title: String,
        assignee: String? = nil,
        deadline: String? = nil,
        deadlineDate: Date? = nil,
        isCompleted: Bool = false,
        notionBlockID: String? = nil,
        notionTaskPageID: String? = nil,
        reminderID: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.assignee = assignee
        self.deadline = deadline
        self.deadlineDate = deadlineDate
        self.isCompleted = isCompleted
        self.notionBlockID = notionBlockID
        self.notionTaskPageID = notionTaskPageID
        self.reminderID = reminderID
    }

    public var isAutoUrgent: Bool {
        guard let deadlineDate, !isCompleted else { return false }
        return deadlineDate.timeIntervalSinceNow <= 48 * 3600
    }

    /// True for critical/high priority or auto-urgent (deadline ≤48h)
    public var isUrgent: Bool {
        priority == "critical" || priority == "high" || isAutoUrgent
    }

    public var priorityLevel: Int {
        switch priority {
        case "critical": 4
        case "high": 3
        case "medium": 2
        case "low": 1
        default: 0
        }
    }

    public var displayDeadline: String? {
        if let deadlineDate {
            return Self.formattedDeadline(from: deadlineDate)
        }
        guard let trimmed = deadline?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        // Models sometimes write a JSON null as text; older items kept it.
        return ["null", "none", "n/a", "unknown"].contains(trimmed.lowercased()) ? nil : trimmed
    }

    public func setPreciseDeadline(_ date: Date?) {
        deadlineDate = date
        deadline = date.map(Self.formattedDeadline(from:))
    }

    public static func formattedDeadline(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    #Index<ActionItem>([\.isCompleted])
}

/// The Kanban column of an action item.
public enum ActionItemStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case todo
    case inProgress
    case waiting
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .waiting: "Waiting"
        case .done: "Done"
        }
    }

    public var systemImage: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .waiting: "hourglass"
        case .done: "checkmark.circle.fill"
        }
    }

    /// The column for a stored status and completion flag. A completed item is
    /// always done (other code and sync only know `isCompleted`); a reopened item
    /// goes back to the column it was in, or To Do.
    public static func resolve(stored: String, isCompleted: Bool) -> ActionItemStatus {
        if isCompleted { return .done }
        let status = ActionItemStatus(rawValue: stored) ?? .todo
        return status == .done ? .todo : status
    }
}

extension ActionItem {
    /// The board column, kept in step with `isCompleted`.
    public var boardStatus: ActionItemStatus {
        get { ActionItemStatus.resolve(stored: workflowStatus, isCompleted: isCompleted) }
        set {
            if workflowStatus != newValue.rawValue { workflowStatus = newValue.rawValue }
            let done = newValue == .done
            if isCompleted != done { isCompleted = done }
        }
    }
}
