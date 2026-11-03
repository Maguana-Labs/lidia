import Foundation

// Small adapters that isolate the meeting page from data other workstreams own.
// Each one documents what it should be replaced with once that data exists.

// MARK: - Ask thread index

/// Remembers which persisted chat thread belongs to which meeting, so the
/// inspector's Ask tab reopens the same conversation.
///
/// Threads themselves live in the shared `ChatThreadStore`; this only maps
/// meeting ID → thread ID. Swap for a `meetingID` field on `ChatThreadModel`
/// if the chat schema ever gains one.
struct MeetingAskThreadIndex {
    private let defaults: UserDefaults
    private static let prefix = "meetingPage.askThread."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func threadID(for meetingID: UUID) -> UUID? {
        defaults.string(forKey: Self.prefix + meetingID.uuidString).flatMap(UUID.init(uuidString:))
    }

    func setThreadID(_ threadID: UUID?, for meetingID: UUID) {
        let key = Self.prefix + meetingID.uuidString
        if let threadID {
            defaults.set(threadID.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Summary provenance

/// Which model wrote a meeting's summary.
///
/// `Meeting` has no field for this yet, so the page records the model when it
/// triggers a regenerate itself. When the pipeline stores provenance on the
/// meeting, read it in `summaryModel(for:)` instead.
struct MeetingProvenanceStore {
    private let defaults: UserDefaults
    private static let prefix = "meetingPage.summaryModel."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func summaryModel(for meetingID: UUID) -> String? {
        let value = defaults.string(forKey: Self.prefix + meetingID.uuidString)
        return value?.isEmpty == false ? value : nil
    }

    func record(model: String, for meetingID: UUID) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: Self.prefix + meetingID.uuidString)
    }

    func clear(for meetingID: UUID) {
        defaults.removeObject(forKey: Self.prefix + meetingID.uuidString)
    }
}

// MARK: - Audio file location

/// Resolves `Meeting.audioFilePath` to a playable file URL.
///
/// Accepts an absolute path, a `file://` URL string, or a path relative to
/// `~/Library/Application Support/LidIA/`. Returns nil when the file is missing.
enum MeetingAudioLocator {
    static func url(for path: String?, fileManager: FileManager = .default) -> URL? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        var candidates: [URL] = []
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            candidates.append(url)
        } else if raw.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: raw))
        } else if raw.hasPrefix("~") {
            candidates.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        } else if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("LidIA", isDirectory: true).appendingPathComponent(raw))
            candidates.append(support.appendingPathComponent(raw))
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

// MARK: - Live audio levels

/// Mic and system input levels shown in the live recording strip (0…1).
///
/// `RecordingSession` only exposes a combined RMS today, so `system` is nil
/// and the strip shows the combined level as "Mic". When capture exposes
/// per-source levels, fill `system` in `LiveAudioLevels.from(session:)`.
struct LiveAudioLevels: Equatable, Sendable {
    var mic: Float
    var system: Float?

    @MainActor
    static func from(session: RecordingSession) -> LiveAudioLevels {
        guard session.isRecording, !session.isPaused else { return LiveAudioLevels(mic: 0, system: nil) }
        return LiveAudioLevels(mic: normalized(session.currentRMS), system: nil)
    }

    /// Maps raw RMS (speech is typically 0.01–0.3) onto a 0…1 meter.
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, max(0, rms * 3))
    }
}
