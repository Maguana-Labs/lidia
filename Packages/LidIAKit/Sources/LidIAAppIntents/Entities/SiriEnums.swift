import AppIntents
import LidIAKit

/// Where a meeting is: recording, being written up, ready, or failed.
public enum MeetingStateAppEnum: String, AppEnum {
    case recording, processing, ready, failed

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meeting Status"
    public static let caseDisplayRepresentations: [MeetingStateAppEnum: DisplayRepresentation] = [
        .recording: "Recording",
        .processing: "Writing notes",
        .ready: "Notes ready",
        .failed: "Needs attention",
    ]

    public init(_ state: SiriMeetingState) {
        self = MeetingStateAppEnum(rawValue: state.rawValue) ?? .ready
    }
}

/// An action item's column: to do, in progress, waiting on someone, or done.
public enum ActionItemStateAppEnum: String, AppEnum {
    case todo, inProgress, waiting, done

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action Item Status"
    public static let caseDisplayRepresentations: [ActionItemStateAppEnum: DisplayRepresentation] = [
        .todo: "To do",
        .inProgress: "In progress",
        .waiting: "Waiting",
        .done: "Done",
    ]

    public init(_ status: ActionItemStatus) {
        self = ActionItemStateAppEnum(rawValue: status.rawValue) ?? .todo
    }
}

/// Whose action items to list.
public enum ActionItemOwnerAppEnum: String, AppEnum {
    case mine, everyone

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Owner"
    public static let caseDisplayRepresentations: [ActionItemOwnerAppEnum: DisplayRepresentation] = [
        .mine: "Mine",
        .everyone: "Everyone's",
    ]
}
