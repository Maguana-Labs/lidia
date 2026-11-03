import AppKit
import SwiftUI

/// "Meeting detected" as a notification: top-right, just under the menu bar, like
/// macOS's own banners. It never sits in the middle of the screen over a window's
/// toolbar. The fallback for `MeetingDetectedPromptController` when LidIA's menu bar
/// icon can't be seen; normally the prompt drops from the icon instead.
@MainActor
final class MeetingDetectionBannerController {
    private var panel: NSPanel?
    private var autoDismissTask: Task<Void, Never>?

    func show(
        appName: String,
        bundleID: String,
        autoDismissAfter: TimeInterval = 20,
        onRecord: @escaping () -> Void,
        onNever: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        if panel?.isVisible == true { return }
        close()

        let content = MeetingDetectionBannerView(
            appName: appName,
            appIcon: Self.icon(for: bundleID),
            neverTitle: MeetingDetectionBannerView.neverTitle(bundleID: bundleID),
            onRecord: { [weak self] in
                onRecord()
                self?.close()
            },
            onNever: { [weak self] in
                onNever()
                self?.close()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.close()
            }
        )

        let hosting = NSHostingView(rootView: content)
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
        panel.animationBehavior = .alertPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting

        let screen = Self.statusItemScreen() ?? NSScreen.main
        if let screen {
            panel.setFrameOrigin(MeetingDetectionBannerLayout.origin(
                bannerSize: size,
                visibleFrame: screen.visibleFrame,
                statusItemFrame: Self.statusItemFrame()
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(autoDismissAfter))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.close()
        panel = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// LidIA's menu bar icon, in screen coordinates.
    private static func statusItemFrame() -> NSRect? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") && $0.isVisible }?.frame
    }

    private static func statusItemScreen() -> NSScreen? {
        guard let frame = statusItemFrame() else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(frame) }
    }
}

enum MeetingDetectionBannerLayout {
    static let margin: CGFloat = 10

    /// Under the menu bar, right-aligned with LidIA's menu bar icon when known (else the
    /// screen's right edge), and always fully on screen.
    static func origin(bannerSize: CGSize, visibleFrame: NSRect, statusItemFrame: NSRect?) -> NSPoint {
        let preferredRight = statusItemFrame.map { $0.maxX + 8 } ?? (visibleFrame.maxX - margin)
        let right = min(preferredRight, visibleFrame.maxX - margin)
        let x = max(visibleFrame.minX + margin, right - bannerSize.width)
        let y = visibleFrame.maxY - bannerSize.height - margin
        return NSPoint(x: x, y: y)
    }
}

// MARK: - View

struct MeetingDetectionBannerView: View {
    let appName: String
    var appIcon: NSImage?
    var neverTitle: String
    var onRecord: () -> Void = {}
    var onNever: () -> Void = {}
    var onDismiss: () -> Void = {}

    static func neverTitle(bundleID: String) -> String {
        "Never for \(appName(bundleID: bundleID))"
    }

    /// The app "Never for …" turns detection off for (the browser for a web meeting).
    static func appName(bundleID: String) -> String {
        MeetingAppRules.nativeMeetingApps[bundleID]
            ?? MeetingAppRules.browsers[bundleID]
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
            ?? "This App"
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting detected")
                    .font(.callout.weight(.semibold))
                Text(appName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.red)
            .help("Record this meeting and take notes")

            Menu {
                Button("Not Now", action: onDismiss)
                Button(neverTitle, action: onNever)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options")
            .help("Not now, or never for this app")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting detected: \(appName)")
    }

    @ViewBuilder
    private var icon: some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
    }
}
