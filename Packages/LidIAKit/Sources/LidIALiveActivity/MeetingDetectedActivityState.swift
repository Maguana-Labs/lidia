import Foundation

/// "Zoom call started": the short-lived prompt shown when a meeting app starts using the
/// microphone. Shaped like an ActivityKit `ContentState` so it can later back a real
/// Live Activity. It ends on its own after `lifetime`, or when the app releases the mic.
public struct MeetingDetectedActivityState: Codable, Hashable, Sendable {
    /// The meeting, as the detector names it ("Zoom", "Google Meet").
    public var meetingName: String
    /// The app "Never for …" applies to (the browser for a web meeting).
    public var appName: String
    public var bundleID: String
    /// The calendar meeting on now, if any.
    public var calendarTitle: String?
    public var detectedAt: Date
    public var endsAt: Date

    /// How long the prompt stays up if nobody answers.
    public static let lifetime: TimeInterval = 120

    public init(
        meetingName: String,
        appName: String,
        bundleID: String,
        calendarTitle: String? = nil,
        detectedAt: Date,
        lifetime: TimeInterval = MeetingDetectedActivityState.lifetime
    ) {
        self.meetingName = meetingName
        self.appName = appName
        self.bundleID = bundleID
        let title = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.calendarTitle = (title?.isEmpty ?? true) ? nil : title
        self.detectedAt = detectedAt
        self.endsAt = detectedAt.addingTimeInterval(lifetime)
    }

    /// "Zoom call started".
    public var headline: String { "\(meetingName) call started" }

    /// The calendar meeting, else what Record does.
    public var subtitle: String { calendarTitle ?? "Record it and take notes?" }

    /// "Never for Google Chrome".
    public var neverTitle: String { "Never for \(appName)" }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    public func isExpired(at now: Date) -> Bool {
        now >= endsAt
    }
}
