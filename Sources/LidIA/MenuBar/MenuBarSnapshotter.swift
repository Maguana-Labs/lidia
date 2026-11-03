#if DEBUG
import AppKit
import LidIALiveActivity
import SwiftUI

/// DEBUG-only: with `LIDIA_SNAPSHOT_MENUBAR=<dir>` set, shows a made-up recording in the
/// real menu bar panel and a made-up "Zoom call started" prompt under the real status
/// item, records where each went in `menubar-report.txt`, writes PNGs of both views
/// (light and dark), then quits. No Screen Recording permission needed.
///
/// The PNGs are the views rendered off screen with `menuBarFlatRendering` (solid card,
/// bordered buttons): glass is composited by the window server, and capturing the live
/// panel loses it along with most of the panel's content.
///
/// A snapshot run: the library is in memory and no background services start. Run a
/// copy of the app with its own bundle ID so defaults are isolated too, e.g.
/// `io.lidia.app.menubar-snapshot` (see CLAUDE.md, "Menu bar Live Activities").
@MainActor
enum MenuBarSnapshotter {
    static let environmentKey = "LIDIA_SNAPSHOT_MENUBAR"
    private static var installed = false

    static func installIfRequested(menuBar: MenuBarController, session: RecordingSession) {
        guard !installed, let dir = ProcessInfo.processInfo.environment[environmentKey], !dir.isEmpty else { return }
        installed = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await run(directory: URL(fileURLWithPath: dir), menuBar: menuBar, session: session)
        }
    }

    private static func run(directory: URL, menuBar: MenuBarController, session: RecordingSession) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String] = []
        guard let context = AppDelegate.modelContainer?.mainContext else {
            print("MenuBarSnapshotter: no model container")
            exit(1)
        }

        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)

            // The recording, in the real panel under the real status item.
            let variants: [(String, Bool, Bool)] = [
                ("recording", false, false),
                ("recording-paused", true, false),
                ("recording-warning", false, true),
            ]
            for (name, paused, warning) in variants {
                LiveSnapshotFixture.begin(in: context, session: session, paused: paused, systemAudioMissing: warning)
                menuBar.debugRefreshRecording()
                menuBar.debugPanelWindow?.appearance = NSAppearance(named: appearance)
                menuBar.debugOpenPanel()
                try? await Task.sleep(for: .seconds(3))
                if let panel = menuBar.debugPanelWindow {
                    if mode == "light" {
                        report.append("\(name): panel frame \(panel.frame), status item \(String(describing: menuBar.visibleStatusItemFrame)), feed state title=\(menuBar.recordingFeed.state?.title ?? "nil") paused=\(menuBar.recordingFeed.state?.isPaused ?? false) line=\(menuBar.recordingFeed.state?.lastLine?.text ?? "nil") warning=\(menuBar.recordingFeed.state?.warning ?? "nil")")
                    }
                }
                menuBar.debugClosePanel()
            }
            // The expanded view on its own, in the panel's glass container.
            if let state = menuBar.recordingFeed.state {
                for (suffix, variant) in [("", state), ("-paused", { var s = state; s.pausedElapsed = 47; return s }())] {
                    let view = RecordingActivityExpandedView(
                        state: variant,
                        level: { 0.12 },
                        initialLevels: (0..<36).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) },
                        actions: RecordingActivityActions(openNotes: {})
                    )
                    .frame(width: 320)
                    .menuBarCard(cornerRadius: 16)
                    render(AnyView(view), appearance: appearance, to: directory.appendingPathComponent("\(mode)-menubar-expanded\(suffix).png"))
                }
            }
            session.endSnapshotRecording()
            menuBar.debugRefreshRecording()
            try? await Task.sleep(for: .seconds(0.5))

            // "Zoom call started", shown the way the app shows it.
            let state = MeetingDetectedActivityState(
                meetingName: "Zoom",
                appName: "Zoom",
                bundleID: "us.zoom.xos",
                calendarTitle: "Onboarding launch plan",
                detectedAt: .now.addingTimeInterval(-25)
            )
            menuBar.showMeetingDetected(state, actions: MeetingDetectedActions())
            try? await Task.sleep(for: .seconds(1.2))
            let prompt = menuBar.debugMeetingPrompt
            if mode == "light" {
                report.append("meeting-detected: presentation=\(String(describing: prompt.presentation)), prompt frame=\(String(describing: prompt.debugPanel?.frame)), status item=\(String(describing: menuBar.visibleStatusItemFrame))")
            }
            menuBar.closeMeetingDetected()
            render(AnyView(MeetingDetectedActivityView(state: state, appIcon: NSWorkspace.shared.icon(for: .applicationBundle))),
                   appearance: appearance, to: directory.appendingPathComponent("\(mode)-menubar-meeting-detected.png"))

            // The prompt's view on its own (also when the icon is in the overflow and the
            // banner was used), without a calendar meeting.
            let plain = MeetingDetectedActivityState(
                meetingName: "Google Meet", appName: "Google Chrome", bundleID: "com.google.Chrome",
                detectedAt: .now.addingTimeInterval(-70)
            )
            render(AnyView(MeetingDetectedActivityView(state: plain, appIcon: NSWorkspace.shared.icon(for: .applicationBundle))),
                   appearance: appearance, to: directory.appendingPathComponent("\(mode)-menubar-meeting-detected-browser.png"))
        }

        let text = report.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("menubar-report.txt"), atomically: true, encoding: .utf8)
        print("MenuBarSnapshotter: wrote snapshots to \(directory.path)")
        print(text)
        exit(0)
    }

    /// An off-screen view in a window of its own (materials only draw inside a window).
    private static func render(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) {
        let isDark = appearance == .darkAqua
        let hosting = NSHostingView(rootView: view
            .padding(20)
            .background(isDark ? Color(white: 0.12) : Color(white: 0.80))
            .environment(\.colorScheme, isDark ? .dark : .light)
            .environment(\.menuBarFlatRendering, true))
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
#endif
