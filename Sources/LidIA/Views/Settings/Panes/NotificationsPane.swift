import SwiftUI

// MARK: - Mapping onto the stored settings

/// Maps the consolidated Notifications controls onto the properties the
/// scheduler and planner already read, so behavior is unchanged.
@MainActor
enum NotificationPreferences {
    static let reminderChoices = [1, 2, 5, 10, 15]
    static let nudgeChoices = [5, 10, 15, 30, 60]

    /// Minutes before a meeting LidIA prompts, or nil when no prompt fires.
    /// Same rule as `PreMeetingPromptPlanner.Config.leadMinutes`.
    static func reminderMinutes(_ settings: AppSettings) -> Int? {
        ProactiveScheduler.promptConfig(from: settings).leadMinutes
    }

    /// Off turns every pre-meeting prompt off. A number turns the reminder on
    /// at that lead time (it includes Record and Join buttons).
    static func setReminderMinutes(_ minutes: Int?, _ settings: AppSettings) {
        if let minutes {
            settings.meetingNotificationMinutes = minutes
            settings.notifyUpcomingMeetings = true
        } else {
            settings.notifyUpcomingMeetings = false
            settings.calendarRecordPromptEnabled = false
            settings.proactivePreMeetingPrep = false
            settings.prepNotificationsEnabled = false
        }
    }

    /// Prep notes come from either of two older switches; keep them together.
    static func showsPrepNotes(_ settings: AppSettings) -> Bool {
        settings.proactivePreMeetingPrep || settings.prepNotificationsEnabled
    }

    static func setShowsPrepNotes(_ on: Bool, _ settings: AppSettings) {
        settings.proactivePreMeetingPrep = on
        settings.prepNotificationsEnabled = on
    }

    enum Digest: String, CaseIterable, Identifiable {
        case off, daily, monday
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .daily: "Every day"
            case .monday: "Mondays"
            }
        }
    }

    static func digest(_ settings: AppSettings) -> Digest {
        guard settings.proactiveMorningDigest else { return .off }
        return Digest(rawValue: settings.proactiveMorningDigestFrequency) ?? .daily
    }

    static func setDigest(_ digest: Digest, _ settings: AppSettings) {
        switch digest {
        case .off:
            settings.proactiveMorningDigest = false
        case .daily, .monday:
            settings.proactiveMorningDigestFrequency = digest.rawValue
            settings.proactiveMorningDigest = true
        }
    }

    /// Choices for a picker, with the stored value added if it isn't one.
    static func choices(_ base: [Int], including value: Int?) -> [Int] {
        guard let value, !base.contains(value) else { return base }
        return (base + [value]).sorted()
    }
}

// MARK: - Shared reminder picker

/// "Remind me before meetings", shown in Notifications and Calendars.
struct MeetingReminderPicker: View {
    @Bindable var settings: AppSettings
    var title = "Remind me"
    var detail = "One alert per meeting, with Record and Join buttons."

