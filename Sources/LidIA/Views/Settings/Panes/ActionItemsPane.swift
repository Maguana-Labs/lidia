import SwiftUI

struct ActionItemsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(pane: .actionItems) {
            Section("Apple Reminders") {
                Toggle(isOn: $settings.remindersEnabled) {
                    Text("Sync to Apple Reminders")
                    Text("Adds action items to a \u{201C}LidIA\u{201D} list. Checking one off syncs both ways.")
                }
                .settingsAnchor(.remindersSync)

                if settings.remindersEnabled {
                    Picker(selection: $settings.remindersMyItemsOnly) {
                        Text("Assigned to me").tag(true)
                        Text("All items").tag(false)
                    } label: {
                        Text("Which items")
                        Text(settings.displayName.isEmpty
                             ? "Add your name in General so LidIA can tell which are yours."
                             : "LidIA knows yours by your name, \(settings.displayName).")
                    }
                    .settingsAnchor(.remindersWho)

                    Toggle(isOn: $settings.remindersAutoSend) {
                        Text("Add them after each meeting")
                        Text("Off: add them yourself from the meeting page.")
                    }
                }
            }

            Section("Board") {
                Toggle(isOn: $settings.commentToAIEnabled) {
                    Text("Comment to AI on cards")
                    Text("Write on a card what you want (“open a ClickUp ticket for this”) and AI proposes the action. Nothing is sent until you confirm. Each card can turn it off.")
                }
            }

            Section("Projects") {
                Toggle(isOn: $settings.autoAssignProjects) {
                    Text("Add meetings to projects automatically")
                    Text("Only when LidIA is all but certain, such as the next meeting of a series already in the project. Otherwise it asks with ✓ / ✕. Worked out on this Mac.")
                }
            }

            Section("Autopilot") {
                Toggle(isOn: $settings.autopilotEnabled) {
                    Text("Send action items automatically")
                    Text("After each meeting, sends every item where AI suggests: ClickUp, Notion, Reminders or n8n.")
                }
                .settingsAnchor(.autopilot)

                if settings.autopilotEnabled && settings.localOnlyMode {
                    LocalOnlyModeBanner(message: "Local-only mode is on: only Apple Reminders, which stay on this Mac, are used.")
                }
            }
        }
    }
}
