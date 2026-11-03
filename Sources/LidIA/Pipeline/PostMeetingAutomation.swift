import Foundation
import os
import SwiftData
import UserNotifications

@MainActor
struct PostMeetingAutomation {
    nonisolated private static let logger = Logger(subsystem: "io.lidia.app", category: "PostMeetingAutomation")
    static func run(
        meeting: Meeting,
        modelContext: ModelContext,
        settings: AppSettings,
        eventKitManager: EventKitManager?,
        modelManager: ModelManager? = nil
    ) async {
        // Snapshot values needed by concurrent tasks before leaving MainActor
        let shouldSendNotion = !settings.localOnlyMode && settings.notionAutoSend && !settings.notionAPIKey.isEmpty && !settings.notionDatabaseID.isEmpty
        let notionAPIKey = settings.notionAPIKey
        let notionDatabaseID = settings.notionDatabaseID
        let meetingTitle = meeting.title
        let meetingDate = meeting.date
        let meetingDuration = meeting.duration
        let meetingSummary = meeting.summary
        let actionItemSnapshot = meeting.actionItems.map { (title: $0.title, assignee: $0.assignee, deadline: $0.displayDeadline, priority: $0.priority, suggestedDestination: $0.suggestedDestination) }
        let shouldSendReminders = eventKitManager != nil && settings.remindersAutoSend && settings.remindersEnabled
        let shouldSendN8n = !settings.localOnlyMode && settings.n8nEnabled && settings.n8nAutoSend && !settings.n8nWebhookURL.isEmpty
        let calendarAttendees = meeting.calendarAttendees ?? []
        let meetingTranscript = MeetingContextRetrievalService.effectiveTranscript(for: meeting)
        let meetingNotes = meeting.notes
        let meetingTemplateName: String? = meeting.templateID.flatMap { tid in settings.meetingTemplates.first { $0.id == tid }?.name }
        let n8nWebhookURL = settings.n8nWebhookURL
        let n8nAuthHeader = settings.n8nAuthHeader.isEmpty ? nil : settings.n8nAuthHeader
        let notionSendSummary = settings.notionSendSummary
        let notionSendActionItems = settings.notionSendActionItems
        let n8nSendSummary = settings.n8nSendSummary
        let n8nSendActionItems = settings.n8nSendActionItems
        let n8nSendAttendees = settings.n8nSendAttendees
        let n8nSendTranscript = settings.n8nSendTranscript
        let remindersMyItemsOnly = settings.remindersMyItemsOnly
        let displayName = settings.displayName
        let shouldSendSlack = !settings.localOnlyMode && settings.slackEnabled && settings.slackAutoSend && !settings.slackBotToken.isEmpty && !settings.slackChannel.isEmpty
        let slackBotToken = settings.slackBotToken
        let slackChannel = settings.slackChannel
        let slackSendSummary = settings.slackSendSummary
        let slackSendActionItems = settings.slackSendActionItems
        let slackSendAttendees = settings.slackSendAttendees

        // --- Run independent integrations concurrently ---

        // Notion (network call via actor, returns page ID)
        async let notionResult: String? = {
            guard shouldSendNotion else { return nil }
            do {
                let notion = NotionClient(apiKey: notionAPIKey)
                var bodyParts: [String] = []
                if notionSendSummary {
                    bodyParts.append("""
                    ## Summary
                    \(meetingSummary)
                    """)
                }
                if notionSendActionItems {
                    bodyParts.append("""
                    ## Action Items
                    \(actionItemSnapshot.map {
                        var line = "- \($0.title)"
                        if let deadline = $0.deadline {
                            line += " (due: \(deadline))"
                        }
                        return line
                    }.joined(separator: "\n"))
                    """)
                }
                let body = bodyParts.joined(separator: "\n\n")
                return try await notion.createMeetingPage(
                    databaseID: notionDatabaseID,
                    title: meetingTitle,
                    date: meetingDate,
                    duration: meetingDuration,
                    bodyMarkdown: body
                )
            } catch {
                logger.error("Notion sync failed: \(error)")
                return nil
            }
        }()

        // Build attendee context on MainActor before entering async closure
        let attendeeContexts: [N8nClient.AttendeeContext] = {
            guard shouldSendN8n, n8nSendAttendees else { return [] }
            let descriptor = FetchDescriptor<Meeting>()
            let allMeetings = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.status == .complete }
            return calendarAttendees.map { attendee in
                let pastMeetings = allMeetings.filter { m in
                    m.calendarAttendees?.contains(where: { $0.localizedCaseInsensitiveCompare(attendee) == .orderedSame }) == true
                }
                let allItems = pastMeetings.flatMap(\.actionItems)
                let openItems = allItems.filter { !$0.isCompleted }
                let overdueItems = openItems.filter { $0.deadlineDate != nil && $0.deadlineDate! < Date() }
                return N8nClient.AttendeeContext(
                    email: attendee,
                    openActionItems: openItems.count,
                    overdueActionItems: overdueItems.count,
                    lastMeetingDate: pastMeetings.sorted(by: { $0.date > $1.date }).first.map { ISO8601DateFormatter().string(from: $0.date) },
                    totalMeetings: pastMeetings.count
                )
            }
        }()

