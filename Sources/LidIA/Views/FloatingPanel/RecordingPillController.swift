import AppKit
import SwiftUI

/// The floating recording pill. At rest it's a small dark capsule with the
/// LidIA mark and a live level meter. On hover it opens a panel beside it with
/// the latest transcript lines, the elapsed time, Pause, Stop and Open Notes,
/// and any warning as one plain sentence. Drag it anywhere; it snaps to the
/// nearest side of the screen.
@MainActor
final class RecordingPillController {
    private var panel: FloatingPanel?
    private var hosting: NSHostingView<AnyView>?
    private let model = RecordingPillModel()
    private var moveObserver: NSObjectProtocol?
    private var snapTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    /// Top-left of the resting pill, in screen coordinates (AppKit, y up = top edge).
    private var pillTopLeft: NSPoint = .zero
    private var isResizing = false

    private static let positionXKey = "recordingPill.position.x"
    private static let positionYKey = "recordingPill.position.y"
    private static let edgeMargin: CGFloat = 12

    func show(session: RecordingSession, onStop: @escaping () -> Void) {
        if panel != nil {
            updateVisibility()
            return
        }

        let root = RecordingPillView(
            session: session,
            model: model,
            onStop: onStop,
            onOpenNotes: {
                guard let meeting = session.currentMeeting else { return }
                MenuBarActions.openMainWindow()
                NotificationCenter.default.post(
                    name: .lidiaOpenMeeting,
                    object: nil,
                    userInfo: [NotificationDispatcher.eventIDUserInfoKey: meeting.id.uuidString]
                )
            },
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) },
            onLayoutChange: { [weak self] in self?.applyFrame(animated: true) }
        )

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: RecordingPillMetrics.pillSize),
            styleMask: [.nonactivatingPanel, .utilityWindow, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A dark HUD in both modes, so controls draw light on dark.
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel

        // Restore the saved spot (snapped to its side), or start top-right.
        let defaults = UserDefaults.standard
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var topLeft = NSPoint(
            x: screen.maxX - RecordingPillMetrics.pillSize.width - Self.edgeMargin,
            y: screen.maxY - 120
        )
        if defaults.object(forKey: Self.positionXKey) != nil {
            let x = defaults.double(forKey: Self.positionXKey)
            let y = defaults.double(forKey: Self.positionYKey)
            topLeft = NSPoint(x: x, y: y + RecordingPillMetrics.pillSize.height)
        }
        pillTopLeft = snapped(topLeft)
        applyFrame(animated: false)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
        // The pill is for when LidIA isn't in front. While LidIA's own window is (the live
        // page has the timer and Stop), it would only sit on top of the window's content,
        // fullscreen or not.
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
        ] {
            visibilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the window finishes closing or miniaturising. A statement,
                // not a returned value: Swift 6.3 can't infer the Task's type here.
                _ = Task { @MainActor in self?.updateVisibility() }
            })
        }
        updateVisibility()
    }

    private var visibilityObservers: [NSObjectProtocol] = []

    /// Shows the pill unless LidIA is the active app with a main window on screen.
    private func updateVisibility() {
        guard let panel else { return }
        let hasMainWindow = NSApp.windows.contains { window in
            window !== panel && !(window is NSPanel) && window.isVisible && !window.isMiniaturized
                && window.canBecomeMain && window.frame.width > 400
        }
        if RecordingPillVisibility.shouldShow(appIsActive: NSApp.isActive, hasVisibleMainWindow: hasMainWindow) {
            if !panel.isVisible { panel.orderFront(nil) }
        } else {
            if panel.isVisible { panel.orderOut(nil) }
            if model.isExpanded { setExpanded(false) }
        }
    }

    func close() {
        if let panel {
            // Saves the resting pill's origin, as before.
            UserDefaults.standard.set(pillTopLeft.x, forKey: Self.positionXKey)
            UserDefaults.standard.set(pillTopLeft.y - RecordingPillMetrics.pillSize.height, forKey: Self.positionYKey)
            panel.close()
        }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers = []
        snapTask?.cancel()
        collapseTask?.cancel()
        panel = nil
        hosting = nil
        model.isExpanded = false
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Hover

    private func hoverChanged(_ hovering: Bool) {
        collapseTask?.cancel()
        if hovering {
            // Not while dragging.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            setExpanded(true)
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.isExpanded != expanded || model.forcedExpanded else { return }
        model.isExpanded = expanded
        applyFrame(animated: true)
    }

    /// Sizes the panel to its content, keeping the pill where it is and
    /// opening the panel toward the middle of the screen.
    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        model.opensLeft = pillTopLeft.x + RecordingPillMetrics.pillSize.width / 2 > screen.midX
        // Measure after SwiftUI has drawn the new state.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.resizePanel(screen: screen)
        }
        _ = animated
    }

    private func resizePanel(screen: NSRect) {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = model.showsPanel ? hosting.fittingSize : RecordingPillMetrics.pillSize
        // The open panel has a margin around its content; keep the pill still.
        let pad: CGFloat = model.showsPanel ? RecordingPillMetrics.panelMargin : 0
        var origin = NSPoint(x: pillTopLeft.x - pad, y: pillTopLeft.y + pad - size.height)
        if model.opensLeft {
            origin.x = pillTopLeft.x + RecordingPillMetrics.pillSize.width + pad - size.width
        }
        // Keep the open panel on screen.
        origin.y = max(screen.minY + 4, origin.y)
        origin.x = min(max(screen.minX + 4, origin.x), screen.maxX - size.width + pad)
        isResizing = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        panel.invalidateShadow()
        isResizing = false
    }

    // MARK: - Drag and snap

    private func panelMoved() {
        guard !isResizing, let panel else { return }
        // Track the pill's corner while dragging (the panel is collapsed then).
        if !model.showsPanel {
            pillTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            // Snap once the mouse is up.
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { return }
            }
            guard let self, let panel = self.panel, !self.model.showsPanel else { return }
            self.pillTopLeft = self.snapped(NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
            let target = NSRect(
                origin: NSPoint(x: self.pillTopLeft.x, y: self.pillTopLeft.y - RecordingPillMetrics.pillSize.height),
                size: RecordingPillMetrics.pillSize
            )
            self.isResizing = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { self.isResizing = false }
            }
        }
    }

    /// The nearest left or right edge of the screen the pill is on.
    private func snapped(_ topLeft: NSPoint) -> NSPoint {
        let size = RecordingPillMetrics.pillSize
        let center = NSPoint(x: topLeft.x + size.width / 2, y: topLeft.y - size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return topLeft }
        let x = center.x < frame.midX ? frame.minX + Self.edgeMargin : frame.maxX - size.width - Self.edgeMargin
        let y = min(max(topLeft.y, frame.minY + size.height + Self.edgeMargin), frame.maxY - Self.edgeMargin)
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Visibility

enum RecordingPillVisibility {
    /// The pill floats over other apps. While LidIA itself is in front with its window,
    /// the live page already shows the recording, and the pill would cover the window.
    static func shouldShow(appIsActive: Bool, hasVisibleMainWindow: Bool) -> Bool {
        !(appIsActive && hasVisibleMainWindow)
    }
}

// MARK: - Model

@MainActor
@Observable
final class RecordingPillModel {
    var isExpanded = false
    /// Expanded regardless of hover (auto-stop countdown, Stop confirmation).
    var forcedExpanded = false
    /// The panel opens to the left of the pill (pill on the right of the screen).
    var opensLeft = true

    var showsPanel: Bool { isExpanded || forcedExpanded }
}

enum RecordingPillMetrics {
    static let pillSize = CGSize(width: 64, height: 32)
    static let panelWidth: CGFloat = 320
    /// Space around the open panel (the window draws the shadow).
    static let panelMargin: CGFloat = 0
}

// MARK: - Display state

/// Everything the pill shows, so it can be rendered from a session or from
/// fixed values (snapshots).
struct RecordingPillState: Equatable {
    struct Line: Equatable, Identifiable {
        let id: Int
        let text: String
        let isLocal: Bool
    }

    var isPaused = false
    var elapsed: TimeInterval = 0
    /// 0…1 meter level.
    var level: Float = 0
    var lines: [Line] = []
    var warning: String?
    var overrunMinutes: Int?
    var autoStopSeconds: Int?
    var autoStopReason: String?

    /// One plain sentence for the first problem worth knowing about.
    static func warning(quality: RecordingSession.AudioQualityState, micOnly: Bool, fallbackReason: String?) -> String? {
        switch quality {
        case .noInput: return "Your microphone isn't picking up any sound."
        case .lowInput: return "Your microphone level is very low."
        case .clipping: return "Your microphone is too loud, so audio may distort."
        case .good: break
        }
        // Mic only by choice (an in-room meeting) isn't a problem; system audio that was
        // asked for and isn't captured is.
        if micOnly && fallbackReason != nil {
            return "Other people aren't being recorded, only your microphone."
        }
        return nil
    }

    /// The last few utterances of the live transcript, newest last.
    static func lines(from words: [TranscriptWord], limit: Int = 6) -> [Line] {
        guard !words.isEmpty else { return [] }
        var result: [Line] = []
        var current: [String] = []
        var currentIsLocal = words[0].isLocalSpeaker == true
        var lastEnd = words[0].end
        for word in words.suffix(400) {
            let isLocal = word.isLocalSpeaker == true
            let gap = word.start - lastEnd
            if !current.isEmpty, (isLocal != currentIsLocal && gap > 1.5) || gap > 2.5 || current.count >= 40 {
                result.append(Line(id: result.count, text: current.joined(separator: " "), isLocal: currentIsLocal))
                current.removeAll()
                currentIsLocal = isLocal
            }
            current.append(word.word)
            lastEnd = word.end
        }
        if !current.isEmpty { result.append(Line(id: result.count, text: current.joined(separator: " "), isLocal: currentIsLocal)) }
        return Array(result.suffix(limit))
    }
}

// MARK: - Live view

/// Reads the session and draws `RecordingPillContent`.
private struct RecordingPillView: View {
    let session: RecordingSession
    @Bindable var model: RecordingPillModel
    let onStop: () -> Void
    let onOpenNotes: () -> Void
    let onHover: (Bool) -> Void
    let onLayoutChange: () -> Void

    @State private var isConfirmingStop = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            RecordingPillContent(
                state: state,
                showsPanel: model.showsPanel,
                opensLeft: model.opensLeft,
                isConfirmingStop: $isConfirmingStop,
                phase: context.date.timeIntervalSinceReferenceDate,
                actions: RecordingPillActions(
                    togglePause: {
                        if session.isPaused { session.resumeRecording() } else { session.pauseRecording() }
                    },
                    stop: onStop,
                    openNotes: onOpenNotes,
                    keepRecording: { session.cancelAutoStop() },
                    stopNow: { session.confirmAutoStop() }
                )
            )
        }
        .onHover(perform: onHover)
        .onChange(of: session.autoStopCountdown != nil || isConfirmingStop, initial: true) { _, forced in
            model.forcedExpanded = forced
            onLayoutChange()
        }
        .onChange(of: state.warning) { onLayoutChange() }
        .task(id: isConfirmingStop) {
            // Drop back if the user doesn't confirm.
            guard isConfirmingStop else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { isConfirmingStop = false }
        }
    }

    private var state: RecordingPillState {
        RecordingPillState(
            isPaused: session.isPaused,
            elapsed: session.elapsedTime,
            level: session.isPaused ? 0 : LiveAudioLevels.normalized(session.currentRMS),
            lines: model.showsPanel ? RecordingPillState.lines(from: session.transcriptWords) : [],
            warning: RecordingPillState.warning(
                quality: session.audioQualityState,
                micOnly: session.activeCaptureMode == .micOnly,
                fallbackReason: session.systemAudioFallbackReason
            ),
            overrunMinutes: session.calendarOverrunMinutes,
            autoStopSeconds: session.autoStopCountdown,
            autoStopReason: session.autoStopReason
        )
    }
}

