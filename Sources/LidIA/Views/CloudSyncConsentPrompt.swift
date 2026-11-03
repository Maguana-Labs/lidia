import SwiftUI

/// The one-time "Turn on iCloud sync?" question for a library that existed before sync.
/// New installs sync by default and never see it; Settings › Sync can change it later.
struct CloudSyncConsentPrompt: ViewModifier {
    let enabled: Bool

    private var runtime: CloudSyncRuntime { .shared }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { enabled && runtime.shouldAsk },
            set: { _ in }
        )
    }

    func body(content: Content) -> some View {
        content.alert("Turn on iCloud sync?", isPresented: isPresented) {
            Button("Turn On and Restart") {
                runtime.choice = .on
                // While recording, the change waits for the next launch.
                runtime.relaunch()
            }
            Button("Not Now", role: .cancel) {
                runtime.choice = .off
            }
        } message: {
            Text(Self.message)
        }
    }

    static let message = """
    LidIA can keep your meetings, notes, transcripts and action items in step on your Mac and iPhone, through your own iCloud account. Audio recordings stay on this Mac.

    Apple encrypts this data in transit and on its servers. It's end-to-end encrypted only if Advanced Data Protection is on for your Apple Account.

    LidIA backs up your library first, then restarts. You can turn sync off any time in Settings › Sync.
    """
}
