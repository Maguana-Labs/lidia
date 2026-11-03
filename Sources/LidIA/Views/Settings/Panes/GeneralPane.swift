import LidIAKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(pane: .general) {
            Section {
                Picker(selection: $settings.appearanceMode) {
                    ForEach(AppSettings.AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                } label: {
                    Text("Appearance")
                    Text("System follows your Mac's light or dark setting.")
                }
                .pickerStyle(.segmented)
                .settingsAnchor(.appearance)
            }

            Section("You") {
                LabeledContent {
                    TextField("Your name", text: $settings.displayName, prompt: Text("Add your name"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220)
                } label: {
                    Text("Your name")
                    Text("How LidIA finds your action items and labels you in transcripts.")
                }
                .settingsAnchor(.displayName)
            }

            Section("Assistant") {
                Picker(selection: $settings.assistantPersonality) {
                    ForEach(AppSettings.AssistantPersonality.allCases, id: \.self) { personality in
                        Text(personality.rawValue).tag(personality)
                    }
                } label: {
                    Text("Personality")
                    Text("The tone LidIA uses in chat and voice.")
                }
                .settingsAnchor(.personality)

                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Edit Instructions") { AssistantFiles.openSoul() }
                        Button("View Memory") { AssistantFiles.openMemory() }
                    }
                } label: {
                    Text("Instructions and memory")
                    Text("Your notes to LidIA, and what it has learned about you.")
                }
                .settingsAnchor(.soulMemory)
            }
        }
    }
}

/// SOUL.md (the user's instructions) and MEMORY.md (what LidIA remembers),
/// both in ~/.lidia/.
enum AssistantFiles {
    static func openSoul() {
        let path = LidIAFiles.soulFilePath
        ensureDirectory()
        if !FileManager.default.fileExists(atPath: path) {
            let template = """
                # LidIA Soul

                Write any instructions here. LidIA will follow them in voice and chat.
                This is your assistant's personality \u{2014} make it yours.

                Examples:
                - Respond in Spanish
                - I work at Acme Corp on the Platform team
                - When summarizing, focus on action items and decisions
                - Be concise, no fluff
                - Call me by my first name
                """
            try? template.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func openMemory() {
        let path = LidIAFiles.memoryFilePath
        ensureDirectory()
        if !FileManager.default.fileExists(atPath: path) {
            try? "# LidIA Memory\n\nThings I've learned about you:\n\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func ensureDirectory() {
        let dir = URL(fileURLWithPath: LidIAFiles.lidiaDir)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
