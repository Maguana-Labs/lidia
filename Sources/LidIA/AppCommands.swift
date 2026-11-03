import SwiftUI

/// Actions the main window publishes to the menu bar commands.
/// `ContentView` provides them with `.focusedSceneValue(\.appActions, …)`.
struct AppActions {
    var isRecording: Bool
    var newNote: () -> Void
    var quickNote: () -> Void
    /// Starts recording, or asks for confirmation before stopping.
    var toggleRecording: () -> Void
    var search: () -> Void
    var ask: () -> Void
    var showToday: () -> Void
    /// Present when a meeting is selected.
    var exportSelectedMeeting: (() -> Void)?
    var deleteSelectedMeeting: (() -> Void)?
}

extension FocusedValues {
    @Entry var appActions: AppActions?
}

/// App menu commands so every shortcut is discoverable from the menu bar.
///
/// ⌘N is New Note (it replaces New Window: LidIA is a single-window app and
/// the shortcut used to clash). ⌘R records; stopping asks first.
struct AppCommands: Commands {
    @FocusedValue(\.appActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
            Button("Quick Note") { actions?.quickNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Export Meeting as Markdown…") { actions?.exportSelectedMeeting?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.exportSelectedMeeting == nil)
            Divider()
            Button("Import from Granola…") {
                NotificationCenter.default.post(name: .lidiaOpenGranolaImport, object: nil)
            }
        }

        CommandMenu("Meeting") {
            Button(actions?.isRecording == true ? "Stop Recording…" : "Record") {
                actions?.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button("Delete Meeting…") { actions?.deleteSelectedMeeting?() }
                .disabled(actions?.deleteSelectedMeeting == nil)
        }

        CommandGroup(before: .sidebar) {
            Button("Today") { actions?.showToday() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Search") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Ask LidIA…") { actions?.ask() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions == nil)
            Divider()
        }
    }
}
