import Foundation
import Testing
@testable import LidIA

@Suite("Integration defaults")
@MainActor
struct IntegrationDefaultsTests {

    @Test("Auto-send and the n8n transcript default to off")
    func newDefaults() {
        let defaults = UserDefaults.standard
        let keys = ["notionAutoSend", "n8nAutoSend", "slackAutoSend", "n8nSendTranscript",
                    "n8nSendSummary", "n8nSendActionItems", IntegrationSettings.integrationDefaultsVersionKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(1, forKey: IntegrationSettings.integrationDefaultsVersionKey)

        let settings = IntegrationSettings()
        #expect(settings.notionAutoSend == false)
        #expect(settings.n8nAutoSend == false)
        #expect(settings.slackAutoSend == false)
        #expect(settings.n8nSendTranscript == false)
        #expect(settings.n8nSendSummary == true)
        #expect(settings.n8nSendActionItems == true)
    }

    @Test("Existing users keep stored values; configured integrations keep working")
    func migration() throws {
        let suite = "lidia-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Stored explicitly: never changed.
        defaults.set(false, forKey: "notionAutoSend")
        IntegrationSettings.migrateIntegrationDefaults(
            in: defaults, notionConfigured: true, n8nConfigured: true, slackConfigured: false)

        #expect(defaults.object(forKey: "notionAutoSend") as? Bool == false)
        // Configured but never touched: pinned to the old "on".
        #expect(defaults.object(forKey: "n8nAutoSend") as? Bool == true)
        #expect(defaults.object(forKey: "n8nSendTranscript") as? Bool == true)
        // Not configured: gets the new default (nothing stored).
        #expect(defaults.object(forKey: "slackAutoSend") == nil)

        // Runs once.
        defaults.removeObject(forKey: "n8nAutoSend")
        IntegrationSettings.migrateIntegrationDefaults(
            in: defaults, notionConfigured: true, n8nConfigured: true, slackConfigured: true)
        #expect(defaults.object(forKey: "n8nAutoSend") == nil)
        #expect(defaults.object(forKey: "slackAutoSend") == nil)
    }
}

