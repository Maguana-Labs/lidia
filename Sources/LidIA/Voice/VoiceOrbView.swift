import SwiftUI

struct VoiceOrbView: View {
    let state: VoiceInputController.State
    let audioLevel: Float
    let isMuted: Bool
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?
    var onMute: (() -> Void)?

    // Brand colors: the icon's glass, crimson through her red to a coral and ivory highlight.
    private let red = Color(nsColor: NSColor(hex: Brand.Hex.red))
    private let coral = Brand.coral
    private let glow = Color(nsColor: NSColor(hex: Brand.Hex.rose))
    private let crimson = Brand.crimson

    var body: some View {
        VStack(spacing: 12) {
            // Close button (top-right)
            HStack {
                Spacer()
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.25))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("End voice mode")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // Orb
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let baseRadius = min(size.width, size.height) / 2 - 10
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    drawOrb(context: context, center: center, baseRadius: baseRadius, time: time)
                }
                .frame(width: 140, height: 140)
            }
            .contentShape(Circle())
            .onTapGesture {
                onTap?()
            }

            // State hint
            Text(stateHint)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))

            // Bottom controls
            HStack(spacing: 16) {
                Button {
                    onMute?()
                } label: {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.caption)
                        .foregroundStyle(isMuted ? .red : .white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute" : "Mute")
            }
            .padding(.bottom, 8)
        }
        .frame(width: 200)
    }

    private var stateHint: String {
        if isMuted { return "Muted" }
        switch state {
        case .idle: return "Tap to start"
        case .listening: return "Listening — tap to send"
        case .thinking: return "Thinking..."
        case .speaking: return "Speaking..."
        }
    }

    private func drawOrb(context: GraphicsContext, center: CGPoint, baseRadius: Double, time: Double) {
        let level = isMuted ? 0.0 : Double(audioLevel)
        let distortion: Double
        let glowRadius: Double
        let gradient: Gradient

        switch state {
        case .idle:
            let breath = sin(time * 2.0) * 0.02 + 1.0
            distortion = 0
            glowRadius = baseRadius * breath
            gradient = Gradient(colors: [red.opacity(0.6), glow.opacity(0.4)])

        case .listening:
            distortion = level * 20
            glowRadius = baseRadius * (1.0 + level * 0.3)
            if isMuted {
                gradient = Gradient(colors: [red.opacity(0.3), coral.opacity(0.2), glow.opacity(0.2)])
            } else {
                gradient = Gradient(colors: [red, coral, glow.opacity(0.6)])
            }

        case .thinking:
            let rotate = time.truncatingRemainder(dividingBy: 2.0) / 2.0
            distortion = sin(rotate * .pi * 2) * 8
            glowRadius = baseRadius * (0.9 + sin(time * 3) * 0.05)
            gradient = Gradient(colors: [crimson, glow, red.opacity(0.3)])

        case .speaking:
            distortion = level * 15
            glowRadius = baseRadius * (1.0 + level * 0.2)
            gradient = Gradient(colors: [red, coral, glow])
        }

        // Outer glow
        let glowRect = CGRect(
            x: center.x - glowRadius - 10,
            y: center.y - glowRadius - 10,
            width: (glowRadius + 10) * 2,
            height: (glowRadius + 10) * 2
        )
        let glowPath = Circle().path(in: glowRect)
        context.fill(glowPath, with: .radialGradient(
            Gradient(colors: [red.opacity(0.3), .clear]),
            center: center,
            startRadius: glowRadius * 0.5,
            endRadius: glowRadius + 20
        ))

        // Main orb with distortion
        let orbPath = Path { path in
            let segments = 64
            for i in 0...segments {
                let angle = Double(i) / Double(segments) * .pi * 2
                let noise = sin(angle * 3 + time * 4) * distortion
                let r = glowRadius + noise
                let point = CGPoint(
                    x: center.x + cos(angle) * r,
                    y: center.y + sin(angle) * r
                )
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
        }

        context.fill(orbPath, with: .radialGradient(
            gradient,
            center: center,
            startRadius: 0,
            endRadius: glowRadius
        ))
    }
}
