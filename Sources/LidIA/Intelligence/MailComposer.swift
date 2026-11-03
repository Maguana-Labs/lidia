import AppKit
import Foundation

/// Opens a draft in the user's mail app. Nothing is sent: the user reviews
/// and sends it there. Falls back to the clipboard when no mail app takes it.
@MainActor
enum MailComposer {
    @discardableResult
    static func open(to recipients: [String], subject: String, body: String) -> Bool {
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.recipients = recipients
            service.subject = subject
            service.perform(withItems: [body])
            return true
        }
        copy(subject: subject, body: body)
        return false
    }

    static func copy(subject: String, body: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Subject: \(subject)\n\n\(body)", forType: .string)
    }
}

extension FollowUpPlanner {
    /// A short email about one action item ("Following up on …").
    static func itemDraft(
        itemTitle: String,
        meeting: MeetingSignals,
        context: ProjectSuggester.Context,
        senderName: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Draft {
        let recipients = externalRecipients(meeting, context: context)
        let others = recipients.isEmpty ? meeting.attendees.filter { !$0.isCurrentUser && $0.email != nil } : recipients
        let firstName = others.first.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name } ?? "there"
        let when = dayPhrase(meeting.date, now: now, calendar: calendar)
        let meetingTitle = meeting.title.trimmingCharacters(in: .whitespaces)
        let body = [
            "Hi \(firstName),",
            "",
            "Following up on one item from \(meetingTitle.isEmpty ? "our meeting" : meetingTitle) \(when):",
            "",
            "- \(itemTitle)",
            "",
            "Could you let me know where this stands?",
            "",
            "Thanks,",
            senderName.split(separator: " ").first.map(String.init) ?? senderName,
        ].joined(separator: "\n")
        return Draft(
            meetingID: meeting.id,
            meetingTitle: meetingTitle,
            meetingDate: meeting.date,
            recipients: others,
            company: AttendeeGrouping.externalCompanies(others).first,
            subject: "Following up: \(itemTitle.prefix(70))",
            body: body,
            reasons: []
        )
    }
}
