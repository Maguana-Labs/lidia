import Foundation
import Observation

/// What the user told LidIA's suggestions: rejected project suggestions,
/// dismissed cards, follow-ups already handled, project colours and the
/// per-card "Comment to AI" switch.
///
/// Local to this Mac (one JSON value in user defaults). Nothing here leaves
/// the Mac, and none of it is meeting content: only IDs, project names and
/// the user's choices.
@MainActor
@Observable
final class IntelligenceStore {
    static let shared = IntelligenceStore()

    struct State: Codable, Hashable {
        /// Meeting ID → folded project names the user rejected for it.
        var rejectedProjects: [UUID: Set<String>] = [:]
        /// Folded names of "Create project …?" suggestions the user dismissed.
        var dismissedClusters: Set<String> = []
        /// IDs of Today cards the user dismissed (follow-ups, patterns).
        var dismissedCards: Set<String> = []
        /// Meeting ID → when the user sent (or copied) its follow-up.
        var handledFollowUps: [UUID: Date] = [:]
        /// Projects the user created, kept even before they hold a meeting.
        var knownProjects: [String] = []
        /// Project name → palette index.
        var projectColors: [String: Int] = [:]
        /// "heard → term" vocabulary suggestions the user dismissed.
        var dismissedVocabulary: Set<String> = []
        /// Action item ID → "Comment to AI" on/off when it differs from the global setting.
        var commentToAIOverrides: [UUID: Bool] = [:]
    }

    static let defaultsKey = "intelligence.state.v1"

    private let defaults: UserDefaults
    private(set) var state: State {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    #if DEBUG
    /// Snapshot runs start from a clean slate.
    func resetForSnapshot() { state = State() }
    #endif

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Projects

    func rejectedProjects(for meetingID: UUID) -> Set<String> {
        state.rejectedProjects[meetingID] ?? []
    }

    func rejectProject(_ project: String, for meetingIDs: [UUID]) {
        let folded = ProjectCatalog.fold(project)
        for id in meetingIDs {
            state.rejectedProjects[id, default: []].insert(folded)
        }
    }

    func dismissCluster(_ name: String) {
        state.dismissedClusters.insert(ProjectCatalog.fold(name))
    }

    func registerProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !state.knownProjects.contains(where: { ProjectCatalog.fold($0) == ProjectCatalog.fold(trimmed) }) else { return }
        state.knownProjects.append(trimmed)
        if state.projectColors[trimmed] == nil {
            // The colour it was suggested in, so it doesn't change on creation.
            state.projectColors[trimmed] = colorIndex(for: trimmed)
        }
    }

    func forgetProject(_ name: String) {
        let folded = ProjectCatalog.fold(name)
        state.knownProjects.removeAll { ProjectCatalog.fold($0) == folded }
        state.projectColors[name] = nil
    }

    func renameProject(_ old: String, to new: String) {
        let folded = ProjectCatalog.fold(old)
        if let index = state.knownProjects.firstIndex(where: { ProjectCatalog.fold($0) == folded }) {
            state.knownProjects[index] = new
        } else {
            state.knownProjects.append(new)
        }
        if let color = state.projectColors[old] {
            state.projectColors[old] = nil
            state.projectColors[new] = color
        }
    }

    func colorIndex(for project: String) -> Int {
        if let index = state.projectColors[project] { return index }
        // Stable across launches for projects that were never registered.
        let sum = ProjectCatalog.fold(project).unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % ProjectPalette.count
    }

    // MARK: - Cards and follow-ups

    func isDismissed(_ cardID: String) -> Bool { state.dismissedCards.contains(cardID) }

    func dismissCard(_ cardID: String) { state.dismissedCards.insert(cardID) }

    func markFollowUpHandled(_ meetingID: UUID, at date: Date = .now) {
        state.handledFollowUps[meetingID] = date
    }

    var handledFollowUpIDs: Set<UUID> { Set(state.handledFollowUps.keys) }

    // MARK: - Vocabulary

    func dismissVocabulary(_ key: String) { state.dismissedVocabulary.insert(key) }

    // MARK: - Comment to AI

    func commentToAI(for itemID: UUID, global: Bool) -> Bool {
        state.commentToAIOverrides[itemID] ?? global
    }

    func setCommentToAI(_ enabled: Bool, for itemID: UUID, global: Bool) {
        state.commentToAIOverrides[itemID] = enabled == global ? nil : enabled
    }
}

/// Colours for project dots and bars, picked by `IntelligenceStore.colorIndex(for:)`.
enum ProjectPalette {
    static let count = 8
}