        // n8n webhook (fire-and-forget via actor) — enriched payload with attendee context
        async let n8nDone: Void = {
            guard shouldSendN8n else { return }
            let payload = N8nClient.WebhookPayload(
                meetingTitle: meetingTitle,
                date: ISO8601DateFormatter().string(from: meetingDate),
                duration: meetingDuration,
                summary: n8nSendSummary ? meetingSummary : "",
                actionItems: n8nSendActionItems ? actionItemSnapshot.map {
                    N8nClient.ActionItemPayload(
                        title: $0.title,
                        assignee: $0.assignee,
                        deadline: $0.deadline,
                        priority: $0.priority,
                        suggestedDestination: $0.suggestedDestination
                    )
                } : [],
                attendees: n8nSendAttendees ? calendarAttendees : [],
                transcript: n8nSendTranscript ? meetingTranscript : "",
                notes: meetingNotes,
                meetingType: meetingTemplateName,
                attendeeContext: attendeeContexts
            )
            await N8nClient.sendWebhook(
                payload: payload,
                webhookURL: n8nWebhookURL,
                authHeader: n8nAuthHeader
            )
        }()

        // Slack (fire-and-forget via actor)
        async let slackDone: Void = {
            guard shouldSendSlack else { return }
            let message = SlackClient.SlackMessage(
                channel: slackChannel,
                meetingTitle: meetingTitle,
                date: meetingDate,
                duration: meetingDuration,
                summary: slackSendSummary ? meetingSummary : nil,
                actionItems: slackSendActionItems ? actionItemSnapshot.map {
                    (title: $0.title, assignee: $0.assignee, deadline: $0.deadline)
                } : [],
                attendees: slackSendAttendees ? calendarAttendees : nil
            )
            await SlackClient.postMeetingSummary(message: message, botToken: slackBotToken)
        }()

        // Await concurrent network integrations
        let meetingID = meeting.id
        let home = meeting.modelContext ?? modelContext
        let pageID = await notionResult
        await n8nDone
        await slackDone
        // The meeting can be deleted while the integrations run.
        guard LiveModel.meetingExists(meetingID, in: home) else { return }

        // Apple Reminders — runs on MainActor (mutates SwiftData model)
        if shouldSendReminders, let ekManager = eventKitManager {
            let itemsToCreate = remindersMyItemsOnly
                ? meeting.actionItems.filter { item in
                    let assignee = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return assignee.isEmpty || assignee.localizedCaseInsensitiveCompare(displayName) == .orderedSame
                }
                : meeting.actionItems
            let reminders = itemsToCreate.map { (id: $0.id, title: $0.title, deadline: $0.displayDeadline) }
            for reminder in reminders {
                if let reminderID = await ekManager.createReminder(
                    title: reminder.title,
                    deadline: reminder.deadline
                ), let actionItem = LiveModel.actionItem(reminder.id, in: home) {
                    actionItem.reminderID = reminderID
                }
            }
            guard LiveModel.meetingExists(meetingID, in: home) else { return }
        }

