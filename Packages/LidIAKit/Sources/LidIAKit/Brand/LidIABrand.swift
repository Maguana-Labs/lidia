import Foundation

/// LidIA is named for Lidia Mariana, the founder's late mother. Her favourite
/// colour was red, so the brand is her red with ink and warm ivory.
///
/// The raw palette, shared by the Mac, iPhone and Live Activity so every
/// platform draws the same red. Each app turns these into its own `Brand`
/// colour tokens (`Sources/LidIA/Views/Shared/Brand.swift`,
/// `LidIAiOS/Sources/Design/Theme.swift`).
///
/// "Paper" balance: red only where it matters (record and live, the accent,
/// the hero, AI and brand moments); everything else stays neutral. Errors use
/// the system red with an icon and wording, never her red.
public enum LidIABrand {
    /// The line shown in About on the Mac and the iPhone.
    /// The owner may want different wording: change it here, nowhere else.
    public static let dedication = "Named for Lidia Mariana, who loved red."

    /// sRGB hex values (0xRRGGBB), sampled from the app icon's glass.
    public enum Hex {
        /// Her red, in light appearance: record, live, the accent.
        /// White or ivory text on it: 5.9:1 / 5.5:1. On white or ivory: 5.9:1 / 5.5:1.
        public static let red: UInt32 = 0xC8102E
        /// Her red in dark appearance: brighter so it reads on dark surfaces
        /// (4.7:1 on #1C1C1E) while white on it stays 3.6:1 (bold labels, glyphs).
        public static let redDark: UInt32 = 0xF2475C
        /// The deep end of the glass: hero gradients, live backgrounds.
        public static let crimson: UInt32 = 0x8E0E22
        /// The glass highlight: glows, waves.
        public static let coral: UInt32 = 0xFF5A4E
        /// A soft wash of her red: decorative tints only, never text.
        public static let rose: UInt32 = 0xF7C1C1
        /// Ink: text and the bottom of the live background.
        public static let ink: UInt32 = 0x1C1C1E
        /// Warm ivory paper: the icon's background, text on red.
        public static let ivory: UInt32 = 0xFDF7EB

        /// Warm companions to her red, for kinds of suggestions
        /// (each passes AA as text on white and on #1C1C1E).
        public static let ember: UInt32 = 0xB4462A
        public static let emberDark: UInt32 = 0xFF8A65
        public static let amber: UInt32 = 0x96600F
        public static let amberDark: UInt32 = 0xF5B547
        public static let berry: UInt32 = 0x9B2C5A
        public static let berryDark: UInt32 = 0xF27BA8

        /// People and projects: warm, muted, distinct hues that sit beside her
        /// red without clashing. White initials pass AA on each.
        public static let avatars: [UInt32] = [
            0xB5523B, // terracotta
            0x9A6A1E, // ochre
            0x5E7F5A, // sage
            0xA4485E, // dusty rose
            0x7A4E78, // plum
            0x4F6F8A, // slate
            0x5C5A8A, // dusk
            0x3F7A74, // muted teal
        ]
    }
}
