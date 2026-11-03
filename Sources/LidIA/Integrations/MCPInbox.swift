import Foundation
import SwiftData
import os

// MARK: - Request format
//
// The LidiaMCP server never writes to the app's database. Each write a tool
// asks for becomes one JSON file in the inbox folder; the app validates it and
// applies it through SwiftData. Keep this format in sync with
// `Sources/LidiaMCP/main.swift` (`InboxRequest`).

/// One queued write from the MCP server.
struct MCPInboxRequest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Operation: String, Codable, Sendable {
        case createActionItem = "create_action_item"
        case updateActionItem = "update_action_item"
        case deleteActionItem = "delete_action_item"
        case markActionItemDone = "mark_action_item_done"
        case updateMeetingNotes = "update_meeting_notes"
    }

    var version: Int
    var requestID: String
    var createdAt: String
    var operation: Operation
    var actionItemID: String?
    var meetingID: String?
    var title: String?
    var assignee: String?
    var deadline: String?
    var isCompleted: Bool?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case createdAt = "created_at"
        case operation
        case actionItemID = "action_item_id"
        case meetingID = "meeting_id"
        case title, assignee, deadline
        case isCompleted = "is_completed"
        case notes
    }
}

enum MCPInbox {
    /// `~/Library/Application Support/LidIA/MCPInbox`. The MCP server writes here.
    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("LidIA/MCPInbox", isDirectory: true)
    }

    // Limits. Generous for real use, small enough that a runaway client
    // can't fill the database.
    static let maxFileBytes = 2 * 1024 * 1024
    static let maxTitleLength = 500
    static let maxAssigneeLength = 200
    static let maxDeadlineLength = 100
    static let maxNotesLength = 1_000_000
    static let maxFilesPerPass = 500
}

// MARK: - Importer

/// Applies queued MCP writes. Runs at launch and whenever the inbox changes.
///
/// Every request is validated before it touches SwiftData: IDs must be UUIDs,
/// referenced meetings and action items must exist, text has length limits,
/// and new action items get the ID the MCP server already returned to its
/// client (rejected if that ID is taken by something else). Applied requests
/// are deleted; rejected ones move to `Rejected/` with a `.reason.txt` note.
@MainActor
final class MCPInboxImporter {
    static let shared = MCPInboxImporter(directory: MCPInbox.defaultDirectory)

    enum Outcome: Equatable {
        case applied
        /// Already applied earlier (for example a create whose item exists).
        case alreadyApplied
        case rejected(String)
    }

    struct PassResult: Equatable {
        var applied = 0
        var rejected = 0
    }

    private static let logger = Logger(subsystem: "io.lidia.app", category: "MCPInbox")

    let directory: URL
    var rejectedDirectory: URL { directory.appendingPathComponent("Rejected", isDirectory: true) }

    private var modelContext: ModelContext?
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingPass: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    /// Imports anything already queued and starts watching for new requests.
    /// Safe to call more than once.
    func start(modelContext: ModelContext) {
        // Demo mode uses a throwaway in-memory store; leave real requests queued.
        guard !DemoDataSeeder.isDemoMode else { return }
        if self.modelContext == nil {
            // A context of our own, so a rollback after a failed save can never
            // discard unsaved edits the rest of the app made.
            let own = ModelContext(modelContext.container)
            own.autosaveEnabled = false
            self.modelContext = own
        }
        do {
            try ensureDirectory()
        } catch {
            Self.logger.error("MCP inbox unavailable: \(error.localizedDescription)")
            return
        }
        importPending()
        startWatching()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        pendingPass?.cancel()
        pendingPass = nil
    }

    /// Processes every queued request once, oldest first.
    @discardableResult
    func importPending() -> PassResult {
        guard let context = modelContext else { return PassResult() }
        return importPending(into: context)
    }

    @discardableResult
    func importPending(into context: ModelContext) -> PassResult {
        var result = PassResult()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return result }
        let files = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
            .prefix(MCPInbox.maxFilesPerPass)

