import SwiftUI

/// A 3×3 pixel grid with a diagonal shimmer: the "working" mark. Static under
/// Reduce Motion.
struct ChatPixelLoader: View {
    var size: CGFloat = 14
    var color: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, canvasSize in
                let gap = canvasSize.width * 0.12
                let cell = (canvasSize.width - gap * 2) / 3
                for row in 0..<3 {
                    for column in 0..<3 {
                        let phase = Double(row + column) * 0.55
                        let wave = reduceMotion ? 0.55 : (sin(t * 4.2 - phase) + 1) / 2
                        let opacity = 0.18 + 0.82 * wave
                        let rect = CGRect(
                            x: CGFloat(column) * (cell + gap),
                            y: CGFloat(row) * (cell + gap),
                            width: cell, height: cell
                        )
                        canvas.fill(Path(roundedRect: rect, cornerRadius: cell * 0.28), with: .color(color.opacity(opacity)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Text with a light sweeping across it. Plain under Reduce Motion.
struct ChatShimmerText: View {
    var text: String
    var font: Font = .callout

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).font(font).foregroundStyle(.secondary)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let x = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8 * 1.8 - 0.4
                Text(text)
                    .font(font)
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: .secondary, location: 0),
                                .init(color: .primary, location: 0.5),
                                .init(color: .secondary, location: 1),
                            ],
                            startPoint: UnitPoint(x: x - 0.35, y: 0.5),
                            endPoint: UnitPoint(x: x + 0.35, y: 0.5)
                        )
                    )
            }
        }
    }
}

/// "▦ Searching your meetings · 2.4s": what the agent is doing right now.
struct ChatWorkingRow: View {
    let run: AgentRun

    @Environment(\.chatDensity) private var density

    private var label: String {
        let running = run.steps.last { $0.status == .running }
        return ChatStepPresentation.phaseLabel(phase: run.phase, runningTool: running?.toolName, runningSummary: running?.summary)
    }

    var body: some View {
        HStack(spacing: 9) {
            ChatPixelLoader(size: density == .regular ? 14 : 12)
            ChatShimmerText(text: label, font: .system(size: density.bodySize - 0.5, weight: .medium))
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: label)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(ChatStepPresentation.elapsed(run.elapsed))
                    .font(.system(size: density.smallSize).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(Int(run.elapsed)) seconds")
    }
}