struct RecordingPillActions {
    var togglePause: () -> Void = {}
    var stop: () -> Void = {}
    var openNotes: () -> Void = {}
    var keepRecording: () -> Void = {}
    var stopNow: () -> Void = {}
}

// MARK: - Content

/// The pill and, when open, the panel beside it. Always dark (a HUD), so it
/// reads the same over light and dark desktops.
struct RecordingPillContent: View {
    let state: RecordingPillState
    let showsPanel: Bool
    let opensLeft: Bool
    @Binding var isConfirmingStop: Bool
    var phase: TimeInterval = 0
    var actions = RecordingPillActions()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsPanel && opensLeft { panel }
            pill
            if showsPanel && !opensLeft { panel }
        }
        .padding(showsPanel ? RecordingPillMetrics.panelMargin : 0)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    // MARK: Pill

    private var tint: Color {
        if state.autoStopSeconds != nil || state.warning != nil { return .orange }
        return state.isPaused ? Color(white: 0.6) : Brand.red
    }

    private var pill: some View {
        HStack(spacing: 8) {
            LidIAMark()
                .frame(width: 15, height: 15)
            LevelMeter(level: state.level, isPaused: state.isPaused, tint: tint, phase: phase)
                .frame(width: 18, height: 14)
        }
        .frame(width: RecordingPillMetrics.pillSize.width, height: RecordingPillMetrics.pillSize.height)
        .background(HUDBackground(shape: Capsule()))
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.isPaused ? "LidIA recording paused" : "LidIA is recording")
        .accessibilityValue(ElapsedFormat.string(state.elapsed))
        .accessibilityHint("Hover to see the live transcript and controls")
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let seconds = state.autoStopSeconds {
                autoStop(seconds)
            } else {
                transcript
                if let warning = state.warning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
            }
        }
        .padding(14)
        .frame(width: RecordingPillMetrics.panelWidth, alignment: .leading)
        .background(HUDBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isPaused ? Color(white: 0.6) : Brand.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(state.isPaused ? "Paused" : "Recording")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            if let overrun = state.overrunMinutes, overrun > 0 {
                Text("\(overrun) min over")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ElapsedFormat.string(state.elapsed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Elapsed \(ElapsedFormat.string(state.elapsed))")
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var transcript: some View {
        if state.lines.isEmpty {
            Text(state.isPaused ? "Recording is paused." : "Listening… the transcript appears here as people speak.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 150, alignment: .bottomLeading)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(state.lines) { line in
                    Text(line.text)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(line.isLocal ? 0.95 : 0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            line.isLocal ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 150, alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Latest transcript")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isConfirmingStop {
            HStack(spacing: 8) {
                Text("Stop and write the notes?")
                    .font(.callout)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button("Keep Recording") { isConfirmingStop = false }
                    .buttonStyle(.glass)
                Button("Stop") {
                    isConfirmingStop = false
                    actions.stop()
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.red)
            }
            .controlSize(.small)
            .foregroundStyle(.white)
        } else {
            HStack(spacing: 8) {
                Button(action: actions.openNotes) {
                    Label("Open Notes", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.glass)
                .help("Open this meeting in LidIA")
                Spacer(minLength: 8)
                Button(action: actions.togglePause) {
                    Label(state.isPaused ? "Resume" : "Pause", systemImage: state.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glass)
                .help(state.isPaused ? "Resume recording" : "Pause recording")
                Button {
                    isConfirmingStop = true
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.red)
                .help("Stop recording and write the notes")
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
        }
    }

    private func autoStop(_ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stopping in \(seconds) s. \(state.autoStopReason ?? "The meeting seems to have ended.")")
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Keep Recording", action: actions.keepRecording)
                    .buttonStyle(.glass)
                Button("Stop Now", action: actions.stopNow)
                    .buttonStyle(.glassProminent)
                    .tint(Brand.red)
            }
            .controlSize(.small)
        }
    }
}

/// Dark translucent HUD fill with a hairline edge.
private struct HUDBackground<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.62))
            shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
    }
}

/// Live level bars: red while recording, grey and still while paused,
/// orange when something needs attention.
private struct LevelMeter: View {
    let level: Float
    let isPaused: Bool
    let tint: Color
    let phase: TimeInterval

    private static let weights: [Double] = [0.55, 1.0, 0.7]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3.5, height: height(index))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(_ index: Int) -> CGFloat {
        let minHeight: CGFloat = 4
        guard !isPaused else { return minHeight }
        let wobble = 0.8 + 0.2 * sin(phase * 9 + Double(index) * 1.7)
        let value = min(1, Double(level) * Self.weights[index] * 1.6 * wobble)
        return minHeight + (14 - minHeight) * CGFloat(value)
    }
}