        for name in files {
            let url = directory.appendingPathComponent(name)
            let outcome = process(fileAt: url, in: context)
            switch outcome {
            case .applied, .alreadyApplied:
                do {
                    try context.save()
                    try? fm.removeItem(at: url)
                    if outcome == .applied { result.applied += 1 }
                } catch {
                    context.rollback()
                    reject(fileAt: url, reason: "Could not save: \(error.localizedDescription)")
                    result.rejected += 1
                }
            case .rejected(let reason):
                context.rollback()
                reject(fileAt: url, reason: reason)
                result.rejected += 1
            }
        }
        if result.applied > 0 || result.rejected > 0 {
            Self.logger.info("MCP inbox: applied \(result.applied), rejected \(result.rejected)")
        }
        return result
    }

    // MARK: - Validation & apply

    func process(fileAt url: URL, in context: ModelContext) -> Outcome {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            return .rejected("Not a regular file")
        }
        guard (values.fileSize ?? 0) <= MCPInbox.maxFileBytes else {
            return .rejected("File is larger than \(MCPInbox.maxFileBytes) bytes")
        }
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(MCPInboxRequest.self, from: data) else {
            return .rejected("Not a valid request")
        }
        return apply(request, in: context)
    }

    func apply(_ request: MCPInboxRequest, in context: ModelContext) -> Outcome {
        guard request.version == MCPInboxRequest.currentVersion else {
            return .rejected("Unsupported version \(request.version)")
        }
        guard UUID(uuidString: request.requestID) != nil else {
            return .rejected("request_id is not a UUID")
        }
        if let problem = textProblem(request) { return .rejected(problem) }

        switch request.operation {
        case .createActionItem:
            guard let id = uuid(request.actionItemID) else { return .rejected("action_item_id is not a UUID") }
            guard let title = trimmed(request.title) else { return .rejected("title is required") }
            if fetchActionItem(id, in: context) != nil { return .alreadyApplied }
            var meeting: Meeting?
            if let rawMeetingID = request.meetingID {
                guard let meetingID = uuid(rawMeetingID) else { return .rejected("meeting_id is not a UUID") }
                guard let found = fetchMeeting(meetingID, in: context) else { return .rejected("Meeting not found") }
                meeting = found
            }
            let item = ActionItem(title: title, assignee: trimmed(request.assignee))
            item.id = id
            setDeadline(request.deadline, on: item)
            if request.isCompleted == true { item.isCompleted = true }
            context.insert(item)
            item.meeting = meeting
            return .applied

        case .updateActionItem:
            guard let id = uuid(request.actionItemID) else { return .rejected("action_item_id is not a UUID") }
            guard let item = fetchActionItem(id, in: context) else { return .rejected("Action item not found") }
            guard request.title != nil || request.assignee != nil || request.deadline != nil || request.isCompleted != nil else {
                return .rejected("No fields to update")
            }
            if request.title != nil {
                guard let title = trimmed(request.title) else { return .rejected("title can't be empty") }
                item.title = title
            }
            if let assignee = request.assignee {
                item.assignee = trimmed(assignee)
            }
            if request.deadline != nil {
                setDeadline(request.deadline, on: item)
            }
            if let isCompleted = request.isCompleted {
                item.isCompleted = isCompleted
            }
            return .applied

        case .deleteActionItem:
            guard let id = uuid(request.actionItemID) else { return .rejected("action_item_id is not a UUID") }
            guard let item = fetchActionItem(id, in: context) else { return .alreadyApplied }
            item.meeting?.actionItems.removeAll { $0.id == id }
            context.delete(item)
            return .applied

        case .markActionItemDone:
            guard let id = uuid(request.actionItemID) else { return .rejected("action_item_id is not a UUID") }
            guard let item = fetchActionItem(id, in: context) else { return .rejected("Action item not found") }
            item.isCompleted = true
            return .applied

        case .updateMeetingNotes:
            guard let id = uuid(request.meetingID) else { return .rejected("meeting_id is not a UUID") }
            guard let notes = request.notes else { return .rejected("notes is required") }
            guard let meeting = fetchMeeting(id, in: context) else { return .rejected("Meeting not found") }
            meeting.notes = notes
            return .applied
        }
    }

    private func textProblem(_ request: MCPInboxRequest) -> String? {
        if let title = request.title, title.count > MCPInbox.maxTitleLength { return "title is too long" }
        if let assignee = request.assignee, assignee.count > MCPInbox.maxAssigneeLength { return "assignee is too long" }
        if let deadline = request.deadline, deadline.count > MCPInbox.maxDeadlineLength { return "deadline is too long" }
        if let notes = request.notes, notes.count > MCPInbox.maxNotesLength { return "notes are too long" }
        return nil
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func uuid(_ raw: String?) -> UUID? {
        guard let raw, raw.count == 36 else { return nil }
        return UUID(uuidString: raw)
    }

    /// Accepts `YYYY-MM-DD` (as the tool schema documents) and keeps any other
    /// text as a free-form deadline.
    private func setDeadline(_ raw: String?, on item: ActionItem) {
        guard let text = trimmed(raw) else {
            item.deadline = nil
            item.deadlineDate = nil
            return
        }
        item.deadline = text
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        item.deadlineDate = formatter.date(from: text)
    }

    private func fetchActionItem(_ id: UUID, in context: ModelContext) -> ActionItem? {
        var descriptor = FetchDescriptor<ActionItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchMeeting(_ id: UUID, in context: ModelContext) -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Files

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func reject(fileAt url: URL, reason: String) {
        Self.logger.warning("MCP inbox rejected \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
        let fm = FileManager.default
        try? fm.createDirectory(at: rejectedDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let destination = rejectedDirectory.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: destination)
        if (try? fm.moveItem(at: url, to: destination)) == nil {
            try? fm.removeItem(at: url)
        }
        let note = rejectedDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".reason.txt")
        try? Data(reason.utf8).write(to: note)
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.error("Could not watch the MCP inbox")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleImport()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Coalesces bursts of file events into one pass.
    private func scheduleImport() {
        pendingPass?.cancel()
        pendingPass = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.importPending()
        }
    }
}
