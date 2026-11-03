import AppKit
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Post to open the "Import from Granola" sheet in the main window.
    static let lidiaOpenGranolaImport = Notification.Name("lidia.openGranolaImport")
    /// Posted by the sheet's "Show in LidIA"; `object` is the folder name.
    static let lidiaShowImportedFolder = Notification.Name("lidia.showImportedFolder")
}

/// "Import from Granola…": sign in, watch progress, see what came in.
///
/// Standalone: present it anywhere that has a model container in its
/// environment. The import itself lives in `GranolaImportController.shared`,
/// so closing the sheet doesn't stop it.
struct GranolaImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var controller = GranolaImportController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 460)
        .frame(minHeight: 240)
        .task { await controller.refreshSignInState() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from Granola")
                    .font(.title3.bold())
                Text("Copies every Granola meeting into LidIA with its summary, private notes, attendees and full transcript. Nothing goes through AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            idleContent
        case .signingIn:
            statusRow("Finish signing in to Granola in your browser…")
        case .enterCode(let code):
            deviceCodeContent(code)
        case .working(let progress):
            progressContent(progress)
        case .finished(let summary):
            summaryContent(summary)
        case .failed(let message):
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isSignedIn {
                Label("Signed in to Granola", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Toggle("Also refresh meetings imported before", isOn: $controller.refreshExisting)
                    .help("Downloads them again. Anything you edited in LidIA stays as you left it.")
            } else {
                Text("You'll sign in to Granola in your browser. LidIA keeps the sign-in in your Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Meetings land in a “Granola” folder. Running the import again picks up where it stopped and doesn't make duplicates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if PrivacyGate.isLocalOnly {
                Text("Local-only mode is on. Importing still works: LidIA only downloads from Granola and sends none of your LidIA meetings anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func deviceCodeContent(_ code: GranolaDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In the browser page that opened, confirm this code:")
                .foregroundStyle(.secondary)
            Text(code.userCode)
                .font(.system(.title, design: .monospaced).bold())
                .textSelection(.enabled)
            HStack {
                Button("Open Granola Sign-In") { NSWorkspace.shared.open(code.verificationURL) }
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func progressContent(_ progress: GranolaImportProgress) -> some View {
        switch progress {
        case .connecting:
            statusRow("Connecting to Granola…")
        case .listing(let found, let total):
            VStack(alignment: .leading, spacing: 6) {
                if let total, total > 0 {
                    ProgressView(value: Double(found), total: Double(total))
                    Text("Finding your meetings… \(found) of \(total)")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    statusRow("Finding your meetings… \(found)")
                }
            }
        case .importing(let done, let total, let title, let alreadyImported):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Importing \(done) of \(total) · \(title.isEmpty ? "Untitled meeting" : title)")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if alreadyImported > 0 {
                    Text("\(alreadyImported) already in LidIA, skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summaryContent(_ summary: GranolaImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.cancelled ? "Import stopped" : "Import finished")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    countCell("Imported", summary.imported)
                    countCell("Updated", summary.updated)
                    countCell("Skipped", summary.skipped)
                    countCell("Failed", summary.failed)
                }
            }
            if summary.cancelled {
                Text("Run the import again to continue where it stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if summary.notReady > 0 {
                Text("\(summary.notReady) \(summary.notReady == 1 ? "meeting is" : "meetings are") still being processed by Granola. Import again later to get \(summary.notReady == 1 ? "it" : "them").")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.failures.isEmpty {
                DisclosureGroup("What failed") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                                Text("\(failure.title): \(failure.reason)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                Text("Import again to retry the ones that failed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func countCell(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var footer: some View {
        HStack {
            if case .idle = controller.phase, controller.isSignedIn {
                Button("Sign Out of Granola") { controller.signOut() }
                    .buttonStyle(.accentLink)
            }
            Spacer()
            switch controller.phase {
            case .idle:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(controller.isSignedIn ? "Import" : "Sign in to Granola") {
                    controller.start(container: modelContext.container)
                }
                .keyboardShortcut(.defaultAction)
            case .signingIn, .enterCode, .working:
                Button("Hide") { dismiss() }
                    .help("The import keeps going. Open File › Import from Granola… to check on it.")
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished(let summary):
                Button("Done") {
                    controller.reset()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if summary.cancelled || summary.failed > 0 || summary.notReady > 0 {
                    Button("Import Again") { controller.start(container: modelContext.container) }
                }
                Button("Show in LidIA") {
                    controller.reset()
                    NotificationCenter.default.post(name: .lidiaShowImportedFolder, object: GranolaImportStore.folderName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(summary.imported + summary.updated + summary.skipped == 0)
            case .failed:
                Button("Close") {
                    controller.reset()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(controller.isSignedIn ? "Try Again" : "Sign in to Granola") {
                    controller.start(container: modelContext.container)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
