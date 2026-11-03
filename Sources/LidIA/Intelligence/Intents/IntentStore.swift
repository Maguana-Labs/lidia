import Foundation
import Observation
import os

/// The intents cache and the user's review choices, as one JSON file next
/// to the library (`Intents.json`). Keyed by action-item UUID, so the
/// SwiftData models stay untouched. Holds drafts made from meeting
/// content: it lives in the library folder, on this Mac only.
@MainActor
@Observable
final class IntentStore {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "IntentStore")

    /// What the transcript check found for an item when it was extracted.
    struct Verification: Codable, Sendable, Equatable {
        var verdict: ActionIntent.Verdict
        var evidence: ActionIntent.Evidence?
        /// The title the summary wrote, when the check corrected it.
        var originalTitle: String?
        var originalAssignee: String?
        var checkedBy: String?
    }

    /// A title LidIA wrote for a note or recording.
    struct AITitle: Codable, Sendable, Equatable {
        var title: String
        /// How long the content was when it was written.
        var contentLength: Int
        var date: Date
    }

    struct State: Codable, Sendable, Equatable {
        var version = 1
        var intents: [UUID: ActionIntent] = [:]
        var verifications: [UUID: Verification] = [:]
        /// Items the user chose to keep despite a review flag.
        var kept: Set<UUID> = []
        /// Meeting ID → the AI title it carries.
        var aiTitles: [UUID: AITitle] = [:]
        /// Meetings whose title the user typed: never retitled.
        var userTitled: Set<UUID> = []
    }

    static let fileName = "Intents.json"

    /// Next to the library in use (a snapshot run's copy included). Nil,
    /// so nothing is written, outside the app itself (tests, tools).
    static var defaultURL: URL? {
        #if DEBUG
        if let copy = SnapshotRun.storeOverrideURL {
            return copy.deletingLastPathComponent().appendingPathComponent(fileName)
        }
        #endif
        guard Bundle.main.bundleIdentifier == "io.lidia.app" else { return nil }
        return LibraryLocation.folder.appendingPathComponent(fileName)
    }

    static let shared = IntentStore(url: defaultURL)

    let url: URL?
    private(set) var state: State
    private var saveTask: Task<Void, Never>?

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = (try? decoder.decode(State.self, from: data)) ?? State()
        } else {
            state = State()
        }
    }

    // MARK: Intents

    func intent(for itemID: UUID) -> ActionIntent? { state.intents[itemID] }

    func setIntent(_ intent: ActionIntent) {
        guard state.intents[intent.itemID] != intent else { return }
        state.intents[intent.itemID] = intent
        scheduleSave()
    }

    func removeIntents(except live: Set<UUID>) {
        let stale = Set(state.intents.keys).subtracting(live)
        guard !stale.isEmpty else { return }
        for id in stale { state.intents[id] = nil }
        scheduleSave()
    }

    // MARK: Verification

    func verification(for itemID: UUID) -> Verification? { state.verifications[itemID] }

    func setVerification(_ verification: Verification, for itemID: UUID) {
        state.verifications[itemID] = verification
        scheduleSave()
    }

    func isKept(_ itemID: UUID) -> Bool { state.kept.contains(itemID) }

    /// The user looked at a flagged item and kept it.
    func keep(_ itemID: UUID) {
        state.kept.insert(itemID)
        scheduleSave()
    }

    /// The item needs the user's review: the transcript doesn't back it and
    /// the user hasn't kept it.
    func needsReview(_ itemID: UUID) -> ActionIntent.Verdict? {
        guard !isKept(itemID) else { return nil }
        if let intent = state.intents[itemID], intent.reviewable == false, state.verifications[itemID] == nil { return nil }
        let verdict = state.intents[itemID]?.verdict ?? state.verifications[itemID]?.verdict
        return verdict?.needsReview == true ? verdict : nil
    }

    // MARK: Titles

    func aiTitle(for meetingID: UUID) -> AITitle? { state.aiTitles[meetingID] }

    func setAITitle(_ title: String, contentLength: Int, for meetingID: UUID) {
        state.aiTitles[meetingID] = AITitle(title: title, contentLength: contentLength, date: .now)
        scheduleSave()
    }

    func isUserTitled(_ meetingID: UUID) -> Bool { state.userTitled.contains(meetingID) }

    func markUserTitled(_ meetingID: UUID) {
        guard !state.userTitled.contains(meetingID) else { return }
        state.userTitled.insert(meetingID)
        state.aiTitles[meetingID] = nil
        scheduleSave()
    }

    #if DEBUG
    func resetForSnapshot() { state = State() }
    #endif

    // MARK: Saving

    private func scheduleSave() {
        guard url != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: [.atomic])
        } catch {
            Self.logger.error("Couldn't save intents: \(error.localizedDescription, privacy: .public)")
        }
    }
}
