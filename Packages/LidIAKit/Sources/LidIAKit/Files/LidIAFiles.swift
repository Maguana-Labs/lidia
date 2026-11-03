import Foundation

/// Where LidIA keeps its user-editable files (SOUL.md and MEMORY.md).
///
/// Shared by the macOS app, the iOS app and sync so they all read and write
/// the same place. On macOS this is `~/.lidia`; on iOS and watchOS
/// `NSHomeDirectory()` is the app's container, so it is `.lidia` inside it.
public enum LidIAFiles {
    /// Base directory for LidIA config files.
    public static let lidiaDir: String = NSHomeDirectory() + "/.lidia"

    /// Path to SOUL.md: user-edited personality and instructions.
    public static let soulFilePath: String = lidiaDir + "/SOUL.md"

    /// Path to MEMORY.md: assistant-written long-term memory.
    public static let memoryFilePath: String = lidiaDir + "/MEMORY.md"
}
