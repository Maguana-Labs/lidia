#if DEBUG
import AppKit
import SwiftUI

/// DEBUG-only: with `LIDIA_SNAPSHOT_SETTINGS=<dir>` set, opens Settings,
/// visits every pane (plus sub-pages and search) in light and dark mode,
/// writes a PNG of each to `<dir>`, then quits. Lets the Settings design be
/// reviewed without Screen Recording permission.
///
/// Run the built app with `--demo` so the library stays in memory. It flips
/// appearance and AI provider while it runs and puts them back, but it (and
/// demo mode) write to the app's user defaults: `defaults export io.lidia.app`
/// first if you care. Optional: `LIDIA_SNAPSHOT_APPEARANCE=light|dark`,
/// `LIDIA_SNAPSHOT_ONLY=<substring of a shot name>`. The sidebar's vibrant
/// material can't be captured this way, so it is painted flat.
@MainActor
enum SettingsSnapshotter {
    private static var installed = false

    @discardableResult
    static func installIfRequested(settings: AppSettings) -> Bool {
        guard !installed,
              let dir = ProcessInfo.processInfo.environment["LIDIA_SNAPSHOT_SETTINGS"],
              !dir.isEmpty else { return false }
        installed = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await run(directory: URL(fileURLWithPath: dir), settings: settings)
        }
        return true
    }

    private static func run(directory: URL, settings: AppSettings) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let router = SettingsRouter.shared
        let only = ProcessInfo.processInfo.environment["LIDIA_SNAPSHOT_ONLY"]
        let originalAppearance = settings.appearanceMode
        let originalProvider = settings.llmProvider
        let originalDictation = settings.dictation.enabled
        let originalVoice = settings.voiceEnabled
        let originalGrok = settings.voiceLayer.grokVoiceEnabled
        let originalHybrid = settings.llm.hybridEnabled
        let originalHybridCloud = settings.llm.hybridCloudProvider
        let appearances: [(String, NSAppearance.Name, AppSettings.AppearanceMode)] = {
            let all: [(String, NSAppearance.Name, AppSettings.AppearanceMode)] = [
                ("light", .aqua, .light), ("dark", .darkAqua, .dark),
            ]
            if let mode = ProcessInfo.processInfo.environment["LIDIA_SNAPSHOT_APPEARANCE"] {
                return all.filter { $0.0 == mode }
            }
            return all
        }()

        // Close the main window so only Settings is on screen.
        for window in NSApp.windows where window.isVisible && !isSettingsWindow(window) {
            window.orderOut(nil)
        }

        for (name, appearanceName, mode) in appearances {
            NSApp.appearance = NSAppearance(named: appearanceName)
            settings.appearanceMode = mode
            SettingsRouter.bringWindowForward()
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: isSettingsWindow) else {
                print("SettingsSnapshotter: no Settings window")
                continue
            }
            window.appearance = NSAppearance(named: appearanceName)
            window.setContentSize(NSSize(width: 860, height: 640))
            window.center()

            var shots: [(String, () -> Void)] = []
            for (index, pane) in SettingsPane.allCases.enumerated() {
                shots.append((String(format: "%02d-%@", index + 1, pane.rawValue), {
                    router.searchText = ""
                    router.show(pane)
                }))
            }
            shots += [
                ("20-recording-advanced", {
                    router.expandedAdvanced.insert(.recording)
                    router.reveal(SettingsLocation(pane: .recording, anchor: .vadPrefilter, inAdvanced: true))
                }),
                ("21-recording-vocabulary", { router.show(.recording, subpage: .vocabulary) }),
                ("22-ai-models", { router.show(.ai, subpage: .onDeviceModels) }),
                ("23-ai-advanced", { router.show(.ai, subpage: .aiAdvanced) }),
                ("23b-ai-apikey", {
                    // Shows the cloud layout. Restored after the run.
                    settings.llmProvider = .anthropic
                    router.show(.ai)
                }),
                ("24-notes-template", { router.show(.notes, subpage: .template(MeetingTemplate.general.id)) }),
                ("25-apps-notion", { router.show(.apps, subpage: .integration(.notion)) }),
                ("26-apps-slack", { router.show(.apps, subpage: .integration(.slack)) }),
                ("27-search-quiet", {
                    router.show(.general)
                    router.searchText = "quiet"
                }),
                ("28-search-jump", {
                    if let entry = SettingsSearchIndex.search("quiet hours").first {
                        router.reveal(entry.location)
                    }
                }),
                ("29-search-apikey", { router.searchText = "api key" }),
                ("30-search-claude", { router.searchText = "claude" }),
                ("31-dictation-on", {
                    // Sample history in a temp file; restored after the run.
                    router.searchText = ""
                    DictationController.shared.history = sampleDictationHistory()
                    settings.dictation.enabled = true
                    router.show(.dictation)
                }),
                ("32-dictation-history", {
                    router.reveal(SettingsLocation(pane: .dictation, anchor: .dictationHistory))
                }),
                ("33-search-dictation", { router.searchText = "dictation" }),
                ("34-voice-grok", {
                    router.searchText = ""
                    settings.voiceEnabled = true
                    settings.voiceLayer.grokVoiceEnabled = true
                    router.show(.voice)
                }),
                ("35-ai-hybrid-offer", {
                    // A key typed for the shot stays in memory: the Keychain
                    // is off during snapshot runs.
                    settings.llmProvider = .automaticLocal
                    settings.llm.hybridEnabled = false
                    settings.llm.hybridOfferHandled = false
                    settings.llm.anthropicAPIKey = "sk-ant-snapshot"
                    router.show(.ai)
                }),
                ("36-ai-hybrid", {
                    settings.llm.hybridCloudProvider = .anthropic
                    settings.llm.hybridEnabled = true
                    // A per-task pick other than the default, to show the pair.
                    settings.setRouteConfig(LLMRouteConfig(provider: .automaticLocal, model: ""), for: .followUp)
                    NSApp.windows.first(where: isSettingsWindow)?.setContentSize(NSSize(width: 860, height: 980))
                    router.show(.ai)
                }),
                ("37-ai-hybrid-tasks", {
                    router.reveal(SettingsLocation(pane: .ai, anchor: .aiModel))
                }),
                ("38-ai-subscription-codex", {
                    settings.setRouteConfig(nil, for: .followUp)
                    NSApp.windows.first(where: isSettingsWindow)?.setContentSize(NSSize(width: 860, height: 640))
                    settings.llm.hybridEnabled = false
                    settings.llmProvider = .codexCLI
                    router.show(.ai)
                }),
                ("39-ai-subscription-grok", {
                    settings.llmProvider = .grokCLI
                    router.show(.ai)
                }),
                ("40-ai-advanced-subscriptions", {
                    settings.llmProvider = .automaticLocal
                    router.show(.ai, subpage: .aiAdvanced)
                }),
            ]

            for (shotName, action) in shots {
                if let only, !shotName.contains(only) { continue }
                action()
                try? await Task.sleep(for: .seconds(shotName.contains("jump") ? 0.5 : 1.0))
                capture(window, to: directory.appendingPathComponent("\(name)-\(shotName).png"))
            }
            router.searchText = ""
        }

        settings.appearanceMode = originalAppearance
        settings.llmProvider = originalProvider
        settings.dictation.enabled = originalDictation
        settings.voiceEnabled = originalVoice
        settings.voiceLayer.grokVoiceEnabled = originalGrok
        settings.llm.hybridEnabled = originalHybrid
        settings.llm.hybridCloudProvider = originalHybridCloud
        if only.map({ $0.contains("hud") || $0.contains("dictation") }) ?? true {
            captureDictationHUD(to: directory)
        }
        print("SettingsSnapshotter: wrote snapshots to \(directory.path)")
        NSApp.terminate(nil)
    }

    /// A few made-up dictations in a temporary file (never the real history).
    private static func sampleDictationHistory() -> DictationHistory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lidia-snapshot-dictation-\(UUID().uuidString).json")
        let history = DictationHistory(fileURL: url)
        let samples: [(String, String, String, Int)] = [
            ("Can we move the TAPR review with Acme to Thursday at 3?", "Slack", "Typed", 212),
            ("Thanks for the notes. I'll send the proposal by Friday.", "Mail", "Typed", 188),
            ("Next steps:\n1. Share the deck\n2. Book the follow-up", "Notion", "Pasted", 341),
        ]
        for (offset, sample) in samples.enumerated().reversed() {
            history.add(DictationRecord(
                date: Date(timeIntervalSinceNow: Double(-offset * 900 - 120)),
                text: sample.0, rawText: sample.0, appName: sample.1, outcome: sample.2, latencyMilliseconds: sample.3
            ), limit: 25)
        }
        return history
    }

    /// The dictation HUD in each state, light and dark, via ImageRenderer.
    /// The glass material doesn't render offscreen, so a plain capsule stands in.
    static func captureDictationHUD(to directory: URL) {
        let states: [(String, DictationHUDModel.Phase, String, [Float])] = [
            ("listening", .listening, "Can we move the TAPR review with Acme to Thurs", [0.2, 0.45, 0.7, 0.55, 0.85, 0.6, 0.4, 0.65, 0.3]),
            ("empty", .listening, "", [0.05, 0.1, 0.08, 0.12, 0.06, 0.1, 0.05, 0.09, 0.07]),
            ("handsfree", .locked, "First, share the deck. Second, book the follow-up", [0.3, 0.5, 0.4, 0.6, 0.35, 0.55, 0.7, 0.45, 0.5]),
            ("finishing", .finishing, "Can we move the TAPR review with Acme to Thursday at 3?", Array(repeating: 0, count: 9)),
            ("error", .message("Not typed into a password field. It's in History.", isError: true), "", Array(repeating: 0, count: 9)),
        ]
        for (scheme, colorScheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for (name, phase, text, levels) in states {
                let model = DictationHUDModel()
                model.reset(keySymbol: "⌥")
                model.phase = phase
                model.partialText = text
                model.levels = levels
                let view = ZStack {
                    LinearGradient(colors: colorScheme == .dark ? [Color(white: 0.12), Color(white: 0.2)] : [Color(white: 0.86), Color(white: 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                    DictationHUDView(model: model, opaqueBackground: true)
                }
                .frame(width: 440, height: 90)
                .environment(\.colorScheme, colorScheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                renderer.colorMode = .nonLinear
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: directory.appendingPathComponent("\(scheme)-hud-\(name).png"))
            }
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        return id.hasPrefix("com_apple_SwiftUI_Settings")
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        // The sidebar's vibrant material doesn't come through cacheDisplay:
        // paint a stand-in for it, lay the window on top, then draw each
        // sidebar list on its own in the window's appearance.
        guard let canvas = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.955, alpha: 1)).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for table in tables(in: view) {
            guard let tableRep = table.bitmapImageRepForCachingDisplay(in: table.visibleRect) else { continue }
            // Without the material behind it, vibrant text draws dark; draw
            // the list in the plain appearance instead.
            let saved = table.appearance
            table.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            table.cacheDisplay(in: table.visibleRect, to: tableRep)
            table.appearance = saved
            var rect = table.convert(table.visibleRect, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            tableRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = canvas.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }
}
#endif
