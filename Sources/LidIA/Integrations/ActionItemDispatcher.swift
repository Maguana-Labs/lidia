import Foundation
import SwiftData

enum DispatchError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let name): "\(name) is not configured. Check Settings → Integrations."
        }
    }
}

@MainActor
enum ActionItemDispatcher {
    static func dispatch(
        item: ActionItem,
        meetingTitle: String,
        destination: String,
        settings: AppSettings,
        eventKitManager: EventKitManager,
        modelContext: ModelContext,
        titleOverride: String? = nil,
        note: String? = nil
    ) async throws {
        let title = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? item.title
        switch destination {
        case "notion":
            _ = try await ActionItemNotionSyncService.sync(
                targets: [ActionItemNotionSyncService.SyncTarget(item: item, meetingTitle: meetingTitle)],
                settings: settings,
                modelContext: modelContext
            )

        case "reminder":
            let reminderID = await eventKitManager.syncReminder(
                reminderID: item.reminderID,
                title: title,
                deadlineText: item.displayDeadline,
                deadlineDate: item.deadlineDate,
                isCompleted: item.isCompleted
            )
            item.reminderID = reminderID

        case "n8n":
            try PrivacyGate.check(.n8n)
            guard settings.n8nEnabled, !settings.n8nWebhookURL.isEmpty else {
                throw DispatchError.notConfigured("n8n")
            }
            let payload = N8nClient.WebhookPayload(
                meetingTitle: meetingTitle,
                date: ISO8601DateFormatter().string(from: .now),
                duration: 0,
                summary: "",
                actionItems: [N8nClient.ActionItemPayload(
                    title: title,
                    assignee: item.assignee,
                    deadline: item.displayDeadline
                )],
                attendees: [],
                transcript: ""
            )
            await N8nClient.sendWebhook(
                payload: payload,
                webhookURL: settings.n8nWebhookURL,
                authHeader: settings.n8nAuthHeader
            )

        case "clickup":
            try PrivacyGate.check(.clickUp)
            guard !settings.clickUpAPIKey.isEmpty, !settings.clickUpListID.isEmpty else {
                throw DispatchError.notConfigured("ClickUp")
            }
            var description = "From meeting: \(meetingTitle)\nAssignee: \(item.assignee ?? "Unassigned")\nDeadline: \(item.displayDeadline ?? "None")"
            if let note, !note.isEmpty { description = note + "\n\n" + description }
            try await ClickUpClient.createTask(
                title: title,
                description: description,
                listID: settings.clickUpListID,
                apiKey: settings.clickUpAPIKey
            )

        case "linear":
            try PrivacyGate.check(.linear)
            guard !settings.linearAPIKey.isEmpty, !settings.linearTeamID.isEmpty else {
                throw DispatchError.notConfigured("Linear")
            }
            var description = "From meeting: \(meetingTitle)\nAssignee: \(item.assignee ?? "Unassigned")\nDeadline: \(item.displayDeadline ?? "None")"
            if let note, !note.isEmpty { description = note + "\n\n" + description }
            try await LinearClient.createIssue(
                title: title,
                description: description,
                teamID: settings.linearTeamID,
                apiKey: settings.linearAPIKey
            )

        default:
            break
        }
        DispatchHistory.record(destination)
    }
}

/// Where the user has sent action items before, most recent last, so
/// intents can rank destinations by habit. Kept in user defaults (a list
/// of destination identifiers, capped), never meeting content.
enum DispatchHistory {
    static let key = "actionItemDispatchHistory"
    static let limit = 50

    static func record(_ destination: String, defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: key) ?? []
        list.append(destination)
        defaults.set(Array(list.suffix(limit)), forKey: key)
    }

    /// Destination → how many of the recent dispatches went there.
    static func counts(defaults: UserDefaults = .standard) -> [String: Int] {
        (defaults.stringArray(forKey: key) ?? []).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
