import AppKit
import SwiftUI

/// What the HUD shows.
@MainActor
@Observable
final class DictationHUDModel {
    enum Phase: Equatable {
        case listening
        /// Hands-free (double-tapped).
        case locked
        case finishing
        case message(String, isError: Bool)
    }

    var phase: Phase = .listening
    /// Recent levels, oldest first, 0…1.
    var levels: [Float] = Array(repeating: 0, count: DictationHUDModel.barCount)
    var partialText = ""
    var keySymbol = "⌥"

    static let barCount = 9

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset(keySymbol: String) {
        phase = .listening
        levels = Array(repeating: 0, count: Self.barCount)
        partialText = ""
        self.keySymbol = keySymbol
    }
}

/// A small capsule near the bottom of the screen: a level meter and the words
/// so far. Calm by design: no colour except while listening, no sound.
struct DictationHUDView: View {
    let model: DictationHUDModel
    /// Snapshots can't capture the glass material; draw a plain capsule instead.
    var opaqueBackground = false

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 44, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(width: 380, height: 50)
        .background { background }
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .animation(.easeOut(duration: 0.15), value: model.partialText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var background: some View {
        if opaqueBackground {
            Capsule().fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else {
            Capsule().fill(.clear)
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch model.phase {
        case .listening, .locked:
            LevelMeter(levels: model.levels, tint: model.phase == .locked ? .orange : .accentColor)
        case .finishing:
            ProgressView().controlSize(.small)
        case .message(_, let isError):
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(isError ? .orange : .green)
        }
    }

    private var isPlaceholder: Bool {
        if case .message = model.phase { return false }
        return model.partialText.isEmpty
    }

    private var primaryText: String {
        switch model.phase {
        case .message(let text, _): return text
        case .finishing where model.partialText.isEmpty: return "Finishing…"
        default: return model.partialText.isEmpty ? "Listening…" : model.partialText
        }
    }

    private var hint: String? {
        switch model.phase {
        case .listening: "Release \(model.keySymbol) to insert · Esc to cancel"
        case .locked: "Hands-free · tap \(model.keySymbol) to insert · Esc to cancel"
        case .finishing: nil
        case .message: nil
        }
    }

    private var accessibilityText: String {
        switch model.phase {
        case .message(let text, _): text
        case .finishing: "Dictation finishing"
        default: "Dictating. \(model.partialText)"
        }
    }
}

private struct LevelMeter: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint.opacity(0.35 + Double(level) * 0.65))
                    .frame(width: 2.5, height: 3 + CGFloat(level) * 19)
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// Never key, never main: the app you're typing in keeps focus.
private final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the HUD panel.
@MainActor
final class DictationHUDController {
    let model = DictationHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    /// Bumped by `show()`, so a fade-out that finishes late can't hide a newer HUD.
    private var generation = 0

    func show() {
        hideTask?.cancel()
        generation += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            let generation = self.generation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    panel.orderOut(nil)
                }
            }
        }
    }

    func showMessage(_ text: String, isError: Bool, for duration: Duration = .seconds(2)) {
        model.phase = .message(text, isError: isError)
        show()
        hide(after: duration)
    }

    private func makePanel() -> NSPanel {
        let panel = DictationHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 70),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: DictationHUDView(model: model).padding(10))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 70)
        panel.contentView = host
        return panel
    }

    /// Bottom centre of the screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 56))
    }
}
