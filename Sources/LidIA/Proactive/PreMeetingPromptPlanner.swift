import Foundation

/// Decides when, and how, to prompt the user before a calendar meeting.
///
/// Rules (see revamp analysis, UX issue 11):
/// - At most one pre-meeting prompt per meeting, ever, across Apple and Google.
/// - The lead time comes from the "Minutes Before" reminder setting rather
///   than a hard-coded 5 minutes.
/// - A meeting with a call link gets the floating Join & Record banner;
///   otherwise a single notification with a Record action (and the prep
///   summary when prep is enabled).
enum PreMeetingPromptPlanner {
    struct Config: Equatable, Sendable {
        var notifyUpcoming: Bool
        var notifyMinutes: Int
        var recordPromptEnabled: Bool
        var prepEnabled: Bool
        var prepMinutes: Int

        /// Lead time used when only the record prompt is on.
        static let recordPromptMinutes = 2

        /// How many minutes before the start to prompt, or nil when every prompt is off.
        var leadMinutes: Int? {
            if notifyUpcoming { return max(0, notifyMinutes) }
            if prepEnabled { return max(0, prepMinutes) }
            if recordPromptEnabled { return Self.recordPromptMinutes }
            return nil
        }
    }

    enum Kind: Equatable, Sendable {
        /// The floating Join & Record banner (event has a call link).
        case banner
        /// A single system notification with a Record / Join & Record action.
        case notification
    }

    struct Decision: Equatable, Sendable {
        let event: AgendaEvent
        let kind: Kind
        let includePrep: Bool
        let leadMinutes: Int
    }

    /// A prompt that arrives later than this after the start is pointless.
    static let lateGrace: TimeInterval = 5 * 60

    /// Returns the prompts to fire now. The caller must add each decision's
    /// `event.id` to `alreadyPrompted` so it never fires twice.
    static func due(
        events: [AgendaEvent],
        now: Date,
        config: Config,
        alreadyPrompted: Set<String>,
        isRecording: Bool
    ) -> [Decision] {
        guard let lead = config.leadMinutes, !isRecording else { return [] }
        let window = TimeInterval(lead * 60)

        return UnifiedCalendar.merge(events).compactMap { event in
            guard !event.isAllDay, !alreadyPrompted.contains(event.id) else { return nil }
            let untilStart = event.start.timeIntervalSince(now)
            guard untilStart <= window, untilStart >= -lateGrace else { return nil }

            let kind: Kind = (event.meetingLink != nil && config.notifyUpcoming) ? .banner : .notification
            return Decision(event: event, kind: kind, includePrep: config.prepEnabled, leadMinutes: lead)
        }
    }

    /// Notification body for a `.notification` decision.
    static func notificationBody(for decision: Decision, now: Date, prepSummary: String?) -> String {
        let minutes = Int((decision.event.start.timeIntervalSince(now) / 60).rounded())
        var body: String
        if minutes <= 0 {
            body = "\(decision.event.title) is starting now."
        } else {
            body = "\(decision.event.title) starts in \(minutes) min."
        }
        if decision.includePrep, let prepSummary, !prepSummary.isEmpty {
            body += " " + prepSummary
        }
        return body
    }
}