        // Apply results back to model (MainActor)
        if let pageID {
            meeting.notionPageID = pageID
        }
        if shouldSendNotion || shouldSendReminders {
            try? modelContext.save()
        }

        // Mark talking points as used
        if let attendees = meeting.calendarAttendees {
            let descriptor = FetchDescriptor<TalkingPoint>()
            if let talkingPoints = try? modelContext.fetch(descriptor) {
                for tp in talkingPoints where !tp.isUsed {
                    if attendees.contains(where: { $0.lowercased() == tp.personIdentifier.lowercased() }) {
                        tp.isUsed = true
                    }
                }
                try? modelContext.save()
            }
        }

        // Index in Spotlight
        SpotlightIndexer.indexMeeting(meeting)

        // Markdown vault export
        if settings.vaultExportEnabled {
            do {
                try VaultExporter.export(meeting: meeting, settings: settings)
            } catch {
                logger.error("Vault export failed: \(error.localizedDescription)")
            }
        }

        // Autopilot: auto-dispatch action items with confirmed or suggested destinations
        if settings.autopilotEnabled {
            var autopilotChanged = false
            for item in meeting.actionItems {
                if let destination = item.confirmedDestination ?? item.suggestedDestination {
                    // Mark suggested destinations as confirmed so they are not sent again
                    if item.confirmedDestination == nil {
                        item.confirmedDestination = destination
                        autopilotChanged = true
                    }
                }
            }
            if autopilotChanged {
                try? modelContext.save()
            }
        }

        // Send completion notification
        sendCompletionNotification(meeting: meeting)

        // Create InboxNotification for processed meeting
        let processedNotif = InboxNotification(
            type: "processed",
            title: "Meeting processed",
            body: "\(meeting.title) — \(meeting.actionItems.count) action item\(meeting.actionItems.count == 1 ? "" : "s")",
            meetingID: meeting.id
        )
        modelContext.insert(processedNotif)

        // Create inbox reminders for action items with due dates
        for item in meeting.actionItems where item.deadlineDate != nil {
            let reminder = InboxNotification(
                type: "reminder",
                title: "Action item due",
                body: item.title,
                meetingID: meeting.id
            )
            modelContext.insert(reminder)
        }
        try? modelContext.save()

        // Next steps: each open item gets one prepared intent (who it's for, where
        // it goes, a draft). They replace the per-item nudge cards, so an item
        // never shows twice on Today, and a ticket goes to a tracker, not to you.
        let openCount = meeting.actionItems.filter { !$0.isCompleted }.count
        if openCount > 0, let eventKitManager {
            IntentEngine.shared.scheduleRefresh(meetingIDs: [meeting.id], environment: .init(
                settings: settings,
                modelManager: modelManager,
                calendar: LiveIntentCalendar(eventKit: eventKitManager, google: nil, hidden: settings.hiddenCalendarIDs),
                modelContext: modelContext,
                useModel: IntentRuntime.modelDraftsAllowed
            ))
            sendNudgeNotification(
                title: "Next steps from \(meeting.title)",
                body: "\(openCount) \(openCount == 1 ? "step is" : "steps are") prepared on the Action Items board. Nothing is sent until you click.",
                identifier: "lidia.nextsteps.\(meeting.id)"
            )
        }
    }

    private static func sendCompletionNotification(meeting: Meeting) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting Processed"
        let actionCount = meeting.actionItems.count
        content.body = "\(meeting.title) — \(actionCount) action item\(actionCount == 1 ? "" : "s") created"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "lidia.processed.\(meeting.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func sendNudgeNotification(title: String, body: String, identifier: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Delay nudges by 2 minutes so they don't overlap with the "Meeting Processed" notification
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 120, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
