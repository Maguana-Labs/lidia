import Foundation
import SwiftData

// MARK: - Chat persistence (Ask threads)

/// A saved Ask conversation. Written by the Mac; part of the shared schema so the
/// library syncs as one CloudKit store.
///
/// `id` used to carry a unique constraint. CloudKit doesn't support those, so callers
/// look a thread up by `id` before inserting (see the Mac's `ChatThreadStore`).
@Model
public final class ChatThreadModel {
    public var id: UUID = UUID()
    public var title: String = ""
    public var scopeRawValue: String = "All meetings"
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    /// The stored relationship (optional for CloudKit); use `messages`.
    @Relationship(deleteRule: .cascade, originalName: "messages", inverse: \ChatMessageModel.thread)
    public var messagesStorage: [ChatMessageModel]? = []

    public var messages: [ChatMessageModel] {
        get { messagesStorage ?? [] }
        set { messagesStorage = newValue }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        scopeRawValue: String = "All meetings",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ChatMessageModel] = []
    ) {
        self.id = id
        self.title = title
        self.scopeRawValue = scopeRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messagesStorage = messages
    }
}

@Model
public final class ChatMessageModel {
    public var id: UUID = UUID()
    public var role: String = "user"
    public var content: String = ""
    public var timestamp: Date = Date.now

    /// Serialized JSON for source meetings and grounding confidence.
    public var sourceMeetingsJSON: String?
    public var groundingConfidenceRawValue: String?
    /// Serialized JSON for file attachments.
    public var attachmentsJSON: String?

    public var thread: ChatThreadModel?

    public init(
        id: UUID = UUID(),
        role: String,
        content: String,
        timestamp: Date = .now,
        sourceMeetingsJSON: String? = nil,
        groundingConfidenceRawValue: String? = nil,
        attachmentsJSON: String? = nil,
        thread: ChatThreadModel? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.sourceMeetingsJSON = sourceMeetingsJSON
        self.groundingConfidenceRawValue = groundingConfidenceRawValue
        self.attachmentsJSON = attachmentsJSON
        self.thread = thread
    }
}
