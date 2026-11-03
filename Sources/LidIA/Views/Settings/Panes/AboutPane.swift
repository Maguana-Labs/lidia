import LidIAKit
import SwiftUI

struct AboutPane: View {
    @Environment(UpdateController.self) private var updateController

    private static let website = URL(string: "https://lidia-app.github.io")!
    private static let issues = URL(string: "https://github.com/Maguana-Labs/lidia/issues")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(pane: .about) {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LidIA")
                            .font(.title2.weight(.semibold))
                        Text("Version \(version)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        DedicationLine()
                            .padding(.top, 4)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .settingsAnchor(.version)
            }

            Section("Updates") {
                LabeledContent {
                    Button("Check for Updates") { updateController.checkForUpdates() }
                        .disabled(!updateController.canCheckForUpdates)
                } label: {
                    Text("Software update")
                    if let reason = updateController.unavailableReason {
                        Text(reason)
                    } else if let last = updateController.lastUpdateCheckDate {
                        Text("Last checked \(last.formatted(.relative(presentation: .named))).")
                    } else {
                        Text("Updates are signed and checked before they install.")
                    }
                }
                .settingsAnchor(.checkUpdates)

                if updateController.canCheckForUpdates {
                    Toggle(isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { updateController.automaticallyChecksForUpdates = $0 }
                    )) {
                        Text("Check automatically")
                        Text("Looks for a new version once a day.")
                    }
                    .settingsAnchor(.autoUpdates)
                }
            }

            Section("Help") {
                Link(destination: Self.website) {
                    LabeledContent("Website") {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.accentLink)
                Link(destination: Self.issues) {
                    LabeledContent("Report a problem") {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.accentLink)
            }
        }
    }
}

/// The quiet line in About: whose name the app carries. The wording lives in
/// `LidIABrand.dedication` (LidIAKit), shared with the iPhone.
private struct DedicationLine: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Brand.red)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(LidIABrand.dedication)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
