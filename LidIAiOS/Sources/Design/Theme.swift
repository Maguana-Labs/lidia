import LidIAKit
import SwiftUI
import UIKit

/// LidIA's palette: her red, ink and warm ivory (`LidIABrand` in LidIAKit holds
/// the hex values and why). Red only where it matters: record and live, the
/// accent, the hero, AI moments. Everything else stays neutral. Errors stay
/// system red with an icon and words, never `Brand.red`.
enum Brand {
    typealias Hex = LidIABrand.Hex

    /// Her red, the one red: record, live and the accent (the `AccentColor`
    /// asset holds the same two values). Deeper in light, brighter in dark.
    static let red = Color(uiColor: .lidia(light: Hex.red, dark: Hex.redDark))
    /// The deep end of the icon's glass.
    static let crimson = Color(hex: Hex.crimson)
    /// The glass highlight.
    static let coral = Color(hex: Hex.coral)
    /// A soft wash of red, decorative only.
    static let rose = Color(hex: Hex.rose)
    static let ink = Color(hex: Hex.ink)
    /// Warm ivory paper, and text on red surfaces.
    static let ivory = Color(hex: Hex.ivory)

    /// Warm companions for kinds of suggestions; AA as text in both appearances.
    static let ember = Color(uiColor: .lidia(light: Hex.ember, dark: Hex.emberDark))
    static let amber = Color(uiColor: .lidia(light: Hex.amber, dark: Hex.amberDark))

    /// The recording red: her red.
    static let record = red

    /// The hero field: the icon's glass, crimson into her red.
    static let field = LinearGradient(
        stops: [
            .init(color: crimson, location: 0),
            .init(color: Color(hex: Hex.red), location: 0.6),
            .init(color: Color(hex: 0xD62536), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The waveform "mark" on red: rose and coral catching the light, into ivory.
    static let mark = LinearGradient(colors: [rose, coral, ivory], startPoint: .leading, endPoint: .trailing)

    /// The mark on paper (sparkles on light or dark surfaces): her red into coral.
    static let markOnPaper = LinearGradient(colors: [red, coral], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Dark, immersive background for the live recording view: deep crimson into ink.
    static let night = LinearGradient(
        colors: [Color(hex: 0x4A0A16), Color(hex: 0x2A0A10), Color(hex: Hex.ink)],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum Metrics {
    static let gutter: CGFloat = 16
    static let cardRadius: CGFloat = 24
    static let tileRadius: CGFloat = 20
    static let rowIcon: CGFloat = 42
    static let sectionSpacing: CGFloat = 28
}

/// Surfaces: a calm grouped background with white (or elevated dark) cards.
enum Surface {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let inset = Color(uiColor: .tertiarySystemGroupedBackground)
    static let hairline = Color(uiColor: .separator)
}

extension UIColor {
    /// A colour that follows light and dark appearance.
    static func lidia(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Stable tints for meetings, projects and people: warm, muted hues that sit
/// beside her red without clashing (white initials pass AA on each).
enum Tint {
    static let palette: [Color] = LidIABrand.Hex.avatars.map { Color(hex: $0) }

    static func color(for key: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in key.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Formatting

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "Today", "Yesterday", "Monday", "3 Nov".
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           abs(days) < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// `day` for use mid-sentence: "today", "yesterday", "Sunday", "27 Oct".
    static func dayInSentence(_ date: Date) -> String {
        let value = day(date)
        return ["Today", "Yesterday", "Tomorrow"].contains(value) ? value.lowercased() : value
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "in 12 min", "in 2 h", "now".
    static func countdown(to date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Int((seconds / 3600).rounded(.down))
        let rest = minutes - hours * 60
        return rest < 5 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    static func initials(_ name: String) -> String {
        let parts = name
            .replacingOccurrences(of: "@", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
            .prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }
        return letters.joined().isEmpty ? "?" : letters.joined()
    }

    /// "ana@acme.com" → "Ana"; "Ana Ruiz" stays.
    static func displayName(_ raw: String) -> String {
        guard raw.contains("@") else { return raw }
        let local = raw.split(separator: "@").first.map(String.init) ?? raw
        return local
            .split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
