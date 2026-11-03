import Foundation
import os
import SwiftData

/// Generates proactive pre-meeting briefs as InboxNotifications shortly before
/// upcoming calendar events. Surfaces in the FOR YOU dispatcher card section.
///
/// Today: pre-meeting briefs (this file).
/// Roadmap: stale action-item nudges, re-engagement reminders, decision tracker.
@MainActor
@Observable
final class ProactiveInsightsService {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "ProactiveInsights")
    private var scheduler: Task<Void, Never>?

    /// How many minutes before the event start we generate the brief.
    /// Extended to 90 min so users see briefs in the Home Insights section
    /// well before the meeting (and well before the system "5 min before"
    /// reminder fires). Deduped per-event so a single brief survives the window.
    private let prepWindowMinutes: Int = 90

    /// Minimum gap between scheduler polls (seconds). Cheap — only reads in-memory
    /// upcomingEvents and a SwiftData query.
    private let pollInterval: TimeInterval = 60

    /// Cap of briefs to generate per tick to avoid token spam if many events stack.
    private let maxBriefsPerTick: Int = 2

    func startScheduler(
        settings: AppSettings,
        modelContext: ModelContext,
        modelManager: ModelManager?,
        googleCalendarMonitor: GoogleCalendarMonitor,
        eventKitManager: EventKitManager
    ) {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            // Initial tick on startup so freshly-relaunched app catches imminent events.
            await self?.tick(
                settings: settings,
                modelContext: modelContext,
                modelManager: modelManager,
                googleCalendarMonitor: googleCalendarMonitor,
                eventKitManager: eventKitManager
            )
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 60))
                guard !Task.isCancelled else { return }
                await self?.tick(
                    settings: settings,
                    modelContext: modelContext,
                    modelManager: modelManager,
                    googleCalendarMonitor: googleCalendarMonitor,
                    eventKitManager: eventKitManager
                )
            }
        }
    }

    func stopScheduler() {
        scheduler?.cancel()
        scheduler = nil
    }

    // MARK: - Tick

    private func tick(
        settings: AppSettings,
        modelContext: ModelContext,
        modelManager: ModelManager?,
        googleCalendarMonitor: GoogleCalendarMonitor,
        eventKitManager: EventKitManager
    ) async {
        // Reuse the existing prep-notifications-enabled flag.
        guard settings.prepNotificationsEnabled else { return }

        let now = Date.now
        let horizonEnd = now.addingTimeInterval(TimeInterval(prepWindowMinutes * 60))
        var candidates: [PrepCandidate] = []

        for ge in googleCalendarMonitor.upcomingEvents {
            guard ge.start > now, ge.start <= horizonEnd else { continue }
            guard !ge.attendees.isEmpty else { continue }
            candidates.append(PrepCandidate(
                eventID: "google:\(ge.id)",
                title: ge.title,
                start: ge.start,
                attendees: ge.attendees,
                rawEventID: ge.id
            ))
        }

        for ae in eventKitManager.upcomingEvents {
            guard ae.start > now, ae.start <= horizonEnd else { continue }
            guard !ae.attendees.isEmpty else { continue }
            candidates.append(PrepCandidate(
                eventID: "apple:\(ae.id)",
                title: ae.title,
                start: ae.start,
                attendees: ae.attendees,
                rawEventID: ae.id
            ))
        }

        guard !candidates.isEmpty else { return }

        let descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\Meeting.date, order: .reverse)])
        let library = (try? modelContext.fetch(descriptor)) ?? []

        // Filter out events we've already briefed. A brief that wrongly called a
        // recurring meeting a first encounter (before history matching used
        // titles) is replaced once history is found.
        let existing = existingPrepBriefs(modelContext: modelContext)
        var fresh: [(PrepCandidate, PrepBrief.Context)] = []
        for candidate in candidates.sorted(by: { $0.start < $1.start }) {
            let context = PrepBrief.context(for: candidate.upcoming, library: library)
            if let old = existing[candidate.eventID] {
                guard context.hasHistory, Self.claimsFirstEncounter(old.body) else { continue }
                modelContext.delete(old)
            }
            fresh.append((candidate, context))
        }
        guard !fresh.isEmpty else { return }

        // Generate at most N briefs per tick, soonest-starting first.
        for (candidate, context) in fresh.prefix(maxBriefsPerTick) {
            await generateBrief(
                candidate: candidate,
                context: context,
                settings: settings,
                modelManager: modelManager,
                modelContext: modelContext
            )
        }
    }

    /// True for briefs written by the old prompt for "no history" meetings.
    nonisolated static func claimsFirstEncounter(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["first-encounter", "first encounter", "first meeting", "no prior meetings", "primer encuentro", "primera reunión"]
            .contains { lower.contains($0) }
    }

    // MARK: - Brief generation

    private func generateBrief(
        candidate: PrepCandidate,
        context: PrepBrief.Context,
        settings: AppSettings,
        modelManager: ModelManager?,
        modelContext: ModelContext
    ) async {
        let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .prepBrief)
        let model = effectiveModel(for: .summary, settings: settings, taskType: .prepBrief)
        guard !model.isEmpty else {
            Self.logger.info("No model configured for summarization (provider: \(settings.llmProvider.rawValue, privacy: .public)); skipping brief")
            return
        }

        do {
            let brief = try await client.chat(
                messages: [LLMChatMessage(role: "user", content: context.prompt)],
                model: model,
                format: nil
            )
            let trimmed = MapReduceSummarizer.stripThinking(brief)
            guard !trimmed.isEmpty else { return }

            let payload = InboxNotification.encodePayload(
                meetingTitle: candidate.title,
                eventID: candidate.eventID
            )
            let notif = InboxNotification(
                type: "meeting_prep",
                title: "Prep: \(candidate.title)",
                body: trimmed,
                actionPayload: payload
            )
            modelContext.insert(notif)
            try? modelContext.save()
            Self.logger.info("Generated prep brief for \(candidate.title, privacy: .public) from \(context.matchedMeetingIDs.count, privacy: .public) earlier meetings")
        } catch {
            Self.logger.error("Brief generation failed for \(candidate.eventID, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: - Dedup

    private func existingPrepBriefs(modelContext: ModelContext) -> [String: InboxNotification] {
        let descriptor = FetchDescriptor<InboxNotification>(
            predicate: #Predicate<InboxNotification> { $0.type == "meeting_prep" }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        var byEvent: [String: InboxNotification] = [:]
        for notification in existing {
            guard let eventID = notification.sourceEventID else { continue }
            byEvent[eventID] = notification
        }
        return byEvent
    }
}

private struct PrepCandidate {
    let eventID: String
    let title: String
    let start: Date
    let attendees: [String]
    let rawEventID: String

    var upcoming: MeetingHistoryMatcher.Upcoming {
        MeetingHistoryMatcher.Upcoming(title: title, attendees: attendees, calendarEventIDs: [rawEventID], start: start)
    }
}
