import SwiftUI

/// "Because …": the reasons behind a suggestion, always shown.
struct BecauseLine: View {
    let reasons: [String]

    var body: some View {
        if !reasons.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Because " + reasons.map(lowercaseFirst).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "You met…" reads as "because you met…"; names stay capitalised.
    private func lowercaseFirst(_ text: String) -> String {
        let starters: Set<String> = ["You", "The", "Same", "People", "Title", "Oldest", "Recurring", "Heard", "Spelled"]
        guard let word = text.split(separator: " ").first.map(String.init), starters.contains(word),
              let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// The small uppercase kind label at the top of a card.
private struct CardKind: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
    }
}

private struct DismissButton: View {
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Not now")
        .accessibilityLabel("Dismiss \(label)")
    }
}

// MARK: - Follow-up email

/// "Mateo K · Northwind x Harborcloud – Session recap & next steps".
struct FollowUpCard: View {
    let draft: FollowUpPlanner.Draft
    var onOpenMeeting: () -> Void

    @State private var isExpanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let primary = draft.primary {
                    AttendeeAvatar(attendee: primary, size: 30)
                } else {
                    SettingsIconTile(symbol: "envelope", tint: Brand.emberSolid, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    CardKind(text: "Suggested follow-up", tint: Brand.ember)
                    Text("\(Text(draft.primary?.name ?? "Follow-up").fontWeight(.semibold)) · \(draft.subject)")
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let email = draft.primary?.email {
                        Text(recipientLine(email))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                DismissButton(label: draft.subject) { withAnimation { IntelligenceStore.shared.dismissCard(draft.id) } }
            }

            Text(draft.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            BecauseLine(reasons: draft.reasons)

            HStack(spacing: 8) {
                Button {
                    MailComposer.open(to: draft.recipients.compactMap(\.email), subject: draft.subject, body: draft.body)
                    SiriCues.draftedFollowUp(meetingID: draft.meetingID)
                    withAnimation { IntelligenceStore.shared.markFollowUpHandled(draft.meetingID) }
                } label: {
                    Label("Open in Mail", systemImage: "envelope")
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.red)
                .help("Opens the draft in Mail. Nothing is sent until you send it there.")
                Button {
                    MailComposer.copy(subject: draft.subject, body: draft.body)
                    withAnimation { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.glass)
                Button("Open Meeting", action: onOpenMeeting)
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                Button(isExpanded ? "Shorter" : "Full Draft") {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .buttonStyle(.accentLink)
                .font(.callout)
            }
            .controlSize(.small)
        }
        .padding(16)
        .lidiaCard(tint: Brand.ember, radius: 14)
    }

    private func recipientLine(_ email: String) -> String {
        let others = draft.recipients.count - 1
        return "To \(email)" + (others > 0 ? " and \(others) more" : "")
    }
}

// MARK: - New project

/// "Create project “Northwind”?" for a group of meetings without one.
struct ClusterCard: View {
    let cluster: ProjectSuggester.Cluster
    var meetingTitles: [String]
    var companies: [String]
    var onCreate: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @State private var name = ""
    @State private var isNaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(symbol: "folder.badge.plus", tint: Brand.berrySolid, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    CardKind(text: "New project", tint: Brand.berry)
                    Text("Group \(cluster.meetingIDs.count) meetings into “\(displayName)”?")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meetingTitles.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                DismissButton(label: "project \(displayName)") {
                    withAnimation { IntelligenceStore.shared.dismissCluster(cluster.name) }
                }
            }

            BecauseLine(reasons: cluster.reasons)

            HStack(spacing: 8) {
                TextField("Project name", text: $name, prompt: Text(cluster.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { onCreate(displayName) }
                Button {
                    suggestName()
                } label: {
                    if isNaming {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Suggest a name", systemImage: "sparkles")
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.glass)
                .disabled(isNaming || IntelligenceLLM.unavailableReason(settings: settings) != nil)
                .help(IntelligenceLLM.unavailableReason(settings: settings)
                      ?? "Ask AI for a name (sends only the meeting titles and company names)")
                Button {
                    onCreate(displayName)
                } label: {
                    Label("Create Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.red)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(16)
        .lidiaCard(tint: Brand.berry, radius: 14)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? cluster.name : trimmed
    }

    private func suggestName() {
        isNaming = true
        Task { @MainActor in
            defer { isNaming = false }
            if let suggested = await IntelligenceLLM.suggestProjectName(
                titles: meetingTitles, companies: companies, settings: settings, modelManager: modelManager
            ) {
                name = suggested
            }
        }
    }
}

// MARK: - Patterns

struct PatternCard: View {
    let pattern: PatternDetector.Pattern
    var onPrimary: () -> Void
    var onAsk: (() -> Void)?

    private var isReview: Bool {
        if case .seriesReview = pattern.kind { return true }
        return false
    }

    private var tint: Color { isReview ? Brand.red : Brand.amber }
    private var tileTint: Color { isReview ? Brand.red : Brand.amberSolid }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(symbol: isReview ? "clock.arrow.circlepath" : "hourglass.bottomhalf.filled", tint: tileTint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    CardKind(text: isReview ? "Before your next meeting" : "Stale action items", tint: tint)
                    Text(pattern.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pattern.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                DismissButton(label: pattern.title) { withAnimation { IntelligenceStore.shared.dismissCard(pattern.id) } }
            }
            BecauseLine(reasons: pattern.reasons)
            HStack(spacing: 8) {
                Button(action: onPrimary) {
                    Label(isReview ? "Review Meetings" : "Open Board", systemImage: isReview ? "rectangle.stack" : "square.grid.3x1.below.line.grid.1x2")
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.red)
                if let onAsk {
                    Button(action: onAsk) {
                        Label(isReview ? "Ask for a Recap" : "Ask What's Blocking", systemImage: "sparkles")
                    }
                    .buttonStyle(.glass)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(16)
        .lidiaCard(tint: tint, radius: 14)
    }
}
