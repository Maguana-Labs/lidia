import SwiftUI

struct PrivacyPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(pane: .privacy) {
            PrivacySettingsSection(settings: settings)
        }
    }
}
