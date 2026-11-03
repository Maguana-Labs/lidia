import Foundation
import Testing
@testable import LidIA

/// Runs `body` with Local-only mode set to `on`, then restores the old value.
@MainActor
func withLocalOnly(_ on: Bool, _ body: () async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: PrivacyGate.localOnlyModeKey)
    defaults.set(on, forKey: PrivacyGate.localOnlyModeKey)
    defer {
        if let previous { defaults.set(previous, forKey: PrivacyGate.localOnlyModeKey) }
        else { defaults.removeObject(forKey: PrivacyGate.localOnlyModeKey) }
    }
    try await body()
}

@Suite("Local-only mode", .serialized)
@MainActor
struct LocalOnlyModeTests {

    @Test("Defaults to off and persists through the didSet pattern")
    func settingPersists() async {
        await withLocalOnly(false) {
            UserDefaults.standard.removeObject(forKey: PrivacyGate.localOnlyModeKey)
            let settings = AppSettings()
            #expect(settings.localOnlyMode == false)
            #expect(PrivacyGate.isLocalOnly == false)

            settings.localOnlyMode = true
            #expect(UserDefaults.standard.bool(forKey: PrivacyGate.localOnlyModeKey))
            #expect(PrivacyGate.isLocalOnly)
            #expect(AppSettings().localOnlyMode)
        }
    }

    @Test("Local-only mode blocks every cloud AI purpose")
    func cloudAIGate() async {
        await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true
            for purpose in LLMCloudPurpose.allCases {
                #expect(!allowsCloud(for: purpose, settings: settings))
            }
            settings.localOnlyMode = false
            #expect(allowsCloud(for: .primary, settings: settings))
        }
    }

    @Test("The gate blocks every destination when on")
    func gateBlocks() async {
        await withLocalOnly(true) {
            for destination in PrivacyGate.Destination.allCases {
                #expect(!PrivacyGate.allows(destination))
                #expect(throws: PrivacyGate.LocalOnlyModeError(destination: destination)) {
                    try PrivacyGate.check(destination)
                }
            }
        }
        await withLocalOnly(false) {
            #expect(PrivacyGate.allows(.notion))
        }
    }

    @Test("Integration clients refuse to send in Local-only mode")
    func clientsRefuse() async {
        await withLocalOnly(true) {
            // An unroutable URL: if the gate failed, these would error out
            // differently (or hang), not throw LocalOnlyModeError.
            await #expect(throws: PrivacyGate.LocalOnlyModeError.self) {
                try await ClickUpClient.createTask(title: "t", description: "d", listID: "1", apiKey: "k")
            }
            await #expect(throws: PrivacyGate.LocalOnlyModeError.self) {
                _ = try await NotionClient(apiKey: "k").createMeetingPage(
                    databaseID: "db", title: "t", date: .now, duration: 1, bodyMarkdown: "b")
            }
            let sent = await N8nClient.sendDispatch(
                payload: .init(channel: "slack", recipient: nil, draft: "d", ticketTitle: nil,
                               meetingTitle: nil, actionItemTitle: nil, actionItemID: nil),
                webhookURL: "http://127.0.0.1:9/hook", authHeader: nil)
            #expect(sent == false)
        }
    }
}
