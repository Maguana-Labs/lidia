import SwiftUI

// MARK: - Card

/// A rounded card on the grouped background. The building block of every screen.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// Title with an optional trailing "See all".
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle) {
                    Haptics.tap()
                    action()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A thin inset divider between rows in a card.
struct RowDivider: View {
    var leading: CGFloat = Metrics.rowIcon + 28

    var body: some View {
        Rectangle()
            .fill(Surface.hairline.opacity(0.6))
            .frame(height: 1 / 3)
            .padding(.leading, leading)
    }
}

// MARK: - Glyphs

/// The "logo" of a meeting in lists: a soft tinted tile with one symbol.
struct MeetingGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Metrics.rowIcon

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(tint.gradient.opacity(0.16))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A person: initials on a tinted circle.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 32
    var ring: Color? = nil

    var body: some View {
        let tint = Tint.color(for: name)
        Circle()
            .fill(tint.gradient)
            .overlay {
                Text(Format.initials(Format.displayName(name)))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay {
                if let ring { Circle().strokeBorder(ring, lineWidth: 2) }
            }
            .frame(width: size, height: size)
            .accessibilityLabel(Format.displayName(name))
    }
}

/// Overlapping avatars with a "+3" tail.
struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 28
    var ring: Color = Surface.card
    var limit = 4

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(limit).enumerated()), id: \.offset) { _, name in
                PersonAvatar(name: name, size: size, ring: ring)
            }
            if names.count > limit {
                Circle()
                    .fill(Surface.inset)
                    .overlay {
                        Text("+\(names.count - limit)")
                            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .overlay { Circle().strokeBorder(ring, lineWidth: 2) }
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.map(Format.displayName).joined(separator: ", "))
    }
}

// MARK: - Buttons

/// Pill buttons for the hero card: solid ivory with crimson text, or frosted.
struct HeroPillStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Brand.crimson : Brand.ivory)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(Brand.ivory) : AnyShapeStyle(Brand.ivory.opacity(0.18)))
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A large square-ish action tile (two per row), as in a card detail screen.
struct ActionTile: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.13), in: .circle)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: .rect(cornerRadius: Metrics.tileRadius, style: .continuous))
            .contentShape(.rect(cornerRadius: Metrics.tileRadius))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Subtle press feedback for custom tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A key/value row in a grouped "details" list, with an optional trailing action.
struct DetailRow: View {
    let label: String
    let value: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle) {
                    Haptics.tap()
                    action()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A small rounded chip ("Due today", "On-device").
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.caption2.weight(.semibold))
            }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

/// The waveform motif from the logo, used as an illustration.
struct WaveMark: Shape {
    var phase: Double = 0
    var amplitude: Double = 0.32

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let steps = 80
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let x = rect.minX + rect.width * t
            // A swell in the middle, like the icon's waveform.
            let envelope = sin(.pi * t)
            let y = mid - rect.height * amplitude * envelope * sin(t * .pi * 5 + phase)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

/// An empty state inside a card.
struct CardEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}
