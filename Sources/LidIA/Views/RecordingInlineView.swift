import SwiftData
import SwiftUI

/// The live-mode toolbar strip: timer, mic and system levels, Pause and Stop.
///
/// Stop goes through the app's single "Stop recording?" confirmation
/// (`AppActions.toggleRecording`, the same path as ⌘R and Meeting › Stop
/// Recording…). The local dialog is only a fallback for when no window
/// publishes `AppActions`.
struct RecordingInlineView: View {
    @Environment(RecordingSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(\.modelContext) private var modelContext
    @FocusedValue(\.appActions) private var appActions

    @State private var isConfirmingStop = false

    var body: some View {
        HStack(spacing: 14) {
            statusDot

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.formatTime(session.elapsedTime))
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(session.isPaused ? .secondary : .primary)
                    .accessibilityLabel("Elapsed time \(Self.formatTime(session.elapsedTime))")
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let levels = LiveAudioLevels.from(session: session)
                HStack(spacing: 12) {
                    RecordingLevelMeter(title: "Mic", systemImage: "mic.fill", level: levels.mic, isAvailable: true)
                    RecordingLevelMeter(
                        title: "System",
                        systemImage: "speaker.wave.2.fill",
                        level: levels.system ?? 0,
                        isAvailable: levels.system != nil,
                        unavailableReason: session.activeCaptureMode == .micOnly
                            ? "System audio is not being captured — others may not be transcribed."
                            : "Included in the Mic level"
                    )
                }
            }

            if session.activeCaptureMode == .micOnly {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Mic only — other participants won't be captured separately")
                    .accessibilityLabel("Warning: microphone only")
            }

            Spacer(minLength: 8)

            if let countdown = session.autoStopCountdown {
                autoStopNotice(countdown)
            }

            Button {
                if session.isPaused { session.resumeRecording() } else { session.pauseRecording() }
            } label: {
                Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.glass)
            .help(session.isPaused ? "Resume recording" : "Pause recording")

            Button {
                if let appActions, appActions.isRecording {
                    appActions.toggleRecording()
                } else {
                    isConfirmingStop = true
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.red)
            .help("Stop recording…")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Brand.red.opacity(session.isPaused ? 0.04 : 0.10)), in: .capsule)
        .stopRecordingConfirmation(isPresented: $isConfirmingStop) {
            session.stopRecording(modelContext: modelContext, settings: settings, eventKitManager: eventKitManager)
        }
    }

    private var statusDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isPaused ? Color.orange : Brand.red)
                .frame(width: 10, height: 10)
                .modifier(PulseEffect())
                .accessibilityHidden(true)
            Text(session.isPaused ? "Paused" : "Recording")
                .font(.callout.weight(.semibold))
                .foregroundStyle(session.isPaused ? .orange : Brand.red)
        }
    }

    private func autoStopNotice(_ countdown: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(session.autoStopReason ?? "Stopping") · \(countdown)s")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
            Button("Keep Recording") { session.cancelAutoStop() }
                .controlSize(.small)
        }
    }

    static func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, mins, secs) }
        return String(format: "%02d:%02d", mins, secs)
    }
}

/// Small horizontal level meter with a label.
struct RecordingLevelMeter: View {
    let title: String
    let systemImage: String
    let level: Float
    var isAvailable: Bool = true
    var unavailableReason: String = ""

    private let segments = 8

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if isAvailable {
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color(for: index))
                            .frame(width: 3, height: 12)
                    }
                }
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(isAvailable ? "\(title) level" : "\(title): \(unavailableReason)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) level")
        .accessibilityValue(isAvailable ? "\(Self.percent(level)) percent" : unavailableReason)
    }

    /// Whole percent for VoiceOver. A malformed buffer can make the level NaN or
    /// infinite, and `Int(_:)` traps on those, so they read as 0.
    static func percent(_ level: Float) -> Int {
        guard level.isFinite else { return 0 }
        return Int(min(max(level, 0), 1) * 100)
    }

    private func color(for index: Int) -> Color {
        let lit = Float(index + 1) / Float(segments) <= max(level, 0.001) + 0.0001
        guard lit else { return .secondary.opacity(0.2) }
        if index >= segments - 1 { return .red }
        if index >= segments - 3 { return .yellow }
        return .green
    }
}

extension View {
    /// Shared "Stop recording?" confirmation used by every Stop entry point on the meeting page.
    func stopRecordingConfirmation(isPresented: Binding<Bool>, onStop: @escaping () -> Void) -> some View {
        confirmationDialog("Stop recording?", isPresented: isPresented, titleVisibility: .visible) {
            // Same wording as the app shell's dialog in ContentView.
            Button("Stop and Process", action: onStop)
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("LidIA will stop capturing audio and start writing the summary.")
        }
    }
}
