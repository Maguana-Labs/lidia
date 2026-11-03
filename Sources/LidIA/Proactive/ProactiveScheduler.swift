import Foundation
import Observation
import SwiftData
import UserNotifications
import os

@MainActor
@Observable
final class ProactiveScheduler {
    enum DigestFrequency: String, Sendable {
        case daily
        case monday
        case off
    }

    /// The next meeting that should show a join banner (has a link, starts within notification window).
    /// Observed by LidIAApp to trigger the floating banner.
    private(set) var pendingBannerMeeting: PendingMeetingBanner?
    /// Event IDs that the user has dismissed the banner for (don't re-show).
    private var dismissedBannerEvents: Set<String> = []

    private let logger = Logger(subsystem: "io.lidia.app", category: "ProactiveScheduler")

    private var settings: AppSettings?
    private var calendarMonitor: GoogleCalendarMonitor?
    private var eventKitManager: EventKitManager?
    private var modelContext: ModelContext?

    private var morningDigestTimer: Timer?
    private var eventCheckTimer: Timer?
    /// Merged agenda event IDs that already got their single pre-meeting prompt.
    private var promptedEvents: Set<String> = []
    private var scheduledNudges: Set<String> = []
    /// Provides whether a recording is in progress (no prompts while recording).
    var isRecordingProvider: (@MainActor () -> Bool)?
    private var lastMorningTriggerDay: Date?
    private var lastActionItemReminderDay: Date?

    func configure(
        settings: AppSettings,
        calendarMonitor: GoogleCalendarMonitor,
        eventKitManager: EventKitManager,
        modelContext: ModelContext
    ) {
        self.settings = settings
        self.calendarMonitor = calendarMonitor
        self.eventKitManager = eventKitManager
        self.modelContext = modelContext

        Task {
            _ = await NotificationDispatcher.requestPermission()
        }
        NotificationDispatcher.removeLegacyCalendarNotifications()

        startTimers()
    }

