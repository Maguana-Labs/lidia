import AppIntents
import LidIAAppIntents
import LidIAKit
import SwiftUI

/// Onscreen context for Siri and Apple Intelligence: the meeting page and
/// action item rows say which entity they show, so "summarize this" and
/// "what did they ask me to do here?" resolve to the visible meeting or item.
extension View {
    /// The meeting page: the view's entity, and a user activity naming it.
    func siriOnscreen(meeting: Meeting) -> some View {
        let identifier = EntityIdentifier(for: MeetingEntity.self, identifier: meeting.id)
        return self
            .siriEntity(identifier)
            .userActivity(SiriActivity.viewMeeting) { activity in
                activity.title = meeting.title.isEmpty ? "Meeting" : meeting.title
                activity.appEntityIdentifier = identifier
                activity.isEligibleForHandoff = false
                activity.isEligibleForPublicIndexing = false
            }
    }

    /// An action item card or row.
    func siriOnscreen(item: ActionItem) -> some View {
        siriEntity(EntityIdentifier(for: ActionItemEntity.self, identifier: item.id))
    }

    /// SwiftUI's `appEntityIdentifier(_:)` view modifier is new in the 27 SDKs
    /// (Swift 6.4); older Xcodes (CI runs 26.x) build without the view half,
    /// and the user activity still names the entity.
    @ViewBuilder
    func siriEntity(_ identifier: EntityIdentifier) -> some View {
        #if compiler(>=6.4)
        appEntityIdentifier(identifier)
        #else
        self
        #endif
    }
}

enum SiriActivity {
    /// Declared in Info.plist (`NSUserActivityTypes`).
    static let viewMeeting = "io.lidia.app.view-meeting"
}

/// Behavioural cues: the app's own actions, donated as the intents Siri would
/// run for them (`SiriDonations` skips content-bearing ones when Siri may not
/// read meeting content).
@MainActor
enum SiriCues {
    static func asked(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SiriDonations.donate(AskLidIAIntent(question: trimmed), carriesContent: true)
    }

    static func draftedFollowUp(meetingID: UUID) {
        guard let context = MacSiriHost.shared?.context, let meeting = SiriStore.meeting(meetingID, in: context) else { return }
        SiriDonations.donate(DraftFollowUpIntent(meeting: MeetingEntity(record: SiriStore.record(meeting, includeSearchText: false))))
    }

    static func preparedNextStep(_ item: ActionItem) {
        SiriDonations.donate(PrepareNextStepIntent(item: ActionItemEntity.make(item)))
    }
}
