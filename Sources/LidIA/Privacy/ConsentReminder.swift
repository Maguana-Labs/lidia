import AppKit
import SwiftUI

// MARK: - Consent reminder (v1)
//
// Usage from the recording / meeting page (owned by another workstream):
//
//     if ConsentReminder.shouldShowConsentReminder(settings: settings) {
//         ConsentReminderView(settings: settings) { showReminder = false }
//     }
//
// The view handles "Don't show again" itself by turning off
// `settings.consentReminderEnabled`. It never blocks recording.

/// Decides when to show the "tell people you're taking AI notes" reminder.
enum ConsentReminder {
    /// Whether the reminder should show when a recording starts.
    ///
    /// - All-party-consent mode: always.
    /// - Otherwise: until the user picks "Don't show again".
    @MainActor
    static func shouldShowConsentReminder(settings: AppSettings) -> Bool {
        shouldShowConsentReminder(
            reminderEnabled: settings.consentReminderEnabled,
            allPartyConsentMode: settings.allPartyConsentMode
        )
    }

    static func shouldShowConsentReminder(reminderEnabled: Bool, allPartyConsentMode: Bool) -> Bool {
        allPartyConsentMode || reminderEnabled
    }

    /// Whether the reminder may offer "Don't show again".
    @MainActor
    static func canDismissPermanently(settings: AppSettings) -> Bool {
        !settings.allPartyConsentMode
    }

    /// Records "Don't show again". Has no effect in all-party-consent mode.
    @MainActor
    static func dismissPermanently(settings: AppSettings) {
        guard canDismissPermanently(settings: settings) else { return }
        settings.consentReminderEnabled = false
    }
}

/// Compact banner shown when a recording starts. Dismissible; offers
/// "Don't show again" unless all-party-consent mode is on, and a quick way to
/// copy a disclosure message to paste in the meeting chat.
struct ConsentReminderView: View {
    @Bindable var settings: AppSettings
    var onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let everyone know you're taking AI notes")
                        .font(.callout.weight(.semibold))
                    Text(settings.allPartyConsentMode
                         ? "Everyone on this call must agree before you record. Ask them, and stop recording if anyone says no."
                         : "Recording laws differ by place, and some require everyone's consent. Tell the people on this call that LidIA is transcribing it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close reminder")
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy message for the chat") {
                    ConsentDisclosure.copyToPasteboard(ConsentDisclosure.chatMessage(displayName: settings.displayName))
                    copied = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                if ConsentReminder.canDismissPermanently(settings: settings) {
                    Button("Don't show again") {
                        ConsentReminder.dismissPermanently(settings: settings)
                        onDismiss()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording consent reminder")
    }
}
