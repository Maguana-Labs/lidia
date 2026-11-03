import Foundation

/// Rules for values that arrive from the sync server.
///
/// The server is trusted to hold meeting content, not to choose local file
/// paths or reach outside the meeting store. Everything that turns a
/// server-supplied string into a file name, a path or an identifier goes
/// through here so the macOS and iOS apps apply the same rules.
public enum SyncSafety {
    /// The only files the server may write, all inside `~/.lidia`.
    public static let syncedFileNames: Set<String> = ["SOUL.md", "MEMORY.md"]

    /// True when `name` is exactly one of the allowlisted synced file names.
    /// Rejects anything else, including `../`, absolute paths and look-alikes.
    public static func isAllowedSyncedFileName(_ name: String) -> Bool {
        syncedFileNames.contains(name)
    }

    /// Parses a server-supplied identifier. Only canonical UUIDs are accepted.
    public static func identifier(_ raw: String?) -> UUID? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 36 else { return nil }
        return UUID(uuidString: trimmed)
    }

    /// Audio paths are local to the device that recorded the meeting, so a path
    /// from the server is never applied. Callers keep their own local value.
    ///
    /// - Parameters:
    ///   - local: the value already stored on this device, if any.
    ///   - remote: the value the server sent (ignored).
    /// - Returns: the value to store.
    public static func audioFilePath(local: String?, remote _: String?) -> String? {
        local
    }

    /// Whether a sync server URL is safe to send the bearer token to.
    ///
    /// HTTPS is always allowed. Plain HTTP is only allowed for hosts that are
    /// on this machine or on a private network (loopback, `.local`, RFC 1918,
    /// and the 100.64.0.0/10 range Tailscale uses), where the token does not
    /// cross the public internet in clear text.
    public static func isAllowedServerURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        guard url.user == nil, url.password == nil else { return false }
        switch scheme {
        case "https":
            return true
        case "http":
            return isPrivateHost(host)
        default:
            return false
        }
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _): return true
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}
