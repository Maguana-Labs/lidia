import SwiftData
import SwiftUI

struct NotesTemplatesPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(pane: .notes) {
            Section {
                ForEach(settings.meetingTemplates) { template in
                    NavigationLink(value: SettingsSubpage.template(template.id)) {
                        HStack(spacing: 10) {
                            Text(template.emoji.isEmpty ? "📝" : template.emoji)
                                .font(.title3)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name.isEmpty ? "Untitled" : template.name)
                                if !template.description.isEmpty {
                                    Text(template.description)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if template.isBuiltIn {
                                Text("Built-in")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("Meeting templates")
                    .settingsAnchor(.templates)
            } footer: {
                HStack {
                    Text("LidIA picks a template from the meeting's title and attendees, or asks AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Template") {
                        let new = MeetingTemplate(name: "", systemPrompt: "")
                        settings.meetingTemplates.append(new)
                        SettingsRouter.shared.path = [.template(new.id)]
                    }
                }
            }

            Section {
                Picker(selection: $settings.defaultTemplateID) {
                    Text(MeetingTemplate.general.name).tag("")
                    ForEach(settings.meetingTemplates.filter { $0.id != MeetingTemplate.general.id }) { template in
                        Text(template.name.isEmpty ? "Untitled" : template.name).tag(template.id.uuidString)
                    }
                } label: {
                    Text("Default template")
                    Text("Used when nothing else picks one for a meeting.")
                }
                .settingsAnchor(.defaultTemplate)
            }
        }
    }
}

// MARK: - Template detail

struct TemplateDetailPage: View {
    @Bindable var settings: AppSettings
    let templateID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(ModelManager.self) private var modelManager
    @State private var showPreviewSheet = false
    @State private var previewMeeting: Meeting?
    @State private var previewResult = ""
    @State private var isPreviewLoading = false

    private var index: Int? {
        settings.meetingTemplates.firstIndex { $0.id == templateID }
    }

    var body: some View {
        if let index {
            let template = settings.meetingTemplates[index]
            SettingsPage(
                pane: .notes,
                subpage: .template(templateID),
                title: template.name.isEmpty ? "New template" : template.name,
                subtitle: template.isBuiltIn ? "Built-in. Duplicate it to make your own version." : nil
            ) {
                TemplateEditorView(template: $settings.meetingTemplates[index])

                Section {
                    HStack {
                        Button("Test with a Past Meeting…") {
                            previewMeeting = nil
                            previewResult = ""
                            showPreviewSheet = true
                        }
                        Spacer()
                        if template.isBuiltIn {
                            Button("Duplicate") { duplicate(template) }
                        } else {
                            Button("Delete Template", role: .destructive) { delete(template) }
                        }
                    }
                }
            }
            .sheet(isPresented: $showPreviewSheet) {
                previewSheet(template: template)
            }
        } else {
            ContentUnavailableView("Template deleted", systemImage: "doc.questionmark")
        }
    }

    private func duplicate(_ template: MeetingTemplate) {
        var copy = template
        copy.id = UUID()
        copy.name = "\(template.name) (Copy)"
        copy.isBuiltIn = false
        settings.meetingTemplates.append(copy)
        SettingsRouter.shared.path = [.template(copy.id)]
    }

    private func delete(_ template: MeetingTemplate) {
        if settings.defaultTemplateID == template.id.uuidString {
            settings.defaultTemplateID = ""
        }
        SettingsRouter.shared.path = []
        settings.meetingTemplates.removeAll { $0.id == template.id }
    }

    // MARK: Preview

    @ViewBuilder
    private func previewSheet(template: MeetingTemplate) -> some View {
        let descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let meetings = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.status == .complete }

        VStack(alignment: .leading, spacing: 16) {
            Text("Test “\(template.name.isEmpty ? "Untitled" : template.name)”")
                .font(.title3.bold())

            if meetings.isEmpty {
                Text("No finished meetings to test with yet.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Meeting", selection: $previewMeeting) {
                    Text("Choose a meeting…").tag(nil as Meeting?)
                    ForEach(meetings) { meeting in
                        Text("\(meeting.title.isEmpty ? "Untitled" : meeting.title) \u{2014} \(meeting.date.formatted(date: .abbreviated, time: .shortened))")
                            .tag(meeting as Meeting?)
                    }
                }
            }

            if isPreviewLoading {
                ProgressView("Writing a preview…")
            }

            if !previewResult.isEmpty {
                ScrollView {
                    Text(previewResult)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 360)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Close") {
                    showPreviewSheet = false
                    previewResult = ""
                    previewMeeting = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Generate Preview") { generatePreview(template: template) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(previewMeeting == nil || isPreviewLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 280)
    }

    private func generatePreview(template: MeetingTemplate) {
        guard let meeting = previewMeeting else { return }
        isPreviewLoading = true
        previewResult = ""
        Task {
            defer { isPreviewLoading = false }
            let client = makeLLMClient(settings: settings, modelManager: modelManager, taskType: .chat)
            let model = effectiveModel(for: .summary, settings: settings, taskType: .chat)
            let transcript = meeting.userEditedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let effectiveText = transcript.isEmpty ? meeting.refinedTranscript : transcript
            guard !effectiveText.isEmpty else {
                previewResult = "This meeting has no transcript."
                return
            }
            do {
                let summary = try await client.summarizeMeeting(transcript: effectiveText, model: model, template: template)
                previewResult = summary.flatSummary
            } catch {
                previewResult = "Error: \(error.localizedDescription)"
            }
        }
    }
}
