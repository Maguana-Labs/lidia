import Foundation
import SwiftData
import Testing
@testable import LidIA

// Part of the serialized Local-only suite: it flips the same global setting.
extension LocalOnlyModeTests {

    @Test("OpenAI chat uses the WebSocket only when the gate allows it, re-checked per send")
    func openAIChatStreamGated() async {
        let restore = saveDefaults(["llmProvider"])
        defer { restore() }
        #expect(ChatBarViewModel.chatStreamKind(
            chatProvider: .openai, defaultProvider: .openai,
            openAIAPIKey: "sk-test", openAIModel: "gpt-test", openAIAllowed: true
        ) == .openAIWebSocket(apiKey: "sk-test", model: "gpt-test"))
        #expect(ChatBarViewModel.chatStreamKind(
            chatProvider: .openai, defaultProvider: .openai,
            openAIAPIKey: "sk-test", openAIModel: "gpt-test", openAIAllowed: false
        ) == .http)
        #expect(ChatBarViewModel.chatStreamKind(
            chatProvider: .mlx, defaultProvider: .openai,
            openAIAPIKey: "sk-test", openAIModel: "gpt-test", openAIAllowed: true
        ) == .http)

        await withLocalOnly(true) {
            // The settings wrapper feeds the gate in: OpenAI is blocked in Local-only mode.
            let settings = AppSettings()
            settings.localOnlyMode = true
            settings.llmProvider = .openai
            #expect(ChatBarViewModel.chatStreamKind(settings: settings) == .http)
        }
    }

    @Test("The OpenAI WebSocket refuses to connect in Local-only mode")
    func webSocketBackstop() async {
        await withLocalOnly(true) {
            let stream = OpenAIWebSocketStream(apiKey: "sk-test", defaultModel: "gpt-test")
            var text = ""
            for await token in stream.send("hi", history: [], context: "secret meeting", attachments: [], model: "") {
                text += token
            }
            #expect(text.contains("Local-only mode is on"))
        }
    }

    @Test("Retry with a cloud provider in Local-only mode sends nothing and keeps the messages")
    func retryWithBlocked() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidia-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = Schema(versionedSchema: AppSchema.self)
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("t.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        await withLocalOnly(true) {
            let settings = AppSettings()
            settings.localOnlyMode = true
            let vm = ChatBarViewModel()
            vm.configure(settings: settings, modelContext: context)
            let user = ChatBarMessage(role: .user, text: "What did we decide?")
            let answer = ChatBarMessage(role: .assistant, text: "The roadmap.")
            vm.messages = [user, answer]

            vm.retryWith(messageID: answer.id, provider: .openai)

            #expect(!vm.isStreaming)
            #expect(vm.messages.count == 3)
            #expect(vm.messages[0].id == user.id)
            #expect(vm.messages[1].id == answer.id)
            #expect(vm.messages[2].text.contains("Not sent to OpenAI"))
        }
    }

    @Test("Sending to n8n from the meeting page is blocked in Local-only mode")
    func meetingWebhookBlocked() async {
        await withLocalOnly(true) {
            let payload = N8nClient.WebhookPayload(
                meetingTitle: "t", date: "d", duration: 1, summary: "s",
                actionItems: [], attendees: [], transcript: "secret"
            )
            await #expect(throws: PrivacyGate.LocalOnlyModeError.self) {
                try await MeetingWebhookSender.send(payload, to: "http://127.0.0.1:9/hook", authHeader: nil)
            }
        }
    }
}
