import Foundation
import Testing
@testable import LidIA

// MARK: - Search index

@Suite("Settings search")
struct SettingsSearchTests {
    private func top(_ query: String) -> SettingsAnchor? {
        SettingsSearchIndex.search(query).first?.anchor
    }

    private func anchors(_ query: String) -> [SettingsAnchor] {
        SettingsSearchIndex.search(query).map(\.anchor)
    }

    @Test("Every pane has search entries")
    func everyPaneHasEntries() {
        for pane in SettingsPane.allCases {
            #expect(SettingsSearchIndex.entries.contains { $0.pane == pane }, "No search entries for \(pane.title)")
        }
    }

    @Test("No two entries share an anchor or id")
    func anchorsAreUnique() {
        let anchors = SettingsSearchIndex.entries.map(\.anchor)
        #expect(Set(anchors).count == anchors.count)
        let ids = SettingsSearchIndex.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every anchor has exactly one entry")
    func everyAnchorIndexed() {
        let indexed = Set(SettingsSearchIndex.entries.map(\.anchor))
        for anchor in SettingsAnchor.allCases {
            #expect(indexed.contains(anchor), "\(anchor) is not searchable")
        }
    }

    @Test("Sub-page entries belong to their pane")
    func subpagesMatchPanes() {
        for entry in SettingsSearchIndex.entries {
            switch entry.location.subpage {
            case .vocabulary?: #expect(entry.pane == .recording)
            case .onDeviceModels?, .aiAdvanced?: #expect(entry.pane == .ai)
            case .integration?: #expect(entry.pane == .apps)
            case .template?: #expect(entry.pane == .notes)
            case nil: break
            }
        }
    }

    @Test("An exact title ranks first")
    func exactTitleFirst() {
        #expect(top("Quiet hours") == .quietHours)
        #expect(top("quiet hours") == .quietHours)
        #expect(top("Local-only mode") == .localOnly)
    }

    @Test("Synonyms and keywords find settings")
    func keywords() {
        #expect(top("dark mode") == .appearance)
        #expect(top("mcp") == .connectAIApps)
        #expect(top("google") == .googleCalendar)
        #expect(top("language") == .sttLanguage)
        #expect(top("microphone") == .captureMode)
        #expect(top("api key") == .apiKey)
        #expect(anchors("obsidian").contains(.markdownExport))
        #expect(top("do not disturb") == .quietHours)
    }

    @Test("Brand names reach every place they matter")
    func brandNames() {
        let claude = anchors("claude")
        #expect(claude.contains(.connectAIApps))
        #expect(claude.contains(.aiProvider))
        #expect(claude.contains(.apiKey))
        #expect(anchors("anthropic").contains(.aiProvider))
        #expect(anchors("anthropic").contains(.apiKey))
    }

    @Test("Reminder finds meeting, calendar and action item reminders")
    func reminder() {
        let results = anchors("reminder")
        #expect(results.contains(.meetingReminder))
        #expect(results.contains(.calendarReminder))
        #expect(results.contains(.remindersSync))
        #expect(results.contains(.actionItemReminders))
    }

    @Test("Title matches outrank keyword-only matches")
    func titleBeatsKeyword() {
        // "Model routing" has "routing" in its title; nothing else should beat it.
        #expect(top("routing") == .routing)
        let results = anchors("quiet")
        #expect(results.first == .quietHours || results.first == .autoStop)
        #expect(results.contains(.quietHours))
    }

    @Test("Every word must match")
    func allWordsMustMatch() {
        #expect(SettingsSearchIndex.search("quiet zebra").isEmpty)
        #expect(SettingsSearchIndex.search("xyzzy").isEmpty)
        #expect(SettingsSearchIndex.search("   ").isEmpty)
    }

    @Test("Case and accents don't matter")
    func folding() {
        #expect(top("QUIET HOURS") == .quietHours)
        #expect(top("appéarance") == .appearance)
    }

    @Test("Breadcrumb names the sub-page or Advanced")
    func breadcrumbs() {
        let fallback = SettingsSearchIndex.entries.first { $0.anchor == .fallback }
        #expect(fallback?.breadcrumb == "AI › Advanced")
        let vad = SettingsSearchIndex.entries.first { $0.anchor == .vadPrefilter }
        #expect(vad?.breadcrumb == "Recording › Advanced")
        let quiet = SettingsSearchIndex.entries.first { $0.anchor == .quietHours }
        #expect(quiet?.breadcrumb == "Notifications")
    }
}

// MARK: - Router

@Suite("Settings router", .serialized)
@MainActor
struct SettingsRouterTests {
    @Test("Remembers the last pane")
    func remembersPane() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "settings.lastPane")
        defer { defaults.set(saved, forKey: "settings.lastPane") }

