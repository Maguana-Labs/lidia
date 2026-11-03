import Foundation
import Testing
@testable import LidIA

@Suite("Consent kit")
@MainActor
struct ConsentKitTests {

    @Test("Reminder shows until dismissed, and always in all-party mode")
    func reminderRules() {
        #expect(ConsentReminder.shouldShowConsentReminder(reminderEnabled: true, allPartyConsentMode: false))
        #expect(!ConsentReminder.shouldShowConsentReminder(reminderEnabled: false, allPartyConsentMode: false))
        #expect(ConsentReminder.shouldShowConsentReminder(reminderEnabled: false, allPartyConsentMode: true))
        #expect(ConsentReminder.shouldShowConsentReminder(reminderEnabled: true, allPartyConsentMode: true))
    }

    @Test("Don't show again is ignored in all-party-consent mode")
    func dismissal() {
        let defaults = UserDefaults.standard
        let keys = ["consentReminderEnabled", "allPartyConsentMode"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        let settings = AppSettings()
        #expect(settings.consentReminderEnabled)
        #expect(ConsentReminder.shouldShowConsentReminder(settings: settings))

        settings.allPartyConsentMode = true
        ConsentReminder.dismissPermanently(settings: settings)
        #expect(settings.consentReminderEnabled)
        #expect(ConsentReminder.shouldShowConsentReminder(settings: settings))

        settings.allPartyConsentMode = false
        ConsentReminder.dismissPermanently(settings: settings)
        #expect(!ConsentReminder.shouldShowConsentReminder(settings: settings))
        #expect(AppSettings().consentReminderEnabled == false)
    }

    @Test("Calendar disclosure is added once")
    func calendarLine() {
        let first = ConsentDisclosure.notesAddingDisclosure(to: "Agenda: roadmap")
        #expect(first?.hasPrefix("Agenda: roadmap") == true)
        #expect(first?.contains(ConsentDisclosure.calendarLine) == true)
        #expect(ConsentDisclosure.notesAddingDisclosure(to: first) == nil)
        #expect(ConsentDisclosure.notesAddingDisclosure(to: nil) == ConsentDisclosure.calendarLine)
    }

    @Test("Chat message names the user when known")
    func chatMessage() {
        #expect(ConsentDisclosure.chatMessage(displayName: "Alex").contains("Alex here"))
        #expect(ConsentDisclosure.chatMessage(displayName: "  ").hasPrefix("Hi all, I'm using LidIA"))
    }
}

