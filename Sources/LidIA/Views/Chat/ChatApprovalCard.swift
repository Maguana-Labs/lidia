import SwiftUI

/// Human in the loop: everything a run left waiting (a change to confirm, a
/// drafted dispatch, a clarifying question), one page at a time ("1 / 3").
/// Nothing runs until the user clicks.
struct ChatApprovalCard: View {
    let run: AgentRun
    /// Meetings the agent read, for the recommendation's evidence.
    var meetingsRead: Int = 0

    @State private var page = 0
    @State private var selection: [UUID: String] = [:]
    @State private var freeText: [UUID: String] = [:]
    @State private var writing: UUID?
    @State private var working: UUID?
    @FocusState private var freeTextFocused: Bool
    @Environment(\.chatDensity) private var density

    private var approvals: [AgentApproval] { run.approvals }

    var body: some View {
        if !approvals.isEmpty {
            let index = min(page, approvals.count - 1)
            let approval = approvals[index]
            VStack(alignment: .leading, spacing: 14) {
                header(approval, index: index)
                Text(approval.question)
                    .font(.system(size: density.bodySize + 1, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                content(approval)
                if case .pending = approval.state { footer(approval) }
            }
            .padding(density == .regular ? 18 : 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.75)
            )
            .animation(.snappy(duration: 0.22), value: page)
            .animation(.snappy(duration: 0.22), value: approval.state)
            .onAppear { page = approvals.firstIndex { $0.state == .pending } ?? 0 }
        }
    }

    // MARK: Header

    private func header(_ approval: AgentApproval, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(approval))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(kicker(approval))
                .font(.system(size: density.smallSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if approvals.count > 1 {
                HStack(spacing: 2) {
                    pagerButton("chevron.left", enabled: index > 0) { page = index - 1 }
                    Text("\(index + 1) / \(approvals.count)")
                        .font(.system(size: density.smallSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34)
                    pagerButton("chevron.right", enabled: index < approvals.count - 1) { page = index + 1 }
                }
            }
        }
    }

    private func pagerButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .accessibilityLabel(symbol.contains("left") ? "Previous" : "Next")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ approval: AgentApproval) -> some View {
        switch approval.state {
        case .resolved(let message):
            resolvedRow(message, color: .green, icon: "checkmark.circle.fill")
        case .failed(let message):
            resolvedRow(message, color: .orange, icon: "exclamationmark.triangle.fill")
        case .pending:
            switch approval.kind {
            case .clarification:
                optionsList(approval)
            case .change(let action):
                ChatChangePreview(action: action)
            case .dispatch(let proposal):
                ChatRecommendationBody(proposal: proposal, evidence: ChatEvidence.of(
                    linkedToItem: proposal.actionItemID != nil,
                    meetingsRead: meetingsRead,
                    hasBody: !proposal.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ))
            }
            if approval.allowsFreeText { somethingElse(approval) }
        }
    }

    private func resolvedRow(_ message: String, color: Color, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.system(size: density.bodySize - 0.5, weight: .medium))
            .foregroundStyle(color)
    }