    var body: some View {
        let current = NotificationPreferences.reminderMinutes(settings)
        Picker(selection: Binding<Int>(
            get: { current ?? 0 },
            set: { minutes in
                NotificationPreferences.setReminderMinutes(minutes == 0 ? nil : minutes, settings)
                if minutes != 0 { EventKitManager.requestNotificationPermission() }
            }
        )) {
            Text("Off").tag(0)
            Divider()
            ForEach(NotificationPreferences.choices(NotificationPreferences.reminderChoices, including: current), id: \.self) { minutes in
                Text("\(minutes) min before").tag(minutes)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Pane

struct NotificationsPane: View {
    @Bindable var settings: AppSettings
    @Environment(ProactiveScheduler.self) private var proactiveScheduler
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor

    private var hasCalendar: Bool {
        settings.calendarEnabled || (googleCalendarMonitor.isSignedIn && settings.googleCalendarEnabled)
    }

    var body: some View {
        SettingsPage(pane: .notifications) {
            if !hasCalendar {
                Section {
                    LabeledContent {
                        Button("Connect a Calendar") { SettingsRouter.shared.show(.calendars) }
                    } label: {
                        Text("No calendar connected")
                        Text("Meeting reminders and nudges follow your calendar.")
                    }
                }
            }

            Section("Before a meeting") {
                MeetingReminderPicker(settings: settings)
                    .settingsAnchor(.meetingReminder)

                if NotificationPreferences.reminderMinutes(settings) != nil {
                    Toggle(isOn: Binding(
                        get: { NotificationPreferences.showsPrepNotes(settings) },
                        set: { NotificationPreferences.setShowsPrepNotes($0, settings) }
                    )) {
                        Text("Show prep notes")
                        Text("Adds what you discussed last time and open action items.")
                    }
                    .settingsAnchor(.prepNotes)
                }
            }

            Section("After a meeting") {
                Toggle(isOn: $settings.proactivePostMeetingNudge) {
                    Text("Nudge me to review")
                    Text("If a meeting on your calendar didn't get notes.")
                }
                .settingsAnchor(.reviewNudge)

                if settings.proactivePostMeetingNudge {
                    Picker("Send it after", selection: $settings.proactivePostMeetingMinutes) {
                        ForEach(NotificationPreferences.choices(NotificationPreferences.nudgeChoices,
                                                                including: settings.proactivePostMeetingMinutes), id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                }
            }

            Section("Every morning") {
                Picker(selection: Binding(
                    get: { NotificationPreferences.digest(settings) },
                    set: { NotificationPreferences.setDigest($0, settings) }
                )) {
                    ForEach(NotificationPreferences.Digest.allCases) { digest in
                        Text(digest.title).tag(digest)
                    }
                } label: {
                    Text("Morning digest")
                    Text("Today's meetings and what's due.")
                }
                .settingsAnchor(.morningDigest)

                Toggle(isOn: $settings.proactiveActionItemReminders) {
                    Text("Action item reminders")
                    Text(settings.proactiveMorningDigest
                         ? "Due and overdue items are part of the digest."
                         : "A note each morning when something is due.")
                }
                .settingsAnchor(.actionItemReminders)

                if settings.proactiveMorningDigest || settings.proactiveActionItemReminders {
                    DatePicker("Time", selection: $settings.proactiveMorningDigestTime, displayedComponents: .hourAndMinute)
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        DatePicker("From", selection: $settings.proactiveQuietStart, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("to")
                            .foregroundStyle(.secondary)
                        DatePicker("To", selection: $settings.proactiveQuietEnd, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                } label: {
                    Text("Quiet hours")
                    Text("No reminders, nudges or digests between these times.")
                }
                .settingsAnchor(.quietHours)
            }
        }
        .onChange(of: ProactiveSignature(settings)) { _, _ in refreshProactiveScheduler() }
    }

    private func refreshProactiveScheduler() {
        if settings.proactiveMorningDigest
            || settings.proactivePreMeetingPrep
            || settings.proactivePostMeetingNudge
            || settings.proactiveActionItemReminders {
            Task { _ = await NotificationDispatcher.requestPermission() }
        }
        proactiveScheduler.startTimers()
    }
}

/// Everything the proactive scheduler reads, to restart it on any change.
private struct ProactiveSignature: Equatable {
    let values: [AnyHashable]

    @MainActor
    init(_ settings: AppSettings) {
        values = [
            settings.proactiveMorningDigest, settings.proactiveMorningDigestTime,
            settings.proactiveMorningDigestFrequency, settings.proactivePreMeetingPrep,
            settings.proactivePreMeetingMinutes, settings.proactivePostMeetingNudge,
            settings.proactivePostMeetingMinutes, settings.proactiveActionItemReminders,
            settings.proactiveQuietStart, settings.proactiveQuietEnd,
        ]
    }
}