        let router = SettingsRouter()
        router.pane = .calendars
        #expect(defaults.string(forKey: "settings.lastPane") == "calendars")
        #expect(SettingsRouter().pane == .calendars)
    }

    @Test("Show on the same pane pushes the sub-page")
    func showSubpage() {
        let router = SettingsRouter()
        router.pane = .ai
        router.show(.ai, subpage: .aiAdvanced, anchor: .fallback)
        #expect(router.pane == .ai)
        #expect(router.path == [.aiAdvanced])
        #expect(router.pendingTarget == SettingsLocation(pane: .ai, subpage: .aiAdvanced, anchor: .fallback))
    }

    @Test("Changing pane clears the pushed pages")
    func changingPaneClearsPath() {
        let router = SettingsRouter()
        router.pane = .ai
        router.path = [.aiAdvanced]
        router.pane = .privacy
        #expect(router.path.isEmpty)
    }

    @Test("Revealing an Advanced row expands Advanced")
    func revealExpandsAdvanced() {
        let router = SettingsRouter()
        router.reveal(SettingsLocation(pane: .recording, anchor: .vadPrefilter, inAdvanced: true))
        #expect(router.expandedAdvanced.contains(.recording))
        #expect(router.pane == .recording)
    }

    @Test("Scrolling clears the target and flashes the row")
    func scrollFlashes() {
        let router = SettingsRouter()
        let location = SettingsLocation(pane: .notifications, anchor: .quietHours)
        router.reveal(location)
        router.didScroll(to: location)
        #expect(router.pendingTarget == nil)
        #expect(router.highlighted == .quietHours)
    }
}

// MARK: - Calendar visibility

@Suite("Calendar visibility", .serialized)
struct CalendarVisibilityTests {
    struct Event { let id: String; let calendarID: String? }

    @Test("Hidden calendars' events are left out")
    func filters() {
        let events = [
            Event(id: "1", calendarID: "work"),
            Event(id: "2", calendarID: "home"),
            Event(id: "3", calendarID: nil),
            Event(id: "4", calendarID: ""),
        ]
        let visible = CalendarVisibility.visible(events, hidden: ["home"], calendarID: \.calendarID)
        #expect(visible.map(\.id) == ["1", "3", "4"])
        #expect(CalendarVisibility.visible(events, hidden: [], calendarID: \.calendarID).count == 4)
    }

    @Test("Toggling adds and removes without duplicates")
    func toggling() {
        var hidden: [String] = []
        hidden = CalendarVisibility.setting("a", visible: false, in: hidden)
        hidden = CalendarVisibility.setting("a", visible: false, in: hidden)
        hidden = CalendarVisibility.setting("b", visible: false, in: hidden)
        #expect(hidden == ["a", "b"])
        hidden = CalendarVisibility.setting("a", visible: true, in: hidden)
        #expect(hidden == ["b"])
        #expect(CalendarVisibility.isVisible("a", hidden: hidden))
        #expect(!CalendarVisibility.isVisible("b", hidden: hidden))
    }

    @Test("Hiding Google's primary calendar hides Google events")
    func google() {
        let events = [1, 2, 3]
        #expect(CalendarVisibility.visibleGoogleEvents(events, hidden: []) == events)
        #expect(CalendarVisibility.visibleGoogleEvents(events, hidden: [CalendarVisibility.googlePrimaryID]).isEmpty)
        #expect(CalendarVisibility.visibleGoogleEvents(events, hidden: ["some-apple-id"]) == events)
    }

    @MainActor
    @Test("hiddenCalendarIDs persists")
    func persists() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: "hiddenCalendarIDs") }
        defaults.removeObject(forKey: "hiddenCalendarIDs")
        #expect(CalendarSettings().hiddenCalendarIDs.isEmpty)

        let settings = CalendarSettings()
        settings.hiddenCalendarIDs = ["cal-1", CalendarVisibility.googlePrimaryID]
        #expect(CalendarSettings().hiddenCalendarIDs == ["cal-1", CalendarVisibility.googlePrimaryID])
    }

    @MainActor
    @Test("AppSettings forwards hiddenCalendarIDs")
    func forwards() {
        defer { UserDefaults.standard.removeObject(forKey: "hiddenCalendarIDs") }
        let settings = AppSettings()
        settings.hiddenCalendarIDs = ["x"]
        #expect(settings.calendar.hiddenCalendarIDs == ["x"])
    }
}

// MARK: - Notifications mapping

