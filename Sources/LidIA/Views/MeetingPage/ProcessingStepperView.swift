import SwiftUI

/// After Stop: Transcribing → Speakers → Summarizing → Action items,
/// with Continue in background. Failures get Retry and Use another model.
struct ProcessingStepperView<ModelMenu: View>: View {
    let progress: MeetingPageProgress
    var onContinueInBackground: () -> Void
    var onRetry: () -> Void
    @ViewBuilder var anotherModelMenu: () -> ModelMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(ProcessingStage.allCases) { stage in
                    stageView(stage)
                    if stage != ProcessingStage.allCases.last {
                        connector(after: stage)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)

            switch progress.phase {
            case .failed:
                MeetingBannerView(
                    kind: .error,
                    title: "Processing stopped at \(progress.stage?.title.lowercased() ?? "a step")",
                    message: progress.message ?? "The transcript is saved. Try again, or use another model."
                ) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                    Menu("Use another model") { anotherModelMenu() }
                        .fixedSize()
                }
            case .queued:
                HStack(spacing: 8) {
                    Text(progress.message ?? "Waiting for the model. LidIA retries automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry Now", action: onRetry)
                    Menu("Use another model") { anotherModelMenu() }
                        .fixedSize()
                }
                .controlSize(.small)
            case .running:
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Overall progress")
                }
                HStack {
                    Text(progress.detail ?? "You can keep editing your notes while this runs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue in Background", action: onContinueInBackground)
                        .controlSize(.small)
                }
            case .idle, .complete:
                EmptyView()
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func stageView(_ stage: ProcessingStage) -> some View {
        let state = progress.state(of: stage)
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(fill(for: state))
                    .frame(width: 28, height: 28)
                switch state {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                case .failed:
                    Image(systemName: "exclamationmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                case .skipped:
                    Image(systemName: "minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                case .pending:
                    Image(systemName: Self.icon(for: stage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(stage.title)
                .font(.caption)
                .foregroundStyle(state == .pending || state == .skipped ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 72, maxWidth: 110)
    }

    private func connector(after stage: ProcessingStage) -> some View {
        let state = progress.state(of: stage)
        let done = state == .done || state == .skipped
        return Rectangle()
            .fill(done ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.top, 13)
    }

    private func fill(for state: ProcessingStageState) -> Color {
        switch state {
        case .done: .accentColor
        case .active: .accentColor.opacity(0.15)
        case .failed: .orange
        case .skipped, .pending: .secondary.opacity(0.12)
        }
    }

    private static func icon(for stage: ProcessingStage) -> String {
        switch stage {
        case .transcribing: "waveform"
        case .speakers: "person.2"
        case .summarizing: "text.badge.star"
        case .actionItems: "checklist"
        }
    }

    private var accessibilitySummary: String {
        let stage = progress.stage?.title ?? ""
        switch progress.phase {
        case .running: return "Processing: \(stage)"
        case .queued: return "Queued for processing"
        case .failed: return "Processing failed at \(stage)"
        case .idle, .complete: return "Processing complete"
        }
    }
}
