import AppIntents
import Foundation
import LidIAKit

/// Someone the user has met in recorded meetings. Not a contact: people come
/// from meeting invites and notes, keyed by email when there is one.
public struct PersonEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Person",
        numericFormat: "\(placeholder: .int) people"
    )
    public static let defaultQuery = PersonEntityQuery()

    /// The email when known, else "name:" and the folded name.
    public let id: String

    @Property(title: "Name") // siri-27.3: @Property(title: "Name", description: "The person's name as it appears in meeting invites.")
    public var name: String

    @Property(title: "Email") // siri-27.3: @Property(title: "Email", description: "The person's email address, when an invite had one.")
    public var email: String?

    @Property(title: "Meetings Together") // siri-27.3: @Property(title: "Meetings Together", description: "How many recorded meetings the user had with this person.")
    public var meetingCount: Int

    @Property(title: "Last Met") // siri-27.3: @Property(title: "Last Met", description: "The date of the latest meeting with this person.")
    public var lastMet: Date?

    public init(summary: SiriPersonSummary) {
        id = summary.id
        name = summary.name
        email = summary.email
        meetingCount = summary.meetingCount
        lastMet = summary.lastMet
    }

    public var displayRepresentation: DisplayRepresentation {
        let meetings = meetingCount == 1 ? "1 meeting" : "\(meetingCount) meetings"
        return DisplayRepresentation(
            title: "\(name.isEmpty ? (email ?? id) : name)",
            subtitle: "\(email.map { "\($0) · " } ?? "")\(meetings)",
            image: .init(systemName: "person.crop.circle")
        )
    }
}

/// Everyone in the library (it's small), by id, or by part of a name or email.
public struct PersonEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    public init() {}

    public static var findIntentDescription: IntentDescription? {
        IntentDescription("Finds people the user has met in recorded meetings, by name or email.")
    }

    @MainActor
    static func all() throws -> [SiriPersonSummary] {
        SiriLibrary.people(from: try SiriStore.meetingRecords(in: try LidIASiri.context(), includeSearchText: false))
    }

    public func allEntities() async throws -> [PersonEntity] {
        try await MainActor.run { try Self.all().prefix(300).map(PersonEntity.init(summary:)) }
    }

    public func entities(for identifiers: [String]) async throws -> [PersonEntity] {
        try await MainActor.run {
            let wanted = Set(identifiers)
            return try Self.all().filter { wanted.contains($0.id) }.map(PersonEntity.init(summary:))
        }
    }

    public func entities(matching string: String) async throws -> [PersonEntity] {
        try await MainActor.run {
            let folded = SiriText.fold(string)
            return try Self.all()
                .filter { SiriText.fold($0.name + " " + ($0.email ?? "")).contains(folded) }
                .prefix(20)
                .map(PersonEntity.init(summary:))
        }
    }

    public func suggestedEntities() async throws -> [PersonEntity] {
        try await MainActor.run { try Self.all().prefix(20).map(PersonEntity.init(summary:)) }
    }
}

/// A project: the folder the user files meetings in.
public struct ProjectEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Project",
        numericFormat: "\(placeholder: .int) projects"
    )
    public static let defaultQuery = ProjectEntityQuery()

    /// The folded project name.
    public let id: String

    @Property(title: "Name") // siri-27.3: @Property(title: "Name", description: "The project's name, as the user filed meetings under it.")
    public var name: String

    @Property(title: "Meetings") // siri-27.3: @Property(title: "Meetings", description: "How many meetings are in the project.")
    public var meetingCount: Int

    @Property(title: "Latest Meeting") // siri-27.3: @Property(title: "Latest Meeting", description: "The date of the project's most recent meeting.")
    public var lastMeeting: Date?

    public init(summary: SiriProjectSummary) {
        id = summary.id
        name = summary.name
        meetingCount = summary.meetingCount
        lastMeeting = summary.lastMeeting
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(meetingCount == 1 ? "1 meeting" : "\(meetingCount) meetings")",
            image: .init(systemName: "folder")
        )
    }
}

/// Every project, by id, or by part of the name.
public struct ProjectEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    public init() {}

    public static var findIntentDescription: IntentDescription? {
        IntentDescription("Finds the user's projects (the folders meetings are filed in) by name.")
    }

    @MainActor
    static func all() throws -> [SiriProjectSummary] {
        SiriLibrary.projects(from: try SiriStore.meetingRecords(in: try LidIASiri.context(), includeSearchText: false))
    }

    public func allEntities() async throws -> [ProjectEntity] {
        try await MainActor.run { try Self.all().map(ProjectEntity.init(summary:)) }
    }

    public func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        try await MainActor.run {
            let wanted = Set(identifiers)
            return try Self.all().filter { wanted.contains($0.id) }.map(ProjectEntity.init(summary:))
        }
    }

    public func entities(matching string: String) async throws -> [ProjectEntity] {
        try await MainActor.run {
            let folded = SiriText.fold(string)
            return try Self.all().filter { $0.id.contains(folded) }.map(ProjectEntity.init(summary:))
        }
    }

    public func suggestedEntities() async throws -> [ProjectEntity] {
        try await MainActor.run { try Self.all().prefix(20).map(ProjectEntity.init(summary:)) }
    }
}
