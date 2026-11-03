import Foundation
import Testing
@testable import LidIA

// Part of the serialized Local-only suite: it flips the same global setting.
extension LocalOnlyModeTests {

    @Test("The privacy list marks integrations as blocked")
    func disclosureReflectsMode() async {
        let defaults = UserDefaults.standard
        let keys = ["n8nEnabled", "n8nWebhookURL", "n8nSendTranscript"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        await withLocalOnly(false) {
            let settings = AppSettings()
            settings.n8nEnabled = true
            settings.n8nWebhookURL = "https://n8n.example.com/hook"
            settings.n8nSendTranscript = false

            let open = PrivacyDisclosure(settings: settings).items.first { $0.id == "n8n" }
            #expect(open?.status == .leavesMac)
            #expect(open?.detail.contains("transcript") == false)

            settings.n8nSendTranscript = true
            let withTranscript = PrivacyDisclosure(settings: settings).items.first { $0.id == "n8n" }
            #expect(withTranscript?.detail.contains("the full transcript") == true)

            settings.localOnlyMode = true
            let blocked = PrivacyDisclosure(settings: settings).items.first { $0.id == "n8n" }
            #expect(blocked?.status == .blockedByLocalOnly)
            let logos = PrivacyDisclosure(settings: settings).items.first { $0.id == "logos" }
            #expect(logos?.status == .staysOnMac)
        }
    }
}
