import AppKit
import Combine
import LidIALiveActivity
import SwiftUI

// The menu bar's two Live-Activity-shaped views, drawn from plain state so the same
// layout can later become a real Live Activity's expanded view:
// - `RecordingActivityExpandedView`: the recording, in the menu bar panel;
// - `MeetingDetectedActivityView`: "Zoom call started", anchored under the icon.

extension EnvironmentValues {
    /// Draws the menu bar views with solid fills and bordered buttons instead of glass.
    /// For off-screen snapshots only: glass is composited by the window server, so a
    /// view rendered off screen loses it and its vibrant text colors.
    @Entry var menuBarFlatRendering = false
}

extension View {
    /// The menu bar's glass card (a solid card in snapshots).
    func menuBarCard(cornerRadius: CGFloat) -> some View {
        modifier(MenuBarCardModifier(cornerRadius: cornerRadius))
    }

    /// `.glass` / `.glassProminent` (bordered in snapshots).
    func menuBarButtonStyle(prominent: Bool) -> some View {
        modifier(MenuBarButtonStyleModifier(prominent: prominent))
    }
}

private struct MenuBarCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.menuBarFlatRendering) private var flat

    func body(content: Content) -> some View {
        if flat {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            )
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

private struct MenuBarButtonStyleModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.menuBarFlatRendering) private var flat

    func body(content: Content) -> some View {
        switch (flat, prominent) {
        case (true, true): content.buttonStyle(.borderedProminent)
        case (true, false): content.buttonStyle(.bordered)
        case (false, true): content.buttonStyle(.glassProminent)
        case (false, false): content.buttonStyle(.glass)
        }
    }
}

struct RecordingActivityActions {
    var togglePause: () -> Void = {}
    var stop: () -> Void = {}
    var openNotes: (() -> Void)?
}

/// Title, elapsed time, live level, the last transcript line, and Pause/Resume, Stop
/// and Open Notes.
struct RecordingActivityExpandedView: View {
    let state: RecordingActivityState
    /// Live input level, 0…1 RMS, read by the meter on its own clock.
    var level: () -> Float = { 0 }
    /// Meter bars to start from (snapshots).
    var initialLevels: [Float]?
    var actions = RecordingActivityActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                RecordingActivityBadge(isPaused: state.isPaused)
                Spacer()
                Text(timerInterval: state.timerInterval, pauseTime: state.pauseTime, countsDown: false, showsHours: true)
                    .font(.system(size: 22, weight: .light).monospacedDigit())
                    .foregroundStyle(state.isPaused ? .secondary : .primary)
                    .accessibilityLabel(state.isPaused ? "Paused at \(ElapsedFormat.string(state.elapsed(at: .now)))" : "Elapsed time")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let warning = state.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text("Microphone and system audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            MenuBarLevelMeter(isPaused: state.isPaused, level: level, initial: initialLevels)
                .frame(height: 22)

            lastLine

            HStack(spacing: 8) {
                Button(action: actions.togglePause) {
                    Label(state.isPaused ? "Resume" : "Pause",
                          systemImage: state.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .menuBarButtonStyle(prominent: false)

                Button(action: actions.stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .menuBarButtonStyle(prominent: true)
                .tint(Brand.red)
                .help("Stop and write the notes")
            }
            .controlSize(.large)

            if let openNotes = actions.openNotes {
                Button(action: openNotes) {
                    Label("Open Notes", systemImage: "note.text")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open this meeting's live notes")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// The newest utterance, or why there isn't one.
    @ViewBuilder
    private var lastLine: some View {
        if let notice = state.transcriptNotice {
            Label(notice, systemImage: "captions.bubble")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.lastLine.map { $0.isLocal ? "You" : "Others" } ?? "Transcript")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(state.lastLine?.text ?? (state.isPaused ? "Paused" : "Listening…"))
                    .font(.callout)
                    .foregroundStyle(state.lastLine == nil ? .tertiary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: state.lastLine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .accessibilityElement(children: .combine)
        }
    }
}

struct RecordingActivityBadge: View {
    let isPaused: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isPaused ? Color.orange : Brand.red)
                .frame(width: 8, height: 8)
                .opacity(isPaused ? 1 : (pulse ? 0.35 : 1))
                .animation(isPaused ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text(isPaused ? "Paused" : "Recording")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPaused ? Color.orange : Brand.red)
        }
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
    }
}

/// Live input level from the capture RMS, newest bar on the right.
struct MenuBarLevelMeter: View {
    let isPaused: Bool
    let level: () -> Float

    static let barCount = 36
    @State private var samples: [Float]
    private let tick = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    init(isPaused: Bool, level: @escaping () -> Float, initial: [Float]? = nil) {
        self.isPaused = isPaused
        self.level = level
        let start = (initial ?? []).suffix(Self.barCount)
        _samples = State(initialValue: Array(repeating: 0, count: Self.barCount - start.count) + start)
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let width = (geo.size.width - spacing * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(samples.indices, id: \.self) { i in
                    Capsule()
                        .fill(isPaused ? Color.secondary.opacity(0.4) : Brand.red.opacity(0.85))
                        .frame(width: max(1.5, width), height: max(2, geo.size.height * CGFloat(samples[i])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(tick) { _ in
            // RMS is small for speech; a square root curve makes normal talking visible.
            let value = isPaused ? 0 : min(1, sqrt(max(0, level())) * 2.2)
            samples.removeFirst()
            samples.append(value)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Meeting detected

struct MeetingDetectedActions {
    var record: () -> Void = {}
    var notNow: () -> Void = {}
    var never: () -> Void = {}
}

/// "Zoom call started" with Record, Not Now and Never for <App>, like a Live Activity's
/// alert under the menu bar icon. A thin bar runs down to when it goes away by itself.
struct MeetingDetectedActivityView: View {
    let state: MeetingDetectedActivityState
    var appIcon: NSImage?
    var actions = MeetingDetectedActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(state.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button(action: actions.record) {
                    Label("Record", systemImage: "record.circle")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .menuBarButtonStyle(prominent: true)
                .tint(Brand.red)
                .help("Record this meeting and take notes")

                Button(action: actions.notNow) {
                    Text("Not Now")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                }
                .menuBarButtonStyle(prominent: false)
                .help("Don't record this call")
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                ProgressView(timerInterval: state.detectedAt...state.endsAt, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(.secondary)
                .controlSize(.mini)
                .accessibilityHidden(true)

                Button(state.neverTitle, action: actions.never)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Stop offering to record calls in \(state.appName)")
            }
        }
        .padding(14)
        .frame(width: 320)
        .menuBarCard(cornerRadius: 16)
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.headline)
    }

    @ViewBuilder
    private var icon: some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        }
    }
}