    private func optionsList(_ approval: AgentApproval) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(approval.options.filter { !$0.isCancel }.enumerated()), id: \.element.id) { index, option in
                let chosen = selectedOption(approval) == option.id && writing != approval.id
                Button {
                    selection[approval.id] = option.id
                    writing = nil
                } label: {
                    ChatOptionRow(number: index + 1, label: option.label, chosen: chosen)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func somethingElse(_ approval: AgentApproval) -> some View {
        if writing == approval.id {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                TextField("Tell LidIA what to do instead…", text: Binding(
                    get: { freeText[approval.id] ?? "" },
                    set: { freeText[approval.id] = $0 }
                ))
                .textFieldStyle(.plain)
                .focused($freeTextFocused)
                .onSubmit { submit(approval) }
            }
            .font(.system(size: density.bodySize - 0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
        } else {
            Button {
                writing = approval.id
                freeTextFocused = true
            } label: {
                Label("Something else…", systemImage: "pencil")
                    .font(.system(size: density.smallSize + 0.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Footer

    private func footer(_ approval: AgentApproval) -> some View {
        HStack(spacing: 8) {
            if working == approval.id {
                ProgressView().controlSize(.small)
                Text("Working…").font(.system(size: density.smallSize)).foregroundStyle(.secondary)
            }
            Spacer()
            let labels = footerLabels(approval)
            Button(labels.secondary) { secondary(approval) }
                .buttonStyle(.bordered)
                .controlSize(density == .regular ? .regular : .small)
            Button(labels.primary) { submit(approval) }
                .buttonStyle(.borderedProminent)
                .controlSize(density == .regular ? .regular : .small)
                .disabled(!canSubmit(approval) || working != nil)
        }
    }

    private func footerLabels(_ approval: AgentApproval) -> (primary: String, secondary: String) {
        if writing == approval.id { return ("Send", "Back") }
        switch approval.kind {
        case .clarification: return ("Continue", "Skip")
        case .change: return (approval.options.first { $0.isPrimary }?.label ?? "Confirm", "Cancel")
        case .dispatch: return ("Accept", "Dismiss")
        }
    }

    private func selectedOption(_ approval: AgentApproval) -> String? {
        selection[approval.id] ?? approval.options.first { $0.isPrimary && !$0.isCancel }?.id
    }

    private func canSubmit(_ approval: AgentApproval) -> Bool {
        if writing == approval.id { return !(freeText[approval.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        return selectedOption(approval) != nil
    }

    private func submit(_ approval: AgentApproval) {
        let choice: AgentApproval.Choice
        if writing == approval.id {
            let text = (freeText[approval.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            choice = .freeText(text)
        } else if let option = selectedOption(approval) {
            choice = .option(option)
        } else {
            return
        }
        respond(approval, choice)
    }

    private func secondary(_ approval: AgentApproval) {
        if writing == approval.id { writing = nil; return }
        switch approval.kind {
        case .clarification:
            advance(from: approval)
        case .change, .dispatch:
            if let cancel = approval.options.first(where: \.isCancel) { respond(approval, .option(cancel.id)) }
        }
    }

    private func respond(_ approval: AgentApproval, _ choice: AgentApproval.Choice) {
        working = approval.id
        Task {
            await run.respond(to: approval.id, with: choice)
            working = nil
            writing = nil
            advance(from: approval)
        }
    }

    private func advance(from approval: AgentApproval) {
        guard let index = approvals.firstIndex(where: { $0.id == approval.id }) else { return }
        let next = approvals.indices.first { $0 > index && approvals[$0].state == .pending }
            ?? approvals.indices.first { approvals[$0].state == .pending }
        if let next { page = next } else if index < approvals.count - 1 { page = index + 1 }
    }

    // MARK: Labels

    private func icon(_ approval: AgentApproval) -> String {
        switch approval.kind {
        case .clarification: "questionmark.bubble"
        case .change: "hand.raised"
        case .dispatch(let proposal): ChatRecommendationBody.icon(proposal.destination)
        }
    }

    private func kicker(_ approval: AgentApproval) -> String {
        switch approval.kind {
        case .clarification: "LidIA has a question"
        case .change: "Confirm a change"
        case .dispatch: "Suggested action"
        }
    }
}

/// One numbered option of a question.
struct ChatOptionRow: View {
    let number: Int
    let label: String
    let chosen: Bool

    @Environment(\.chatDensity) private var density

    private var badgeFill: Color { chosen ? Color.accentColor : Color.primary.opacity(0.07) }
    private var rowFill: Color { chosen ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03) }
    private var rowStroke: Color { chosen ? Color.accentColor.opacity(0.45) : ChatStyle.cardStroke }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(chosen ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(badgeFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .font(.system(size: density.bodySize - 0.5))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer()
            if chosen {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowFill, in: shape)
        .overlay(shape.strokeBorder(rowStroke, lineWidth: chosen ? 1 : 0.5))
        .contentShape(.rect)
    }
}

/// What a prepared change does, from its arguments.
struct ChatChangePreview: View {
    let action: AgentPendingAction

    @Environment(\.chatDensity) private var density

    private var fields: [(String, String)] {
        guard let data = action.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let order = ["title", "assignee", "due", "deadline", "status", "priority", "meeting_id", "id"]
        return object.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }.compactMap { key in
            guard let value = object[key] else { return nil }
            let text = "\(value)"
            guard !text.isEmpty, key != "id", key != "meeting_id", key != "action_item_id" else { return nil }
            return (key.replacingOccurrences(of: "_", with: " ").capitalized, text)
        }
    }

    var body: some View {
        if !fields.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(fields, id: \.0) { field in
                    GridRow {
                        Text(field.0).foregroundStyle(.secondary)
                        Text(field.1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: density.bodySize - 1))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatCard(radius: 10)
        }
    }
}

/// The recommendation: what the agent proposes, where it goes, and how well
/// grounded it is (from facts, not the model's own confidence).
struct ChatRecommendationBody: View {
    let proposal: AgentDispatchProposal
    let evidence: ChatEvidence

    @Environment(\.chatDensity) private var density

    static func icon(_ destination: String) -> String {
        switch destination {
        case "clickup": "checkmark.square"
        case "notion": "doc.richtext"
        case "reminder": "checklist"
        case "n8n": "point.3.connected.trianglepath.dotted"
        case "email": "envelope"
        default: "paperplane"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.icon(proposal.destination))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.title)
                        .font(.system(size: density.bodySize, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(CommentToAction.displayName(proposal.destination))
                        .font(.system(size: density.smallSize))
                        .foregroundStyle(.secondary)
                }
            }
            let body = proposal.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: density.bodySize - 1))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                ChatEvidenceMeter(level: evidence.level)
                Text(evidence.label)
                    .font(.system(size: density.smallSize, weight: .semibold))
                    .foregroundStyle(evidence.level >= 3 ? Color.green : evidence.level == 2 ? Color.secondary : Color.orange)
                Text(evidence.detail)
                    .font(.system(size: density.smallSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .help("How grounded this is: linked to an action item, meetings read, a drafted note")
        }
        .padding(12)
        .chatCard(radius: 10)
    }
}

/// Three bars.
struct ChatEvidenceMeter: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? color : Color.primary.opacity(0.12))
                    .frame(width: 3.5, height: CGFloat(4 + bar * 3))
            }
        }
        .accessibilityLabel("Evidence \(level) of 3")
    }

    private var color: Color { level >= 3 ? .green : level == 2 ? .accentColor : .orange }
}
