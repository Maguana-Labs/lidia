import Foundation
import SwiftData

/// Everything Today, the library and the project pages show from LidIA's
/// on-device intelligence, computed in one pass over the library.
struct IntelligenceResults: Sendable {
    var signals: [MeetingSignals] = []
    var context = ProjectSuggester.Context()
    var profiles: [ProjectSuggester.Profile] = []
    var projects: [ProjectCatalog.Summary] = []
    /// Meeting ID → suggested project (meetings without one).
    var projectSuggestions: [UUID: ProjectSuggester.Suggestion] = [:]
    var clusters: [ProjectSuggester.Cluster] = []
    var followUps: [FollowUpPlanner.Draft] = []
    var patterns: [PatternDetector.Pattern] = []
    /// Agenda event ID → its likely project.
    var eventProjects: [String: String] = [:]

    static let empty = IntelligenceResults()

    /// A series' suggestion: the project most of its unassigned meetings point to.
    func seriesSuggestion(for meetingIDs: [UUID]) -> ProjectSuggester.Suggestion? {
        let suggestions = meetingIDs.compactMap { projectSuggestions[$0] }
        guard suggestions.count * 2 >= meetingIDs.count, let first = suggestions.first else { return nil }
        guard suggestions.allSatisfy({ ProjectCatalog.fold($0.project) == ProjectCatalog.fold(first.project) }) else { return nil }
        return suggestions.max { $0.confidence < $1.confidence }
    }
}

@MainActor
enum IntelligenceEngine {
    /// Reads the library and runs every suggestion.
    static func compute(
        meetings: [Meeting],
        events: [AgendaEvent],
        settings: AppSettings,
        store: IntelligenceStore,
        now: Date = .now
    ) -> IntelligenceResults {
        MeetingAttendeeContext.currentUserName = settings.displayName
        let live = meetings.filter { !$0.isDeleted && $0.status != .recording }
        let signals = live.map { MeetingSignals($0) }
        var results = IntelligenceResults()
        results.signals = signals
        let context = ProjectSuggester.Context.build(signals)
        results.context = context
        let known = store.state.knownProjects
        results.profiles = ProjectSuggester.profiles(signals, context: context, extraProjects: known)
        results.projects = ProjectCatalog.projects(meetings: signals, known: known)
        let existingFits = ProjectSuggester.suggestions(
            for: signals, knownProjects: known, rejected: store.state.rejectedProjects, context: context
        )
        results.clusters = ProjectSuggester.clusters(
            signals,
            existingProjects: known,
            dismissed: store.state.dismissedClusters,
            excluding: Set(existingFits.keys),
            context: context
        )
        results.projectSuggestions = projectSuggestions(signals, clusters: results.clusters, context: context, store: store)

        // Speaker labels in transcripts help pick who the follow-up is to.
        var mentions: [UUID: String] = [:]
        for meeting in live where meeting.status == .complete {
            mentions[meeting.id] = String(meeting.refinedTranscript.prefix(20_000))
        }
        results.followUps = FollowUpPlanner.drafts(
            signals,
            handled: store.handledFollowUpIDs,
            senderName: settings.displayName,
            transcriptMentions: mentions,
            now: now
        )
        .filter { !store.isDismissed($0.id) }

        let openItems = live.flatMap { meeting in
            meeting.actionItems
                .filter { !$0.isDeleted && !$0.isCompleted }
                .map {
                    PatternDetector.OpenItem(
                        id: $0.id, title: $0.title,
                        meetingTitle: meeting.title, meetingDate: meeting.date,
                        project: meeting.projectName
                    )
                }
        }
        results.patterns = (PatternDetector.seriesReviews(events: events, meetings: signals, now: now)
            + PatternDetector.staleItems(openItems, now: now))
            .filter { !store.isDismissed($0.id) }

        for event in events where !event.isAllDay {
            let eventSignals = MeetingSignals(event: event, currentUserName: settings.displayName)
            if let best = ProjectSuggester.best(for: eventSignals, profiles: results.profiles, context: context) {
                results.eventProjects[event.id] = best.project
            }
        }
        return results
    }

    /// Existing projects first; a meeting that fits none but sits in a
    /// "new project" group is offered that group's name. Those never
    /// auto-assign (no strong signals): the project doesn't exist yet.
    static func projectSuggestions(
        _ signals: [MeetingSignals],
        clusters: [ProjectSuggester.Cluster],
        context: ProjectSuggester.Context,
        store: IntelligenceStore
    ) -> [UUID: ProjectSuggester.Suggestion] {
        var result = ProjectSuggester.suggestions(
            for: signals,
            knownProjects: store.state.knownProjects,
            rejected: store.state.rejectedProjects,
            context: context
        )
        for cluster in clusters {
            for id in cluster.meetingIDs where result[id] == nil && !store.rejectedProjects(for: id).contains(cluster.id) {
                result[id] = ProjectSuggester.Suggestion(
                    meetingID: id, project: cluster.name, confidence: cluster.confidence,
                    reasons: cluster.reasons, strongSignals: 0
                )
            }
        }
        return result
    }

    /// Changes whenever something the suggestions read changes.
    static func fingerprint(_ meetings: [Meeting], events: [AgendaEvent], store: IntelligenceStore) -> Int {
        var hasher = Hasher()
        for meeting in meetings where !meeting.isDeleted {
            hasher.combine(meeting.id)
            hasher.combine(meeting.folder)
            hasher.combine(meeting.status)
            hasher.combine(meeting.title)
            hasher.combine(meeting.summary.count)
            for item in meeting.actionItems where !item.isDeleted {
                hasher.combine(item.isCompleted)
            }
            hasher.combine(meeting.actionItems.count)
        }
        for event in events { hasher.combine(event.id) }
        hasher.combine(store.state)
        return hasher.finalize()
    }

    // MARK: - Actions

    /// Puts meetings in a project and remembers the project.
    static func assign(_ meetingIDs: [UUID], to project: String, in meetings: [Meeting], store: IntelligenceStore, context: ModelContext?) {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.registerProject(trimmed)
        let ids = Set(meetingIDs)
        for meeting in meetings where ids.contains(meeting.id) && !meeting.isDeleted {
            meeting.setProject(trimmed)
        }
        try? context?.save()
    }

    /// Auto-assigns near-certain suggestions when the user opted in. Returns how many.
    @discardableResult
    static func autoAssign(_ results: IntelligenceResults, meetings: [Meeting], settings: AppSettings, store: IntelligenceStore, context: ModelContext?) -> Int {
        guard settings.autoAssignProjects else { return 0 }
        var count = 0
        for suggestion in results.projectSuggestions.values where suggestion.isAutoAssignable {
            guard let meeting = meetings.first(where: { $0.id == suggestion.meetingID }),
                  !meeting.isDeleted, meeting.projectName == nil else { continue }
            meeting.setProject(suggestion.project)
            count += 1
        }
        if count > 0 { try? context?.save() }
        return count
    }
}

