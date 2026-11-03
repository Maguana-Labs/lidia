import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Posted to open the Granola importer. The importer's own branch owns the
/// public name; this file-private copy uses the same raw string.

struct ImportPane: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showImportPreview = false
    @State private var importURLs: [URL] = []
    @State private var importResult: NoteImporter.ImportResult?

    var body: some View {
        SettingsPage(pane: .importData) {
            Section {
                LabeledContent {
                    Button("Import from Granola\u{2026}") {
                        // Bring the main window forward, then ask it to open the importer.
                        MenuBarActions.openMainWindow(post: .lidiaOpenGranolaImport)
                    }
                } label: {
                    Text("Granola")
                    Text("Bring over your meetings, notes and transcripts.")
                }
                .settingsAnchor(.importGranola)
            }

            Section {
                LabeledContent {
                    Button("Choose Files\u{2026}") { chooseFiles() }
                } label: {
                    Text("Notes from files")
                    if let result = importResult {
                        Text("Last import: \(result.imported) added, \(result.skipped) skipped.")
                    } else {
                        Text("Markdown or text files, one meeting each. Titles and dates come from YAML front matter.")
                    }
                }
                .settingsAnchor(.importNotes)
            }
        }
        .alert("Import \(importURLs.count) files?", isPresented: $showImportPreview) {
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                importResult = NoteImporter.importFiles(importURLs, into: modelContext)
            }
        } message: {
            Text("Each file becomes a past meeting in your library.")
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText]
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes.append(mdType)
        }
        if panel.runModal() == .OK {
            importURLs = Self.gatherFiles(from: panel.urls)
            showImportPreview = true
        }
    }

    static func gatherFiles(from urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        let ext = fileURL.pathExtension.lowercased()
                        if ext == "md" || ext == "mdx" || ext == "txt" {
                            files.append(fileURL)
                        }
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }
}
