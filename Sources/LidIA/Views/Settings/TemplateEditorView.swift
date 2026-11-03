import SwiftUI

// MARK: - Template Editor

/// Edits one meeting template as grouped-form sections: name, AI draft,
/// sections or raw prompt, and when to use it.
struct TemplateEditorView: View {
    @Binding var template: MeetingTemplate

    @State private var attendeeMin: String = ""
    @State private var attendeeMax: String = ""
    @State private var keywords: String = ""
    @State private var aiDescription: String = ""
    @State private var isGeneratingFromAI = false

    var body: some View {
        Section {
            LabeledContent("Name") {
                HStack(spacing: 8) {
                    TextField("Emoji", text: $template.emoji, prompt: Text("📝"))
                        .labelsHidden()
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                    TextField("Template name", text: $template.name, prompt: Text("Template name"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
            }
            LabeledContent {
                TextField("Description", text: $template.description, prompt: Text("Shown in the template picker"))
                    .labelsHidden()
                    .frame(maxWidth: 280)
            } label: {
                Text("Description")
            }
        }
        .onAppear(perform: loadRules)

        if !template.isBuiltIn {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Describe it", text: $aiDescription, prompt: Text("e.g. pain points, feature requests"))
                            .labelsHidden()
                            .frame(maxWidth: 240)
                        Button {
                            generateFromDescription()
                        } label: {
                            if isGeneratingFromAI {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                        }
                        .disabled(aiDescription.isEmpty || isGeneratingFromAI)
                        .accessibilityLabel("Make sections")
                    }
                } label: {
                    Text("Start from a description")
                    Text("Comma-separated topics become sections.")
                }

                Toggle(isOn: $template.isAdvancedMode) {
                    Text("Write the prompt yourself")
                    Text("Replace sections with your own instructions.")
                }
            }
        }

        if template.isAdvancedMode {
            Section("Prompt") {
                TextEditor(text: $template.systemPrompt)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180, maxHeight: 320)
            }
        } else {
            Section {
                ForEach($template.sections) { $section in
                    HStack(spacing: 8) {
                        TextField("Section name", text: $section.name, prompt: Text("Name"))
                            .labelsHidden()
                            .frame(maxWidth: 140)
                        TextField("What goes in it", text: $section.description, prompt: Text("What goes in it"))
                            .labelsHidden()
                        Picker("Format", selection: $section.format) {
                            Text("Bullets").tag(OutputFormat.bullets)
                            Text("Prose").tag(OutputFormat.prose)
                            Text("Table").tag(OutputFormat.table)
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        let sectionID = section.id
                        Button {
                            template.sections.removeAll { $0.id == sectionID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove section")
                    }
                }
                if !template.sections.isEmpty {
                    DisclosureGroup("Preview prompt") {
                        Text(template.effectiveSystemPrompt)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("Sections")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Section") {
                        template.sections.append(SectionSpec(name: ""))
                    }
                }
            }
        }

        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("Min", text: $attendeeMin, prompt: Text("Min"))
                        .labelsHidden()
                        .frame(width: 52)
                        .onChange(of: attendeeMin) { _, _ in syncAttendeeRules() }
                    Text("to").foregroundStyle(.secondary)
                    TextField("Max", text: $attendeeMax, prompt: Text("Max"))
                        .labelsHidden()
                        .frame(width: 52)
                        .onChange(of: attendeeMax) { _, _ in syncAttendeeRules() }
                }
            } label: {
                Text("Attendees")
                Text("Use this template for meetings this size.")
            }
            LabeledContent {
                TextField("Title keywords", text: $keywords, prompt: Text("brainstorm, ideation"))
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .onChange(of: keywords) { _, _ in syncKeywords() }
            } label: {
                Text("Title keywords")
                Text("Or when the meeting title has one of these words.")
            }
        } header: {
            Text("Use it automatically")
        }
    }

    private func loadRules() {
        if let range = template.autoDetectRules.attendeeCount {
            attendeeMin = "\(range.lowerBound)"
            attendeeMax = "\(range.upperBound)"
        }
        keywords = template.autoDetectRules.titleKeywords.joined(separator: ", ")
    }

    private func syncAttendeeRules() {
        if let min = Int(attendeeMin), let max = Int(attendeeMax), min <= max {
            template.autoDetectRules.attendeeCount = min...max
        } else {
            template.autoDetectRules.attendeeCount = nil
        }
    }

    private func syncKeywords() {
        template.autoDetectRules.titleKeywords = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func generateFromDescription() {
        isGeneratingFromAI = true
        Task {
            defer { isGeneratingFromAI = false }
            let parts = aiDescription
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            template.sections = parts.map { part in
                SectionSpec(name: part.capitalized, description: "", format: .bullets)
            }
            template.isAdvancedMode = false
            if template.name.isEmpty {
                template.name = String(aiDescription.prefix(30))
            }
        }
    }
}
