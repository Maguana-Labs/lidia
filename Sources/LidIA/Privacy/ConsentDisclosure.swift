import AppKit
import SwiftUI

/// Text and helpers for telling meeting participants that AI notes are in use.
enum ConsentDisclosure {
    /// The line added to a calendar invite. Also used to detect it was already added.
    static let calendarLine = "AI notes in use: this meeting may be transcribed and summarized with LidIA. Tell the organizer if you'd rather not be recorded."

    /// A short message to paste into the meeting chat or an email.
    static func chatMessage(displayName: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "I'm" : "\(name) here, I'm"
        return "Hi all, \(who) using LidIA to take AI notes of this call. It transcribes and summarizes on my Mac. Let me know if you'd rather I didn't."
    }

    /// Returns `notes` with the disclosure line appended, or `nil` if it is already there.
    static func notesAddingDisclosure(to notes: String?) -> String? {
        let existing = notes ?? ""
        if existing.contains(calendarLine) { return nil }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? calendarLine : "\(trimmed)\n\n\(calendarLine)"
    }

    @MainActor
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Settings row: preview and copy the disclosure message, and explain the
/// calendar option.
struct ConsentDisclosureActions: View {
    let settings: AppSettings
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ConsentDisclosure.chatMessage(displayName: settings.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(copied ? "Copied" : "Copy disclosure message") {
                    ConsentDisclosure.copyToPasteboard(ConsentDisclosure.chatMessage(displayName: settings.displayName))
                    copied = true
                }
                .buttonStyle(.glass)
            }
            Text("For Apple Calendar events you organize, the meeting page can also add an \"AI notes in use\" line to the invite. Google Calendar is connected read-only, so LidIA can't edit those invites.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Button the meeting page can show for an Apple Calendar event. Adds the
/// "AI notes in use" line to the event's notes. Saving an event you organize
/// can update attendees' copies, so it only runs when the user clicks it.
struct ConsentCalendarInviteButton: View {
    let eventKitManager: EventKitManager
    let eventID: String

    @State private var result: EventKitManager.DisclosureResult?

    var body: some View {
        HStack(spacing: 6) {
            Button("Add \"AI notes in use\" to invite") {
                result = eventKitManager.addAINotesDisclosure(toEventID: eventID)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(result == .added || result == .alreadyPresent)

            if let result {
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
