import Foundation
import SwiftData

/// Shared talking point model for the iOS and watchOS apps.
/// Mirrors `Sources/LidIA/Models/TalkingPoint.swift`; keep the two in step.
@Model
public final class TalkingPoint {
    public var id: UUID = UUID()
    public var personIdentifier: String = ""
    public var content: String = ""
    public var createdDate: Date = Date.now
    public var isUsed: Bool = false

    public init(
        personIdentifier: String,
        content: String,
        createdDate: Date = .now,
        isUsed: Bool = false
    ) {
        self.id = UUID()
        self.personIdentifier = personIdentifier
        self.content = content
        self.createdDate = createdDate
        self.isUsed = isUsed
    }
}
