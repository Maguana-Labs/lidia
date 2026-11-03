// STAGED for the Siri AI Developer Preview (Xcode 27.3 SDK). Not compiled until
// `scripts/siri-27.3.py enable` copies it into Packages/LidIAKit/Sources/
// LidIAAppIntents/Staged/. See docs/siri.md.

import AppIntents
import Foundation

/// A meeting search Siri can fill straight from the request ("my meetings
/// with Mateo about the Northwind contract since Monday"), without asking
/// LidIA's queries first. Find Meetings takes it as its "Search" parameter.
@AppEntity(.generable)
public struct MeetingSearchRequest: TransientAppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meeting Search"

    @Property(title: "Person", description: "Someone who was in the meeting, by name or email, as the user said it.")
    public var person: String?

    @Property(title: "Project", description: "The project the meetings are filed in, as the user said it.")
    public var project: String?

    @Property(title: "Words", description: "What the meetings were about: a company, topic or phrase.")
    public var keyword: String?

    @Property(title: "From", description: "The earliest meeting date to include.")
    public var from: Date?

    @Property(title: "To", description: "The latest meeting date to include; the whole day counts.")
    public var to: Date?

    public var displayRepresentation: DisplayRepresentation {
        let parts = [person.map { "with \($0)" }, project.map { "in \($0)" }, keyword.map { "about \($0)" }].compactMap { $0 }
        return DisplayRepresentation(title: "\(parts.isEmpty ? "Meetings" : "Meetings " + parts.joined(separator: " "))")
    }

    public init() {}

    /// Fills in what the explicit parameters left empty.
    func merged(into search: SiriMeetingSearch) -> SiriMeetingSearch {
        var merged = search
        if merged.person == nil { merged.person = person }
        if merged.project == nil { merged.project = project }
        if merged.keyword == nil { merged.keyword = keyword }
        if merged.from == nil { merged.from = from }
        if merged.to == nil { merged.to = to }
        return merged
    }
}
