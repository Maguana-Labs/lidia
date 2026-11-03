import AppKit
import Foundation
import SwiftData

/// Runs a prepared intent. Only the confirmation sheet calls `perform`,
/// after the user pressed its button: this is the one place an intent
/// sends, creates or changes anything.
@MainActor
enum IntentActions {
    enum Outcome: Equatable {
        case done(String)
        /// Opened a draft in another app; the user sends it there.
        case handedOff(String)
    }

    struct Edited: Equatable {
        var destinationID: String
        var subject: String
        var body: String
        var slot: ActionIntent.Slot?
    }

    static func integrationKind(for destinationID: String) -> IntegrationKind? {
        switch destinationID {
        case "linear": .linear
        case "clickup": .clickUp
        case "notion": .notion
        case "slack": .slack
        case "n8n": .n8n
        default: nil
        }
    }

    /// Opens Settings at the integration the intent needs.
    static func connect(_ destination: ActionIntent.Destination) {
        guard let kind = integrationKind(for: destination.id) else { return }
        SettingsRouter.shared.open(.apps, subpage: .integration(kind))
    }

    /// Whether Local-only mode blocks this destination (drafts that open
    /// locally, Reminders and Calendar never are).
    nonisolated static func isBlockedByLocalOnly(_ destinationID: String, localOnly: Bool) -> Bool {
        localOnly && ["slack", "linear", "clickup", "notion", "n8n", "gmail"].contains(destinationID)
    }

    static func perform(
        _ intent: ActionIntent,
        edited: Edited,
        item: ActionItem,
        meetingTitle: String,
        settings: AppSettings,
        eventKitManager: EventKitManager,
        calendar: (any IntentCalendarSource)?,
        modelContext: ModelContext
    ) async throws -> Outcome {
        var emails = intent.recipients.compactMap(\.email)
        if case .calendarChange(let proposal) = intent.artifact { emails = proposal.attendees.compactMap(\.email) }
        switch edited.destinationID {
        case "gmail":
            guard let url = gmailComposeURL(to: emails, subject: edited.subject, body: edited.body) else { throw URLError(.badURL) }
            NSWorkspace.shared.open(url)
            DispatchHistory.record("gmail")
            return .handedOff("Opened in Gmail. Send it from there.")
        case "mail":
            if MailComposer.open(to: emails, subject: edited.subject, body: edited.body) {
                DispatchHistory.record("mail")
                return .handedOff("Opened in your mail app. Send it from there.")
            }
            if let url = mailtoURL(to: emails, subject: edited.subject, body: edited.body), NSWorkspace.shared.open(url) {
                return .handedOff("Opened in your mail app. Send it from there.")
            }
            return .handedOff("Copied the draft: no mail app took it.")
        case "slack":
            try await SlackClient.postText(edited.body, channel: settings.slackChannel, botToken: settings.slackBotToken)
            DispatchHistory.record("slack")
            item.confirmedDestination = "slack"
            return .done("Posted to \(settings.slackChannel).")
        case "notion" where intent.kind == .document || intent.kind == .research:
            try PrivacyGate.check(.notion)
            guard !settings.notionAPIKey.isEmpty, !settings.notionDatabaseID.isEmpty else { throw DispatchError.notConfigured("Notion") }
            _ = try await NotionClient(apiKey: settings.notionAPIKey).createMeetingPage(
                databaseID: settings.notionDatabaseID, title: edited.subject, date: .now, duration: 0, bodyMarkdown: edited.body
            )
            DispatchHistory.record("notion")
            item.confirmedDestination = "notion"
            return .done("Created the Notion page.")
        case "calendar":
            guard let slot = edited.slot, case .calendarChange(let proposal) = intent.artifact, let eventID = proposal.eventID else {
                throw DispatchError.notConfigured("This calendar change")
            }
            guard let calendar else { throw DispatchError.notConfigured("Calendar access") }
            try calendar.move(eventID: eventID, to: slot.start, end: slot.end)
            return .done("Moved “\(proposal.eventTitle)” to \(slot.start.formatted(.dateTime.weekday(.wide).hour().minute())).")
        case "calendarApp":
            if case .calendarChange(let proposal) = intent.artifact, proposal.source == "google" {
                NSWorkspace.shared.open(URL(string: "https://calendar.google.com/calendar/r/week")!)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            }
            return .handedOff("Opened your calendar.")
        default:
            // Trackers and Reminders share the dispatcher (and its PrivacyGate checks).
            try await ActionItemDispatcher.dispatch(
                item: item, meetingTitle: meetingTitle, destination: edited.destinationID,
                settings: settings, eventKitManager: eventKitManager, modelContext: modelContext,
                titleOverride: edited.subject, note: edited.body
            )
            item.confirmedDestination = edited.destinationID
            try? modelContext.save()
            return .done("Sent to \(intent.destinations.first { $0.id == edited.destinationID }?.name ?? edited.destinationID).")
        }
    }

    /// Gmail's web compose, opened in the user's browser.
    static func gmailComposeURL(to: [String], subject: String, body: String) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/")
        components?.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: to.joined(separator: ",")),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    static func mailtoURL(to: [String], subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }

    /// A short note to attendees after a move, for the user to send.
    static func attendeeNote(for proposal: ActionIntent.CalendarProposal, slot: ActionIntent.Slot, sender: String) -> (subject: String, body: String) {
        let when = slot.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
        let body = [
            "Hi all,", "",
            "I've moved “\(proposal.eventTitle)” to \(when). Let me know if that doesn't work for you.", "",
            "Thanks,", sender.split(separator: " ").first.map(String.init) ?? sender,
        ].joined(separator: "\n")
        return ("Moved: \(proposal.eventTitle)", body)
    }

    /// The editable text an intent starts with.
    /// An email proposing the free times to the people on the event.
    static func proposeTimesNote(for proposal: ActionIntent.CalendarProposal, sender: String) -> (subject: String, body: String) {
        let first = sender.split(separator: " ").first.map(String.init) ?? sender
        var lines = ["Hi,", "", "Could we move “\(proposal.eventTitle)”\(proposal.currentStart.map { " (\($0.formatted(.dateTime.weekday(.wide).hour().minute())))" } ?? "")? I'm free:", ""]
        lines += proposal.slots.map { "- \($0.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))–\($0.end.formatted(.dateTime.hour().minute()))" }
        lines += ["", "Let me know what works.", "", "Thanks,", first]
        return ("New time for \(proposal.eventTitle)?", lines.joined(separator: "\n"))
    }

    static func initialEdit(for intent: ActionIntent, destinationID: String? = nil, sender: String = "") -> Edited {
        let destination = destinationID ?? intent.primaryDestination?.id ?? "reminder"
        switch intent.artifact {
        case .message(let subject, let body), .document(let subject, let body), .ticket(let subject, let body):
            return Edited(destinationID: destination, subject: subject, body: body, slot: nil)
        case .reminder(let title, let notes):
            return Edited(destinationID: destination, subject: title, body: notes ?? "", slot: nil)
        case .research(let notes):
            return Edited(destinationID: destination, subject: intent.suggestedTitle ?? "Research", body: notes, slot: nil)
        case .calendarChange(let proposal):
            if ["gmail", "mail"].contains(destination) {
                let note = proposeTimesNote(for: proposal, sender: sender)
                return Edited(destinationID: destination, subject: note.subject, body: note.body, slot: proposal.slots.first)
            }
            return Edited(destinationID: destination, subject: proposal.eventTitle, body: "", slot: proposal.slots.first)
        case .none:
            return Edited(destinationID: destination, subject: intent.suggestedTitle ?? "", body: "", slot: nil)
        }
    }
}