@Suite("Notification preferences", .serialized)
@MainActor
struct NotificationPreferencesTests {
    private static let keys = [
        "notifyUpcomingMeetings", "meetingNotificationMinutes", "calendarRecordPromptEnabled",
        "prepNotificationsEnabled", "proactivePreMeetingPrep", "proactivePreMeetingMinutes",
        "proactiveMorningDigest", "proactiveMorningDigestFrequency",
    ]

    private func freshSettings() -> AppSettings {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        return AppSettings()
    }

    private func cleanUp() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @Test("Shows the lead time the planner actually uses")
    func effectiveLead() {
        defer { cleanUp() }
        let settings = freshSettings()
        // Defaults: reminder off, prep on at 10 min, so the prompt fires at 10.
        #expect(NotificationPreferences.reminderMinutes(settings) == 10)
        settings.proactivePreMeetingPrep = false
        settings.prepNotificationsEnabled = false
        // Record prompt alone fires 2 minutes before.
        #expect(NotificationPreferences.reminderMinutes(settings) == 2)
    }

    @Test("Picking minutes turns the reminder on at that time")
    func setMinutes() {
        defer { cleanUp() }
        let settings = freshSettings()
        NotificationPreferences.setReminderMinutes(15, settings)
        #expect(settings.notifyUpcomingMeetings)
        #expect(settings.meetingNotificationMinutes == 15)
        #expect(ProactiveScheduler.promptConfig(from: settings).leadMinutes == 15)
    }

    @Test("Off means no pre-meeting prompt at all")
    func off() {
        defer { cleanUp() }
        let settings = freshSettings()
        NotificationPreferences.setReminderMinutes(nil, settings)
        #expect(ProactiveScheduler.promptConfig(from: settings).leadMinutes == nil)
        #expect(NotificationPreferences.reminderMinutes(settings) == nil)
        #expect(!NotificationPreferences.showsPrepNotes(settings))
    }

    @Test("Prep notes drive both older switches")
    func prepNotes() {
        defer { cleanUp() }
        let settings = freshSettings()
        NotificationPreferences.setShowsPrepNotes(false, settings)
        #expect(!settings.proactivePreMeetingPrep && !settings.prepNotificationsEnabled)
        NotificationPreferences.setShowsPrepNotes(true, settings)
        #expect(settings.proactivePreMeetingPrep && settings.prepNotificationsEnabled)
    }

    @Test("Digest picker maps onto digest and frequency")
    func digest() {
        defer { cleanUp() }
        let settings = freshSettings()
        #expect(NotificationPreferences.digest(settings) == .daily)
        NotificationPreferences.setDigest(.monday, settings)
        #expect(settings.proactiveMorningDigest && settings.proactiveMorningDigestFrequency == "monday")
        NotificationPreferences.setDigest(.off, settings)
        #expect(!settings.proactiveMorningDigest)
        #expect(NotificationPreferences.digest(settings) == .off)
    }

    @Test("Picker choices keep an unusual stored value")
    func choices() {
        #expect(NotificationPreferences.choices([1, 5], including: 20) == [1, 5, 20])
        #expect(NotificationPreferences.choices([1, 5], including: 5) == [1, 5])
        #expect(NotificationPreferences.choices([1, 5], including: nil) == [1, 5])
    }
}

// MARK: - Default template

@Suite("Default template", .serialized)
@MainActor
struct DefaultTemplateTests {
    @Test("Used when no rule matches, and persists")
    func defaultTemplate() {
        defer { UserDefaults.standard.removeObject(forKey: "defaultTemplateID") }
        UserDefaults.standard.removeObject(forKey: "defaultTemplateID")
        let settings = AppSettings()
        let meeting = Meeting(title: "Quarterly catch-up")
        #expect(settings.resolveTemplate(for: meeting).id == MeetingTemplate.general.id)

        settings.defaultTemplateID = MeetingTemplate.oneOnOne.id.uuidString
        #expect(settings.resolveTemplate(for: meeting).id == MeetingTemplate.oneOnOne.id)
        #expect(AppSettings().defaultTemplateID == MeetingTemplate.oneOnOne.id.uuidString)
    }

    @Test("A matching rule still wins over the default")
    func ruleWins() {
        defer { UserDefaults.standard.removeObject(forKey: "defaultTemplateID") }
        let settings = AppSettings()
        settings.defaultTemplateID = MeetingTemplate.oneOnOne.id.uuidString
        let standup = Meeting(title: "Daily standup")
        #expect(settings.resolveTemplate(for: standup).id == MeetingTemplate.standup.id)
    }

    @Test("A deleted default falls back to General")
    func missingDefault() {
        defer { UserDefaults.standard.removeObject(forKey: "defaultTemplateID") }
        let settings = AppSettings()
        settings.defaultTemplateID = UUID().uuidString
        #expect(settings.defaultTemplate.id == MeetingTemplate.general.id)
    }
}