/// The LidIA mark (the menu bar icon's waveform), drawn white. The asset
/// itself has no alpha channel, so it can't be tinted.
private struct LidIAMark: View {
    var body: some View {
        Image(systemName: "waveform")
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

// MARK: - Snapshots

/// Fixed states for the snapshot run (resting, hover, warning).
@MainActor
enum RecordingPillSnapshots {
    static func views() -> [(String, AnyView)] {
        let lines = [
            RecordingPillState.Line(id: 0, text: "So the landing zone is ready, we can start moving the staging workloads next week.", isLocal: false),
            RecordingPillState.Line(id: 1, text: "Great. Let's keep prod in its own account and review the guardrails on Monday.", isLocal: true),
            RecordingPillState.Line(id: 2, text: "Sounds good to me.", isLocal: false),
        ]
        let recording = RecordingPillState(isPaused: false, elapsed: 754, level: 0.55, lines: lines)
        var warning = recording
        warning.warning = RecordingPillState.warning(quality: .noInput, micOnly: false, fallbackReason: nil)
        var paused = recording
        paused.isPaused = true
        paused.level = 0
        var micOnly = recording
        micOnly.warning = RecordingPillState.warning(quality: .good, micOnly: true, fallbackReason: "Screen Recording permission is off")
        let none = Binding.constant(false)
        return [
            ("19-pill-resting", AnyView(RecordingPillContent(state: recording, showsPanel: false, opensLeft: true, isConfirmingStop: none, phase: 1.2))),
            ("20-pill-resting-paused", AnyView(RecordingPillContent(state: paused, showsPanel: false, opensLeft: true, isConfirmingStop: none))),
            ("21-pill-hover", AnyView(RecordingPillContent(state: recording, showsPanel: true, opensLeft: true, isConfirmingStop: none, phase: 1.2))),
            ("22-pill-warning", AnyView(RecordingPillContent(state: warning, showsPanel: true, opensLeft: true, isConfirmingStop: none, phase: 2))),
            ("23-pill-warning-resting", AnyView(RecordingPillContent(state: warning, showsPanel: false, opensLeft: true, isConfirmingStop: none, phase: 2))),
            ("24-pill-mic-only-paused", AnyView(RecordingPillContent(state: { var s = micOnly; s.isPaused = true; return s }(), showsPanel: true, opensLeft: true, isConfirmingStop: none))),
            ("25-pill-confirm-stop", AnyView(RecordingPillContent(state: recording, showsPanel: true, opensLeft: true, isConfirmingStop: .constant(true)))),
        ]
    }
}
