import AppKit
import LidIALiveActivity
import SwiftUI
import SwiftData

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private weak var session: RecordingSession?
    private weak var updateController: UpdateController?
    private var elapsedTimer: Timer?
    /// The recording as Live-Activity-shaped state: the status item's timer and the
    /// panel's expanded view both read it.
    let recordingFeed = RecordingActivityFeed()
    /// "Zoom call started", dropped from the icon.
    private let meetingPrompt = MeetingDetectedPromptController()

    func setup(environment: AppEnvironment, modelContainer: ModelContainer) {
        let session = environment.session
        let updateController = environment.updateController
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

        // The full shared set, like the scenes: the panel is its own SwiftUI root.
        let menuBarView = MenuBarView(feed: recordingFeed, close: { [weak self] in self?.closePanel() })
            .injectAppEnvironment(environment)
            .modelContainer(modelContainer)

        // Sized by its content, like a system menu bar extra: no fixed height,
        // no popover arrow.
        let hosting = NSHostingController(rootView: menuBarView)
        hosting.sizingOptions = [.preferredContentSize]
        let panel = MenuBarPanel(contentViewController: hosting)
        panel.delegate = self
        self.panel = panel

        self.session = session
        self.updateController = updateController
        observeRecordingState()
    }

    // MARK: - Recording state

    /// Re-renders the status item whenever recording starts, stops or pauses.
    private func observeRecordingState() {
        guard let session else { return }
        withObservationTracking {
            _ = session.isRecording
            _ = session.isPaused
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeRecordingState()
            }
        }
        updateRecordingAppearance()
    }

    private func updateRecordingAppearance() {
        let isRecording = session?.isRecording ?? false
        showRecordingIndicator(isRecording)
        if let session { recordingFeed.refresh(from: session) }
        if isRecording {
            // Recording started some other way: the call prompt has done its job.
            meetingPrompt.close()
            if elapsedTimer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                elapsedTimer = timer
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
        updateElapsedTitle()
    }

    private func tick() {
        if let session { recordingFeed.refresh(from: session) }
        updateElapsedTitle()
    }

    /// The compact presentation: the red dot (the icon) and the elapsed time.
    private func updateElapsedTitle() {
        guard let button = statusItem?.button else { return }
        guard let state = recordingFeed.state else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("LidIA")
            return
        }
        let elapsed = ElapsedFormat.string(state.elapsed(at: .now))
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: " " + elapsed,
            attributes: [.font: font, .foregroundColor: state.isPaused ? NSColor.systemOrange : Brand.nsRed]
        )
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(state.isPaused ? "LidIA, recording paused, \(elapsed)" : "LidIA, recording, \(elapsed)")
    }

    // MARK: - Meeting detected

    /// Drops "Zoom call started" from the icon, or shows the top-right banner when the
    /// icon can't be seen.
    func showMeetingDetected(
        _ state: MeetingDetectedActivityState,
        actions: MeetingDetectedActions,
        onExpire: @escaping () -> Void = {}
    ) {
        if panel?.isVisible == true { return }
        meetingPrompt.show(state, anchor: visibleStatusItemFrame, actions: actions, onExpire: onExpire)
    }

    func closeMeetingDetected() {
        meetingPrompt.close()
    }

    /// LidIA's icon in screen coordinates, or nil when it can't be seen (pushed into the
    /// menu bar's overflow, turned off in System Settings, or not set up yet).
    var visibleStatusItemFrame: NSRect? {
        guard let statusItem, statusItem.isVisible,
              let button = statusItem.button, let window = button.window,
              window.isVisible, window.occlusionState.contains(.visible) else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return MenuBarAnchoredLayout.isOnScreen(frame, screens: NSScreen.screens.map(\.frame)) ? frame : nil
    }

    #if DEBUG
    /// For the snapshot run.
    var debugMeetingPrompt: MeetingDetectedPromptController { meetingPrompt }
    var debugPanelWindow: NSPanel? { panel }
    func debugOpenPanel() { openPanel() }
    func debugClosePanel() { closePanel() }
    func debugRefreshRecording() { updateRecordingAppearance() }
    #endif

    // MARK: - Panel

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showContextMenu()
            return
        }
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let panel, let button = statusItem?.button else { return }
        meetingPrompt.close()
        if let session { recordingFeed.refresh(from: session) }
        panel.anchor = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        panel.positionUnderAnchor()
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// Keeps the panel's top edge pinned under the status item as its content grows or shrinks.
    func windowDidResize(_ notification: Notification) {
        panel?.positionUnderAnchor()
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - Context menu (right-click)

    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open LidIA", action: #selector(openLidIA), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",").target = self
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = updateController?.canCheckForUpdates ?? false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LidIA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openLidIA() { MenuBarActions.openMainWindow(post: .lidiaOpenHomeWorkspace) }
    @objc private func newNote() { MenuBarActions.openMainWindow(post: .lidiaCreateNote) }
    @objc private func openSettingsWindow() { MenuBarActions.openSettings() }
    @objc private func checkForUpdates() { updateController?.checkForUpdates() }

    func showRecordingIndicator(_ isRecording: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = isRecording ? Self.makeRecordingIcon() : Self.makeMenuBarIcon()
    }

    // MARK: - Custom Icon Drawing

    private static func makeMenuBarIcon() -> NSImage {
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            return icon
        }
        return drawLegacyMenuBarIcon()
    }

    /// Fallback template icon used when the asset catalog image is unavailable.
    private static func drawLegacyMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)

            // Ear outline — a C-shaped curve open to the left
            let ear = NSBezierPath()
            ear.lineWidth = 1.5
            ear.lineCapStyle = .round

            // Start bottom-left, curve up and around
            let cx = inset.midX + 1
            let cy = inset.midY
            let r: CGFloat = 7.0

            // Main ear arc (roughly 270° arc, open on the left)
            ear.appendArc(
                withCenter: NSPoint(x: cx, y: cy),
                radius: r,
                startAngle: 220,
                endAngle: -40,
                clockwise: true
            )
            NSColor.black.setStroke()
            ear.stroke()

            // Inner "canal" — a small inward hook at the bottom
            let canal = NSBezierPath()
            canal.lineWidth = 1.3
            canal.lineCapStyle = .round
            canal.move(to: NSPoint(x: cx - 1, y: cy - 2))
            canal.curve(to: NSPoint(x: cx + 1, y: cy + 2),
                        controlPoint1: NSPoint(x: cx + 3, y: cy - 1),
                        controlPoint2: NSPoint(x: cx + 3, y: cy + 1))
            canal.stroke()

            // Sound wave arcs — 2 concentric arcs to the left of the ear
            for i in 0..<2 {
                let waveR: CGFloat = CGFloat(3 + i * 3)
                let wave = NSBezierPath()
                wave.lineWidth = 1.2
                wave.lineCapStyle = .round
                wave.appendArc(
                    withCenter: NSPoint(x: cx - 3, y: cy),
                    radius: waveR,
                    startAngle: 140,
                    endAngle: 220,
                    clockwise: false
                )
                NSColor.black.withAlphaComponent(CGFloat(0.9 - Double(i) * 0.25)).setStroke()
                wave.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    /// Recording state icon: a record symbol in her red. Not a template image, so
    /// it stays red in both light and dark menu bars.
    private static func makeRecordingIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, Brand.nsRed]))
        if let symbol = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config) {
            symbol.isTemplate = false
            return symbol
        }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            Brand.nsRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Panel

/// A borderless, non-activating glass panel that drops from the status item,
/// the way system menu bar extras do (no popover arrow, sized to content).
final class MenuBarPanel: NSPanel {
    var anchor: NSRect?

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func positionUnderAnchor() {
        guard let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        setFrameOrigin(MenuBarAnchoredLayout.origin(size: frame.size, anchor: anchor, visibleFrame: screen.visibleFrame))
    }
}

// MARK: - Shared actions

@MainActor
enum MenuBarActions {
    static func openMainWindow(post name: Notification.Name? = nil) {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        if let name {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    static func openSettings(_ pane: SettingsPane? = nil) {
        if let pane {
            SettingsRouter.shared.open(pane)
        } else {
            SettingsRouter.bringWindowForward()
        }
    }
}
