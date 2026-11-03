import AppKit
import LidIALiveActivity
import SwiftUI

/// "Zoom call started" as a small prompt anchored under LidIA's menu bar icon, the way
/// a Live Activity's alert drops from the menu bar. It ends by itself after
/// `MeetingDetectedActivityState.lifetime`, and the app closes it when the meeting app
/// releases the microphone. When the icon can't be seen (hidden by the menu bar's
/// overflow or turned off in System Settings), the top-right `MeetingDetectionBanner`
/// is shown instead.
@MainActor
final class MeetingDetectedPromptController {
    private var panel: NSPanel?
    private var expiryTask: Task<Void, Never>?
    private let fallback = MeetingDetectionBannerController()
    private(set) var state: MeetingDetectedActivityState?

    /// How the last prompt was shown, for logs and the snapshot run.
    enum Presentation: Equatable { case anchored(NSRect), banner }
    private(set) var presentation: Presentation?

    var isVisible: Bool { panel?.isVisible == true || fallback.isVisible }

    /// - Parameters:
    ///   - anchor: LidIA's menu bar icon in screen coordinates, or nil when it isn't visible.
    ///   - onExpire: runs when it ends by itself.
    func show(
        _ state: MeetingDetectedActivityState,
        anchor: NSRect?,
        actions: MeetingDetectedActions,
        onExpire: @escaping () -> Void = {}
    ) {
        if self.state?.bundleID == state.bundleID, isVisible { return }
        close()
        self.state = state

        let icon = Self.icon(for: state.bundleID)
        if let anchor, let screen = MenuBarAnchoredLayout.screen(containing: anchor) {
            let view = MeetingDetectedActivityView(
                state: state,
                appIcon: icon,
                actions: MeetingDetectedActions(
                    record: { [weak self] in self?.close(); actions.record() },
                    notNow: { [weak self] in self?.close(); actions.notNow() },
                    never: { [weak self] in self?.close(); actions.never() }
                )
            )
            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .alertPanel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = hosting
            panel.setFrameOrigin(MenuBarAnchoredLayout.origin(size: size, anchor: anchor, visibleFrame: screen.visibleFrame))
            panel.orderFrontRegardless()
            self.panel = panel
            presentation = .anchored(anchor)
        } else {
            fallback.show(
                appName: state.meetingName,
                bundleID: state.bundleID,
                autoDismissAfter: state.remaining(at: .now),
                onRecord: actions.record,
                onNever: actions.never,
                onDismiss: actions.notNow
            )
            presentation = .banner
        }

        let remaining = state.remaining(at: .now)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self, self.state == state else { return }
            self.close()
            onExpire()
        }
    }

    func close() {
        expiryTask?.cancel()
        expiryTask = nil
        panel?.close()
        panel = nil
        fallback.close()
        state = nil
    }

    #if DEBUG
    /// The anchored prompt's window, for the snapshot run.
    var debugPanel: NSPanel? { panel }
    #endif

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Where panels that drop from the menu bar icon go.
enum MenuBarAnchoredLayout {
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// Centered under `anchor` (the icon, screen coordinates), `gap` below it, and kept
    /// `margin` inside the screen's sides.
    static func origin(size: CGSize, anchor: NSRect, visibleFrame: NSRect) -> NSPoint {
        var x = anchor.midX - size.width / 2
        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - size.width - margin)
        let y = anchor.minY - gap - size.height
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Whether an icon frame is somewhere you can see it: on a screen, with a size.
    /// Icons pushed out by the menu bar's overflow sit off every screen.
    static func isOnScreen(_ frame: NSRect, screens: [NSRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return screens.contains { $0.contains(center) }
    }

    static func screen(containing anchor: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
    }
}
