import AppKit
import LidIAKit
import SwiftUI

/// LidIA's palette: her red, ink and warm ivory (`LidIABrand` in LidIAKit holds
/// the hex values and why). The "Paper" balance: red only where it matters
/// (record and live, the accent, AI and brand moments); everything else stays
/// neutral. Errors and destructive actions keep the system red with an icon and
/// words, so they never look like a brand accent.
///
/// The `AccentColor` asset (named in Info.plist) holds the same red, so
/// selection, prominent buttons, links and toggles follow it.
enum Brand {
    typealias Hex = LidIABrand.Hex

    /// Her red, the one red for record, live and brand moments. Deeper in
    /// light, brighter in dark so it reads on dark surfaces.
    static let nsRed = NSColor.lidia(light: Hex.red, dark: Hex.redDark, name: "LidIARed")
    static let red = Color(nsColor: nsRed)
    /// The recording red: her red.
    static let record = red
    /// The deep end of the icon's glass.
    static let crimson = Color(nsColor: NSColor(hex: Hex.crimson))
    /// The glass highlight.
    static let coral = Color(nsColor: NSColor(hex: Hex.coral))
    static let ink = Color(nsColor: NSColor(hex: Hex.ink))
    static let ivory = Color(nsColor: NSColor(hex: Hex.ivory))

    /// Warm companions for kinds of suggestions (For You); AA as text in both
    /// appearances, and white on each passes AA in light.
    static let ember = Color(nsColor: .lidia(light: Hex.ember, dark: Hex.emberDark, name: "LidIAEmber"))
    static let amber = Color(nsColor: .lidia(light: Hex.amber, dark: Hex.amberDark, name: "LidIAAmber"))
    static let berry = Color(nsColor: .lidia(light: Hex.berry, dark: Hex.berryDark, name: "LidIABerry"))
    /// The same three as solid fills under a white glyph (icon tiles), in both appearances.
    static let emberSolid = Color(nsColor: NSColor(hex: Hex.ember))
    static let amberSolid = Color(nsColor: NSColor(hex: Hex.amber))
    static let berrySolid = Color(nsColor: NSColor(hex: Hex.berry))

    /// People: warm, muted hues that sit beside her red (white initials pass AA).
    static let avatarPalette: [Color] = Hex.avatars.map { Color(nsColor: NSColor(hex: $0)) }

    /// The AI sparkle and other brand marks: her red into the glass highlight.
    static let mark = LinearGradient(colors: [red, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A text link in the accent (her red), where `.link` would use the system
/// link blue whatever the accent is. Same look and behaviour otherwise.
struct AccentLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentLinkLabel(configuration: configuration)
    }

    private struct AccentLinkLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(.rect)
                .pointerStyle(.link)
        }
    }
}

extension ButtonStyle where Self == AccentLinkButtonStyle {
    /// `.link`, in the accent colour.
    static var accentLink: AccentLinkButtonStyle { AccentLinkButtonStyle() }
}

extension NSColor {
    /// A colour that follows light and dark appearance.
    static func lidia(light: UInt32, dark: UInt32, name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
