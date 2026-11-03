import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LidIAWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// The brand palette for the Live Activity (the extension doesn't link LidIAKit;
/// these mirror `LidIABrand.Hex`). Always on a dark field, so her red's dark value.
private enum Palette {
    static let record = Color(red: 0xF2 / 255, green: 0x47 / 255, blue: 0x5C / 255)
    static let paused = Color(red: 1.0, green: 0.72, blue: 0.2)
    /// Deep crimson into ink, like the live recording screen.
    static let night = Color(red: 0x2A / 255, green: 0x0A / 255, blue: 0x10 / 255)
    static let crimson = Color(red: 0x8E / 255, green: 0x0E / 255, blue: 0x22 / 255)
    /// Rose and coral into ivory.
    static let mark = LinearGradient(
        colors: [Color(red: 0xF7 / 255, green: 0xC1 / 255, blue: 0xC1 / 255), Color(red: 1, green: 0x5A / 255, blue: 0x4E / 255), Color(red: 0xFD / 255, green: 0xF7 / 255, blue: 0xEB / 255)],
        startPoint: .leading, endPoint: .trailing
    )
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecordingView(title: context.attributes.title, state: context.state)
                .activityBackgroundTint(Palette.night.opacity(0.94))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusBadge(state: context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        TranscriptLine(text: context.state.lastLine, phase: context.state.phase)
                        if context.state.phase == .recording || context.state.phase == .paused {
                            ControlsRow(state: context.state)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                RecordingDot(state: context.state)
                    .padding(.leading, 2)
            } compactTrailing: {
                TimerText(state: context.state)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.phase == .recording ? Palette.record : .white)
                    .frame(maxWidth: 52)
            } minimal: {
                RecordingDot(state: context.state)
            }
            .keylineTint(Palette.record)
            .widgetURL(URL(string: "lidia://recording"))
        }
    }
}

// MARK: - Pieces

private struct RecordingDot: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .recording:
                Circle().fill(Palette.record).frame(width: 10, height: 10)
            case .paused:
                Image(systemName: "pause.fill").font(.caption2.weight(.semibold)).foregroundStyle(Palette.paused)
            case .saving:
                Image(systemName: "sparkles").font(.caption2.weight(.semibold)).foregroundStyle(.white)
            case .saved:
                Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.green)
            }
        }
        .accessibilityLabel(state.phase.label)
    }
}

private struct StatusBadge: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            RecordingDot(state: state)
            Text(state.phase.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isLive {
            Text(timerInterval: state.timerAnchor...Date.distantFuture, countsDown: false, showsHours: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(state.elapsedText)
        }
    }
}

private struct TranscriptLine: View {
    let text: String
    let phase: RecordingActivityAttributes.ContentState.Phase

    var body: some View {
        Text(display)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(text.isEmpty ? 0.55 : 0.9))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var display: String {
        switch phase {
        case .saving: return "Writing your notes on this iPhone…"
        case .saved: return "Notes are ready. Tap to open."
        default: return text.isEmpty ? "Listening…" : "“\(text)”"
        }
    }
}

private struct ControlsRow: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if state.phase == .paused {
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.white)
            } else {
                Button(intent: PauseRecordingIntent()) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.white)
            }
            Button(intent: StopRecordingIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(Palette.record)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .foregroundStyle(.black)
    }
}

private struct LockScreenRecordingView: View {
    let title: String
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(Palette.crimson)
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.mark)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    StatusBadge(state: state)
                }
                Spacer(minLength: 8)
                TimerText(state: state)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            TranscriptLine(text: state.lastLine, phase: state.phase)
            if state.phase == .recording || state.phase == .paused {
                ControlsRow(state: state)
            }
        }
        .padding(16)
    }
}

private extension RecordingActivityAttributes.ContentState.Phase {
    var label: String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .saving: "Writing notes"
        case .saved: "Saved"
        }
    }
}
