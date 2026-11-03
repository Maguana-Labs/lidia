import EventKit
import SwiftUI
import SwiftData
import UserNotifications
import os

@MainActor
@Observable
final class EventKitManager {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "EventKitManager")

    // MARK: - Calendar

    struct CalendarEvent: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        let calendarName: String
        let meetingLink: URL?
    }

    var upcomingEvents: [CalendarEvent] = []
    var todayEvents: [CalendarEvent] { upcomingEvents }
    var calendarAccessGranted = false
    var remindersAccessGranted = false
    var error: String?
    var backgroundContext: ModelContext?

    private let store = EKEventStore()
    private var pollTask: Task<Void, Never>?

    // MARK: - Calendar Access

    func requestCalendarAccess() async {
        do {
            calendarAccessGranted = try await store.requestFullAccessToEvents()
        } catch {
            self.error = "Calendar access denied: \(error.localizedDescription)"
        }
    }

    // MARK: - Google accounts added to macOS

    /// Event calendars that reach Apple Calendar from Google accounts added in
    /// System Settings → Internet Accounts. Zero until calendar access is granted.
    var googleCalendarCountViaMacOS = 0

    /// Re-reads the event sources and counts Google calendars. Cheap; call it
    /// when Settings appears and when the app comes back from System Settings.
    func refreshGoogleAccountStatus() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            googleCalendarCountViaMacOS = 0
            return
        }
        calendarAccessGranted = true
        store.refreshSourcesIfNecessary()
        let sources = store.sources.map { source in
            GoogleAccountDetection.Source(
                title: source.title,
                isCalDAV: source.sourceType == .calDAV,
                calendarTitles: source.calendars(for: .event).map(\.title)
            )
        }
        googleCalendarCountViaMacOS = GoogleAccountDetection.googleCalendarCount(in: sources)
    }

    // MARK: - Calendar list (Settings › Calendars)

    /// One event calendar, for the per-calendar switches in Settings.
    struct CalendarInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let color: CGColor?
    }

    /// Calendars grouped by account ("iCloud", "Google", "On My Mac"…).
    struct CalendarGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let calendars: [CalendarInfo]
    }

    /// Event calendars grouped by their account, accounts sorted by name.
    /// Empty until calendar access is granted.
    func calendarGroups() -> [CalendarGroup] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let calendars = store.calendars(for: .event)
        let bySource = Dictionary(grouping: calendars) { $0.source?.sourceIdentifier ?? "" }
        return bySource.compactMap { sourceID, calendars -> CalendarGroup? in
            guard let first = calendars.first else { return nil }
            let title = first.source.map(Self.accountTitle(for:)) ?? "Other"
            let infos = calendars
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: $0.cgColor) }
            return CalendarGroup(id: sourceID, title: title, calendars: infos)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func accountTitle(for source: EKSource) -> String {
        switch source.sourceType {
        case .local: return "On My Mac"
        case .birthdays: return "Other"
        case .subscribed: return "Subscribed"
        default: return source.title.isEmpty ? "Other" : source.title
        }
    }

    var calendarAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func startPolling(settings: AppSettings) {
        stopPolling()
        guard settings.calendarEnabled else { return }

        pollTask = Task {
            if !calendarAccessGranted {
                await requestCalendarAccess()
            }
            guard calendarAccessGranted else { return }

            // Refresh as soon as Calendar changes (an account added, an event
            // moved), not only on the next poll.
            let changes = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    guard let self else { return }
                    self.store.refreshSourcesIfNecessary()
                    await self.refresh(settings: settings)
                }
            }
            defer { changes.cancel() }

            while !Task.isCancelled {
                await refresh(settings: settings)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(settings: AppSettings) async {
        error = nil
        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 60 * 60)

        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
        let ekEvents = CalendarVisibility.visible(
            store.events(matching: predicate),
            hidden: settings.hiddenCalendarIDs,
            calendarID: { $0.calendar?.calendarIdentifier }
        )

        upcomingEvents = ekEvents
            .compactMap(Self.calendarEvent(from:))
            .filter { $0.end >= now }
            .sorted { $0.start < $1.start }

        // Pre-meeting prompts are owned by ProactiveScheduler, which merges
        // Apple and Google events so each meeting is prompted at most once.
    }

    /// Maps an EventKit event, or nil when it has no identifier or dates. EventKit
    /// imports these as implicitly unwrapped (`String!`, `Date!`), so reading a missing
    /// one directly traps.
    static func calendarEvent(from event: EKEvent) -> CalendarEvent? {
        let identifier: String? = event.eventIdentifier
        let start: Date? = event.startDate
        let end: Date? = event.endDate
        guard let identifier, !identifier.isEmpty, let start, let end else { return nil }
        let title: String? = event.title
        return CalendarEvent(
            id: identifier,
            title: title ?? "Untitled",
            start: start,
            end: end,
            attendees: event.attendees?.compactMap(\.name) ?? [],
            calendarName: event.calendar?.title ?? "",
            meetingLink: extractMeetingLink(from: event)
        )
    }

    // MARK: - Consent disclosure

    enum DisclosureResult: Equatable {
        case added
        case alreadyPresent
        case notFound
        case readOnly
        case failed(String)

        var message: String {
            switch self {
            case .added: "Added to the invite."
            case .alreadyPresent: "The invite already says AI notes are in use."
            case .notFound: "Couldn't find this event in Apple Calendar."
            case .readOnly: "This calendar can't be edited from LidIA. Copy the disclosure message instead."
            case .failed(let reason): "Couldn't update the invite: \(reason)"
            }
        }
    }

    /// Appends the "AI notes in use" line to an Apple Calendar event's notes.
    /// Only call this from an explicit user action: saving an event the user
    /// organizes can update attendees' copies of the invite.
    func addAINotesDisclosure(toEventID eventID: String) -> DisclosureResult {
        guard let event = store.event(withIdentifier: eventID) else { return .notFound }
        guard event.calendar?.allowsContentModifications == true else { return .readOnly }
        guard let updated = ConsentDisclosure.notesAddingDisclosure(to: event.notes) else {
            return .alreadyPresent
        }
        event.notes = updated
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .added
        } catch {
            Self.logger.error("Failed to add AI notes disclosure: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Reminders

    func requestRemindersAccess() async {
        do {
            remindersAccessGranted = try await store.requestFullAccessToReminders()
        } catch {
            self.error = "Reminders access denied: \(error.localizedDescription)"
        }
    }

    /// Finds or creates the "LidIA" reminders list.
    private func lidiaRemindersList() -> EKCalendar? {
        // Look for existing
        let calendars = store.calendars(for: .reminder)
        if let existing = calendars.first(where: { $0.title == "LidIA" }) {
            return existing
        }
        // Create new
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "LidIA"
        calendar.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            Self.logger.error("Failed to create LidIA reminders list: \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates or updates an EKReminder for an action item. Returns the reminder identifier.
    func syncReminder(
        reminderID: String?,
        title: String,
        deadlineText: String?,
        deadlineDate: Date?,
        isCompleted: Bool
    ) async -> String? {
        if !remindersAccessGranted {
            await requestRemindersAccess()
        }
        guard remindersAccessGranted else { return nil }
        guard let calendar = lidiaRemindersList() else { return nil }

        let reminder: EKReminder
        if let reminderID,
           let existingReminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder {
            reminder = existingReminder
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
        }

        reminder.title = title
        reminder.calendar = calendar
        reminder.isCompleted = isCompleted
        reminder.dueDateComponents = deadlineDate.map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        }
        if deadlineDate == nil,
           let deadlineText,
           !deadlineText.isEmpty {
            reminder.notes = "Due: \(deadlineText)"
        } else {
            reminder.notes = nil
        }

        do {
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        } catch {
            Self.logger.error("Failed to create reminder: \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates an EKReminder for an action item. Returns the reminder identifier.
    func createReminder(title: String, deadline: String?) async -> String? {
        await syncReminder(
            reminderID: nil,
            title: title,
            deadlineText: deadline,
            deadlineDate: nil,
            isCompleted: false
        )
    }

    /// Updates an EKReminder's completion status.
    func updateReminderCompletion(reminderID: String, isCompleted: Bool) {
        guard let item = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        item.isCompleted = isCompleted
        try? store.save(item, commit: true)
    }

    /// Syncs completion status FROM Reminders back to the app.
    /// Returns a dictionary of reminderID → isCompleted.
    func syncReminderStatuses(reminderIDs: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for id in reminderIDs {
            if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
                result[id] = item.isCompleted
            }
        }
        return result
    }

    // MARK: - Notifications

    private static var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestNotificationPermission() {
        guard canUseNotifications else {
            Self.logger.warning("Notifications unavailable — no bundle identifier (running outside .app bundle)")
            return
        }
        // The async API, not the completion handler: written here, that handler would be
        // main-actor isolated, and UserNotifications calls it on a background queue, which
        // traps in Swift 6.
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    static func registerNotificationCategories() {
        guard canUseNotifications else { return }

        let joinAndRecord = UNNotificationAction(
            identifier: "JOIN_AND_RECORD",
            title: "Join & Record",
            options: [.foreground]
        )
        let record = UNNotificationAction(
            identifier: "RECORD_MEETING",
            title: "Record",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )

        let preMeeting = UNNotificationCategory(
            identifier: "MEETING_PRE",
            actions: [joinAndRecord, dismiss],
            intentIdentifiers: []
        )
        let atMeeting = UNNotificationCategory(
            identifier: "MEETING_AT_TIME",
            actions: [record, dismiss],
            intentIdentifiers: []
        )

        let categories = Set([preMeeting, atMeeting])
            .union(NotificationDispatcher.notificationCategories())
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    private func scheduleNotifications(for events: [CalendarEvent], settings: AppSettings) {
        guard Self.canUseNotifications else { return }

        for event in events {
            let prepSummary = settings.prepNotificationsEnabled
                ? prepareSummary(for: event)
                : nil

            Self.scheduleEventNotifications(
                eventID: event.id,
                title: event.title,
                start: event.start,
                meetingLink: event.meetingLink,
                minutesBefore: settings.notifyUpcomingMeetings ? [settings.meetingNotificationMinutes, 1] : [],
                includeRecordPrompt: settings.calendarRecordPromptEnabled,
                prepSummary: prepSummary
            )
        }
    }

    /// Shared notification scheduler that works for any calendar source (Apple, Google, etc.)
    /// Sends exactly 2 notifications per event:
    /// 1. 5 minutes before — "Join & Record" action
    /// 2. At meeting time — "Record" prompt (suppressed if already recording)
    static func scheduleEventNotifications(
        eventID: String,
        title: String,
        start: Date,
        meetingLink: URL?,
        minutesBefore: [Int] = [],
        includeRecordPrompt: Bool = true,
        prepSummary: String? = nil
    ) {
        guard canUseNotifications else { return }

        let center = UNUserNotificationCenter.current()
        let now = Date()
        let linkString = meetingLink?.absoluteString ?? ""

        // 1) 5 minutes before — "Meeting Soon" with Join & Record
        let preDate = start.addingTimeInterval(-5 * 60)
        if preDate.timeIntervalSince(now) > 0 {
            let content = UNMutableNotificationContent()
            content.title = "Meeting Soon"
            content.body = "\(title) starts in 5 minutes"
            content.sound = .default
            content.categoryIdentifier = "MEETING_PRE"
            content.userInfo = [
                "eventID": eventID,
                "eventTitle": title,
                "meetingLink": linkString,
                "notificationType": "preMeeting"
            ]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: preDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "lidia.pre.\(eventID)",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }

        // 2) At meeting time — "Record [title]?" prompt
        if start.timeIntervalSince(now) > 0 {
            let content = UNMutableNotificationContent()
            content.title = "Record \(title)?"
            content.body = "Your meeting is starting now"
            content.sound = .default
            content.categoryIdentifier = "MEETING_AT_TIME"
            content.userInfo = [
                "eventID": eventID,
                "eventTitle": title,
                "meetingLink": linkString,
                "notificationType": "recordPrompt"
            ]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: start
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "lidia.record.\(eventID)",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }

    private func prepareSummary(for event: CalendarEvent) -> String? {
        guard !event.attendees.isEmpty, let context = backgroundContext else { return nil }
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let meetings = try? context.fetch(descriptor) else { return nil }
        let completed = meetings.filter { $0.status == .complete }
        guard !completed.isEmpty else { return nil }
        return MeetingContextRetrievalService.buildPrepSummary(attendees: event.attendees, meetings: completed)
    }

    // MARK: - Meeting Link Extraction

    private static let meetingLinkPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com)[^\s]*"#,
        options: .caseInsensitive
    )

    private static func extractMeetingLink(from event: EKEvent) -> URL? {
        if let url = event.url, isMeetingURL(url) {
            return url
        }
        // Scan notes and location for meeting URLs
        for text in [event.notes, event.location].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = meetingLinkPattern.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text) {
                return URL(string: String(text[matchRange]))
            }
        }
        return nil
    }

    private static func isMeetingURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("zoom.us") || host.contains("meet.google.com") || host.contains("teams.microsoft.com")
    }
}

// MARK: - Intents (free time and moving events)

extension EventKitManager {
    /// Timed and all-day events in visible calendars, for free-time search.
    /// Includes other people's calendars the user can see. Empty without access.
    func intentEvents(from start: Date, to end: Date, hidden: [String]) -> [IntentCalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return CalendarVisibility.visible(store.events(matching: predicate), hidden: hidden, calendarID: { $0.calendar?.calendarIdentifier })
            .compactMap { event -> IntentCalendarEvent? in
                let identifier: String? = event.eventIdentifier
                let startDate: Date? = event.startDate
                let endDate: Date? = event.endDate
                guard let identifier, let startDate, let endDate else { return nil }
                let title: String? = event.title
                let attendees = event.attendees?.compactMap { participant -> String? in
                    let email = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    return email.contains("@") ? email : participant.name
                } ?? []
                // The user organizes it (or nobody else is invited) and the calendar is writable.
                let organizedByUser = event.organizer == nil || event.organizer?.isCurrentUser == true
                return IntentCalendarEvent(
                    id: identifier, title: title ?? "Untitled", start: startDate, end: endDate,
                    attendees: attendees, isAllDay: event.isAllDay, source: "apple",
                    editable: event.calendar?.allowsContentModifications == true && organizedByUser,
                    calendarName: event.calendar?.title ?? ""
                )
            }
    }

    /// Moves one occurrence of an event. Only call this after the user
    /// confirmed: saving an event the user organizes updates attendees' invites.
    func moveEvent(id: String, to start: Date, end: Date) throws {
        guard let event = store.event(withIdentifier: id) else { throw CocoaError(.fileNoSuchFile) }
        guard event.calendar?.allowsContentModifications == true else { throw CocoaError(.fileWriteNoPermission) }
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
    }
}

/// Apple Calendar through EventKit, plus Google Calendar events LidIA
/// downloaded (read-only), as one source for intents.
@MainActor
final class LiveIntentCalendar: IntentCalendarSource {
    let eventKit: EventKitManager
    let google: GoogleCalendarMonitor?
    let hidden: [String]

    init(eventKit: EventKitManager, google: GoogleCalendarMonitor?, hidden: [String]) {
        self.eventKit = eventKit
        self.google = google
        self.hidden = hidden
    }

    var isAvailable: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess || google?.isSignedIn == true
    }

    func events(from start: Date, to end: Date) -> [IntentCalendarEvent] {
        var events = eventKit.intentEvents(from: start, to: end, hidden: hidden)
        if let google, google.isSignedIn {
            for event in google.weekEvents where event.end > start && event.start < end {
                // The same meeting synced to Apple Calendar wins: LidIA can edit that one.
                if events.contains(where: { $0.title == event.title && abs($0.start.timeIntervalSince(event.start)) < 60 }) { continue }
                events.append(IntentCalendarEvent(
                    id: event.id, title: event.title, start: event.start, end: event.end,
                    attendees: event.attendees, source: "google", editable: false
                ))
            }
        }
        return events
    }

    func move(eventID: String, to start: Date, end: Date) throws {
        try eventKit.moveEvent(id: eventID, to: start, end: end)
    }
}
