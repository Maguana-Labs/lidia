import AppKit
import SwiftUI

/// "View what was sent": a discreet disclosure under an AI answer that shows
/// the run's transcript (system prompt, tools, every message, tool calls and
/// results, the model, and whether it ran on this Mac or in the cloud).
struct AgentTranscriptDisclosure: View {
    let transcript: AgentTranscript

    @State private var expanded: Bool

    init(transcript: AgentTranscript, expanded: Bool = false) {
        self.transcript = transcript
        #if DEBUG
        _expanded = State(initialValue: expanded || AgentTranscriptDisclosure.snapshotExpanded)
        #else
        _expanded = State(initialValue: expanded)
        #endif
    }

    #if DEBUG
    /// Snapshot runs open every disclosure.
    @MainActor static var snapshotExpanded = false
    #endif

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            AgentTranscriptView(transcript: transcript)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: transcript.locality.systemImage)
                    .accessibilityHidden(true)
                Text("View what was sent")
                Text("· \(transcript.model) · \(transcript.whereItRan)")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
        }
        .accessibilityLabel("View what was sent to \(transcript.model), \(transcript.whereItRan)")
    }
}

/// The transcript itself.
struct AgentTranscriptView: View {
    let transcript: AgentTranscript
    /// Inline under an answer it stays short; in a sheet it fills the space.
    var maxHeight: CGFloat = 340

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                section("System prompt", subtitle: "\(TokenEstimate.estimate(transcript.systemPrompt)) tokens (est.)") {
                    mono(transcript.systemPrompt)
                }
                if !transcript.tools.isEmpty {
                    section("Tools offered", subtitle: "\(transcript.tools.count) · \(transcript.backend.displayName)") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(transcript.tools, id: \.name) { tool in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(tool.name).font(.caption.monospaced().weight(.semibold))
                                        if tool.effect != .readOnly {
                                            Text(tool.effect == .mutating ? "asks you first" : "drafts only")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .background(.quaternary, in: .capsule)
                                        }
                                    }
                                    Text(tool.schemaJSON).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                section("Conversation", subtitle: "\(transcript.messages.count) messages") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(transcript.messages.enumerated()), id: \.offset) { _, message in
                            messageRow(message)
                        }
                    }
                }
                section("Steps", subtitle: stepsSubtitle) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(transcript.entries.enumerated()), id: \.offset) { _, entry in
                            entryRow(entry)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Copy as JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.jsonText, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var headline: String {
        switch transcript.locality {
        case .onDevice: "Ran on this Mac: nothing left it"
        case .localNetwork: "Ran on your network server: nothing went to the cloud"
        case .cloud: "Sent to \(transcript.providerName) in the cloud, with your key"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(headline)
                    .font(.caption.weight(.semibold))
            } icon: {
                Image(systemName: transcript.locality.systemImage)
            }
            .foregroundStyle(transcript.locality == .cloud ? Color.orange : Color.green)
            Text("\(transcript.model) · \(transcript.providerName) · profile \(transcript.profileID) v\(transcript.profileVersion) · effort \(transcript.effort.rawValue) · \(String(format: "%.1f", transcript.seconds)) s · \(outcomeText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var outcomeText: String {
        switch transcript.outcome {
        case .answered: "answered"
        case .stepLimit: "stopped at \(transcript.maxSteps) steps"
        case .deadline: "stopped at \(Int(transcript.deadlineSeconds)) s"
        case .cancelled: "cancelled"
        case .failed: "failed" + (transcript.errorMessage.map { ": \($0)" } ?? "")
        }
    }

    private var stepsSubtitle: String {
        "\(transcript.modelCalls.count) model call\(transcript.modelCalls.count == 1 ? "" : "s"), \(transcript.toolRuns.count) tool call\(transcript.toolRuns.count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func messageRow(_ message: AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(roleLabel(message))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if !message.text.isEmpty { mono(message.text) }
            ForEach(message.toolCalls) { call in
                mono("→ \(call.name) \(call.argumentsJSON)")
            }
        }
    }

    private func roleLabel(_ message: AgentMessage) -> String {
        switch message.role {
        case .user: "User"
        case .assistant: message.toolCalls.isEmpty ? "Assistant" : "Assistant (tool call)"
        case .tool: "Tool result: \(message.toolName ?? "")" + (message.isError ? " (error)" : "")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AgentTranscript.Entry) -> some View {
        switch entry {
        case .modelCall(let call):
            Text("Step \(call.step): model call with \(call.sentMessageCount) message\(call.sentMessageCount == 1 ? "" : "s")\(call.toolsOffered ? " + tools" : ", no tools") · \(String(format: "%.1f", call.seconds)) s · \(call.toolCalls.isEmpty ? "answered" : call.toolCalls.map(\.name).joined(separator: ", "))")
                .font(.caption2)
        case .toolRun(let run):
            Text("Step \(run.step): \(run.call.name) → \(statusText(run.status)) · \(String(format: "%.2f", run.seconds)) s")
                .font(.caption2)
                .foregroundStyle(run.status == .executed ? Color.secondary : Color.orange)
        case .repair(let step, let problem, let rejected):
            Text("Step \(step): asked the model to fix its reply (\(problem)): \(rejected.agentTruncated(200))")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .note(let note):
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statusText(_ status: AgentTranscript.ToolRun.Status) -> String {
        switch status {
        case .executed: "ran"
        case .awaitingConfirmation: "waiting for your confirmation"
        case .invalidArguments: "invalid arguments"
        case .unknownTool: "unknown tool"
        case .failed: "failed"
        case .skipped: "skipped (over budget)"
        }
    }

    private func section<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text.agentTruncated(4_000))
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Changes the agent prepared, each waiting for Confirm.
struct AgentPendingActionsView: View {
    let actions: [AgentPendingAction]
    var onConfirm: (AgentPendingAction) -> Void
    var onDismiss: (AgentPendingAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(actions) { action in
                HStack(spacing: 8) {
                    Image(systemName: icon(action.state))
                        .foregroundStyle(color(action.state))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.summary).font(.callout)
                        if let message = action.resultMessage, action.state != .pending {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if action.state == .pending {
                        Button("Dismiss") { onDismiss(action) }
                            .controlSize(.small)
                        Button("Confirm") { onConfirm(action) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func icon(_ state: AgentPendingAction.State) -> String {
        switch state {
        case .pending: "hand.raised"
        case .confirmed: "checkmark.circle.fill"
        case .dismissed: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func color(_ state: AgentPendingAction.State) -> Color {
        switch state {
        case .pending: .orange
        case .confirmed: .green
        case .dismissed: .secondary
        case .failed: .red
        }
    }
}