    func startTimers() {
        stopTimers()
        guard settings != nil else { return }

        eventCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkEvents()
            }
        }
        eventCheckTimer?.tolerance = 5
        RunLoop.main.add(eventCheckTimer!, forMode: .common)

        scheduleNextMorningTrigger()
    }

    func stopTimers() {
        morningDigestTimer?.invalidate()
        morningDigestTimer = nil
        eventCheckTimer?.invalidate()
        eventCheckTimer = nil
        scheduledNudges.removeAll()
        pendingBannerMeeting = nil
    }

    /// Called when user dismisses or joins from the banner. Prevents re-showing for this event.
    func dismissBanner(eventID: String) {
        dismissedBannerEvents.insert(eventID)
        if pendingBannerMeeting?.eventID == eventID {
            pendingBannerMeeting = nil
        }
    }

    nonisolated static func isWithinQuietHours(
        now: Date,
        quietStart: Date,
        quietEnd: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let nowMinutes = minutesSinceMidnight(for: now, calendar: calendar)
        let startMinutes = minutesSinceMidnight(for: quietStart, calendar: calendar)
        let endMinutes = minutesSinceMidnight(for: quietEnd, calendar: calendar)

        if startMinutes == endMinutes {
            return false
        }
        if startMinutes < endMinutes {
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        }
        return nowMinutes >= startMinutes || nowMinutes < endMinutes
    }

    nonisolated static func nextMorningDigestDate(
        after now: Date,
        triggerTime: Date,
        frequency: DigestFrequency,
        calendar: Calendar = .current
    ) -> Date? {
        guard frequency != .off else { return nil }

        let time = calendar.dateComponents([.hour, .minute], from: triggerTime)
        var candidateComponents = calendar.dateComponents([.year, .month, .day], from: now)
        candidateComponents.hour = time.hour
        candidateComponents.minute = time.minute
        candidateComponents.second = 0

        guard var candidate = calendar.date(from: candidateComponents) else { return nil }

        switch frequency {
        case .daily:
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate

        case .monday:
            while calendar.component(.weekday, from: candidate) != 2 || candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate

        case .off:
            return nil
        }
    }

    private func scheduleNextMorningTrigger() {
        guard let settings else { return }
        let frequency = settings.proactiveMorningDigest
            ? DigestFrequency(rawValue: settings.proactiveMorningDigestFrequency) ?? .daily
            : (settings.proactiveActionItemReminders ? .daily : .off)

        guard let nextDate = Self.nextMorningDigestDate(
            after: .now,
            triggerTime: settings.proactiveMorningDigestTime,
            frequency: frequency
        ) else {
            return
        }

        let interval = max(1, nextDate.timeIntervalSinceNow)
        morningDigestTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.handleMorningTrigger()
                self?.scheduleNextMorningTrigger()
            }
        }
        morningDigestTimer?.tolerance = 30
        RunLoop.main.add(morningDigestTimer!, forMode: .common)
    }

    /// Settings snapshot for the prompt planner.
    static func promptConfig(from settings: AppSettings) -> PreMeetingPromptPlanner.Config {
        PreMeetingPromptPlanner.Config(
            notifyUpcoming: settings.notifyUpcomingMeetings,
            notifyMinutes: settings.meetingNotificationMinutes,
            recordPromptEnabled: settings.calendarRecordPromptEnabled,
            prepEnabled: settings.proactivePreMeetingPrep || settings.prepNotificationsEnabled,
            prepMinutes: settings.proactivePreMeetingMinutes
        )
    }

    private func checkEvents() {
        guard let settings else { return }
        let events = agendaEvents()
        let now = Date()
        let quietHours = Self.isWithinQuietHours(
            now: now,
            quietStart: settings.proactiveQuietStart,
            quietEnd: settings.proactiveQuietEnd
        )
        let isRecording = isRecordingProvider?() ?? false

        // One prompt per meeting: banner for meetings with a call link,
        // otherwise a single notification. Never both, never twice.
        let decisions = PreMeetingPromptPlanner.due(
            events: events,
            now: now,
            config: Self.promptConfig(from: settings),
            alreadyPrompted: promptedEvents,
            isRecording: isRecording
        )
        for decision in decisions {
            promptedEvents.insert(decision.event.id)
            guard !quietHours else { continue }
            switch decision.kind {
            case .banner:
                showBanner(for: decision.event)
            case .notification:
                let summary = decision.includePrep ? prepSummary(for: decision.event) : nil
                NotificationDispatcher.sendMeetingPrompt(
                    eventID: decision.event.calendarEventID,
                    promptKey: decision.event.id,
                    title: decision.event.title,
                    body: PreMeetingPromptPlanner.notificationBody(for: decision, now: now, prepSummary: summary),
                    meetingLink: decision.event.meetingLink
                )
            }
        }

        // Retire the banner once its meeting is well under way or gone.
        if let banner = pendingBannerMeeting,
           isRecording || now.timeIntervalSince(banner.start) > 30 * 60
            || dismissedBannerEvents.contains(banner.eventID) {
            pendingBannerMeeting = nil
        }

        if settings.proactivePostMeetingNudge {
            for event in events where !event.isAllDay {
                let interval = now.timeIntervalSince(event.end)
                guard interval >= Double(settings.proactivePostMeetingMinutes * 60),
                      interval <= Double((settings.proactivePostMeetingMinutes + 30) * 60),
                      !scheduledNudges.contains(event.id) else { continue }
                scheduledNudges.insert(event.id)
                guard !quietHours else { continue }
                Task { await firePostMeetingNudge(for: event) }
            }
        }

        // Keep the dedupe sets from growing forever.
        let liveIDs = Set(events.map(\.id))
        promptedEvents.formIntersection(liveIDs)
        scheduledNudges.formIntersection(liveIDs)
    }

    private func showBanner(for event: AgendaEvent) {
        let banner = PendingMeetingBanner(
            eventID: event.calendarEventID,
            title: event.title,
            start: event.start,
            end: event.end,
            meetingLink: event.meetingLink,
            attendees: event.attendees
        )
        guard !dismissedBannerEvents.contains(banner.eventID) else { return }
        if pendingBannerMeeting != banner {
            pendingBannerMeeting = banner
        }
    }

    private func handleMorningTrigger() async {
        guard let settings else { return }
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)

        guard !Self.isWithinQuietHours(
            now: now,
            quietStart: settings.proactiveQuietStart,
            quietEnd: settings.proactiveQuietEnd
        ) else {
            lastMorningTriggerDay = day
            lastActionItemReminderDay = day
            return
        }

        if settings.proactiveMorningDigest, lastMorningTriggerDay != day {
            await fireMorningDigest()
            lastMorningTriggerDay = day
        }

        if settings.proactiveActionItemReminders,
           !settings.proactiveMorningDigest,
           lastActionItemReminderDay != day {
            await fireActionItemReminders()
            lastActionItemReminderDay = day
        }
    }

    private func fireMorningDigest() async {
        let events = agendaEvents().filter { !$0.isAllDay && Calendar.current.isDateInToday($0.start) }
        let items = dueActionItems(referenceDate: .now)
        let details = events.prefix(3).map(\.title).joined(separator: ", ")
        NotificationDispatcher.sendMorningDigest(
            eventCount: events.count,
            actionItemCount: items.count,
            details: details.isEmpty ? "Open LidIA for details." : details
        )
    }

    private func firePostMeetingNudge(for event: AgendaEvent) async {
        guard shouldNudge(for: event) else { return }
        NotificationDispatcher.sendPostMeetingNudge(eventTitle: event.title, eventID: event.calendarEventID)
    }

    private func fireActionItemReminders() async {
        let items = dueActionItems(referenceDate: .now)
        guard !items.isEmpty else { return }
        NotificationDispatcher.sendActionItemReminder(
            count: items.count,
            titles: items.map(\.title)
        )
    }

    /// Apple and Google events merged into one deduplicated list.
    private func agendaEvents() -> [AgendaEvent] {
        let google = (calendarMonitor?.isSignedIn == true) ? (calendarMonitor?.upcomingEvents ?? []) : []
        let apple = eventKitManager?.upcomingEvents ?? []
        return UnifiedCalendar.merge(apple: apple, google: google)
    }

    private func prepSummary(for event: AgendaEvent) -> String {
        // Earlier meetings in the same series or with the same people (not just
        // this exact event), so recurring meetings get their history.
        let library: [Meeting] = modelContext.flatMap {
            try? $0.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        } ?? []
        let upcoming = MeetingHistoryMatcher.Upcoming(
            title: event.title,
            attendees: event.attendees,
            calendarEventIDs: [event.googleEventID, event.appleEventID].compactMap { $0 },
            start: event.start
        )
        let relatedMeetings = MeetingHistoryMatcher
            .matches(for: upcoming, in: library.filter { $0.status == .complete })
            .map(\.meeting)
        let relatedItems = relatedMeetings
            .flatMap(\.actionItems)
            .filter { !$0.isCompleted }
            .prefix(3)
            .map(\.title)

        var fragments: [String] = []
        if let lastMeeting = relatedMeetings.first,
           !lastMeeting.summary.isEmpty {
            fragments.append("Last meeting: \(trimmedPreview(lastMeeting.summary))")
        }
        if !relatedItems.isEmpty {
            fragments.append("Open items: \(relatedItems.joined(separator: ", "))")
        }

        return fragments.isEmpty ? "Open LidIA for the latest notes and context." : fragments.joined(separator: " ")
    }

    private func shouldNudge(for event: AgendaEvent) -> Bool {
        let relatedMeetings = recentMeetings(matching: event)
        guard let lastMeeting = relatedMeetings.first else { return true }
        return lastMeeting.status == .failed
    }

    private func recentMeetings(matching event: AgendaEvent) -> [Meeting] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let meetings = (try? context.fetch(descriptor)) ?? []

        return meetings.filter { meeting in
            guard meeting.status == .complete || meeting.status == .failed else { return false }

            if let calendarEventID = meeting.calendarEventID,
               calendarEventID == event.googleEventID || calendarEventID == event.appleEventID {
                return true
            }

            let attendeeOverlap = Set(meeting.calendarAttendees ?? []).intersection(event.attendees)
            if !attendeeOverlap.isEmpty {
                return true
            }

            return meeting.title == event.title && abs(meeting.date.timeIntervalSince(event.start)) < 6 * 60 * 60
        }
    }

    private func dueActionItems(referenceDate: Date) -> [ActionItem] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<ActionItem>()
        let items = (try? context.fetch(descriptor)) ?? []
        let startOfToday = Calendar.current.startOfDay(for: referenceDate)

        return items.filter { item in
            guard !item.isCompleted, let deadline = item.deadlineDate else { return false }
            return deadline < startOfToday || Calendar.current.isDate(deadline, inSameDayAs: referenceDate)
        }
    }

    private func trimmedPreview(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        if cleaned.count <= 100 {
            return cleaned
        }
        return String(cleaned.prefix(97)) + "..."
    }

    private nonisolated static func minutesSinceMidnight(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
