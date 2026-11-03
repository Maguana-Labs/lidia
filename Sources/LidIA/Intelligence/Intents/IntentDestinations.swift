import AppKit
import Foundation

/// What the user has connected, and where they've sent things before.
/// Intents rank destinations from this, so a Notion-and-Linear user gets
/// Notion pages and Linear issues, not Apple Reminders.
struct IntentConnections: Sendable, Equatable {
    enum MailHandler: Sendable, Equatable {
        /// mailto: opens a browser: Gmail on the web.
        case gmail
        case appleMail
        case app(String)
        case none
    }

    var slack = false
    var slackChannel = ""
    var notionPages = false
    var notionTasks = false
    var clickUp = false
    var linear = false
    var n8n = false
    var mail: MailHandler = .appleMail
    /// Destination identifier → recent dispatches there.
    var history: [String: Int] = [:]
    var localOnly = false

    @MainActor
    static func current(settings: AppSettings) -> IntentConnections {
        IntentConnections(
            slack: settings.slackEnabled && !settings.slackBotToken.isEmpty && !settings.slackChannel.isEmpty,
            slackChannel: settings.slackChannel,
            notionPages: !settings.notionAPIKey.isEmpty && !settings.notionDatabaseID.isEmpty,
            notionTasks: !settings.notionAPIKey.isEmpty && !settings.notionTasksDatabaseID.isEmpty,
            clickUp: !settings.clickUpAPIKey.isEmpty && !settings.clickUpListID.isEmpty,
            linear: !settings.linearAPIKey.isEmpty && !settings.linearTeamID.isEmpty,
            n8n: settings.n8nEnabled && !settings.n8nWebhookURL.isEmpty,
            mail: detectMailHandler(),
            history: DispatchHistory.counts(),
            localOnly: settings.localOnlyMode
        )
    }

    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// The app that opens mailto: links. A browser there means webmail (Gmail).
    @MainActor
    static func detectMailHandler() -> MailHandler {
        guard let probe = URL(string: "mailto:someone@example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: app) else { return .none }
        let id = bundle.bundleIdentifier ?? ""
        if id == "com.apple.mail" { return .appleMail }
        if browserBundleIDs.contains(id) { return .gmail }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? app.deletingPathExtension().lastPathComponent
        return .app(name)
    }

    /// A stable string for cache fingerprints.
    var fingerprint: String {
        "\(slack)\(notionPages)\(notionTasks)\(clickUp)\(linear)\(n8n)\(mail)\(localOnly)"
    }
}

/// Ranks where an intent's prepared action should go.
enum IntentDestinationRanker {
    static func email(_ connections: IntentConnections) -> ActionIntent.Destination {
        switch connections.mail {
        case .gmail where !connections.localOnly:
            return .init(id: "gmail", name: "Gmail", configured: true, reason: "Gmail · your mail opens in the browser")
        case .app(let name):
            return .init(id: "mail", name: name, configured: true, reason: "\(name) · your mail app")
        default:
            return .init(id: "mail", name: "Mail", configured: true, reason: "Mail · your mail app")
        }
    }

    static func slack(_ connections: IntentConnections) -> ActionIntent.Destination {
        let channel = connections.slackChannel.isEmpty ? "" : " \(connections.slackChannel)"
        return .init(id: "slack", name: "Slack", configured: connections.slack, reason: "Slack · posts to\(channel.isEmpty ? " your channel" : channel)")
    }

    static func usage(_ id: String, _ connections: IntentConnections) -> Int { connections.history[id] ?? 0 }

    static func habitReason(_ name: String, id: String, connections: IntentConnections, fallback: String) -> String {
        let count = usage(id, connections)
        return count > 0 ? "\(name) · you've sent \(count) \(count == 1 ? "item" : "items") there" : "\(name) · \(fallback)"
    }

    static func looksLikeEngineering(_ title: String) -> Bool {
        let words = Set(IntentText.words(title))
        let engineering: Set<String> = ["bug", "fix", "pr", "prs", "deploy", "code", "api", "build", "merge", "terraform", "repo", "test",
                                        "release", "refactor", "pipeline", "infra", "infrastructure", "ecs", "aws", "git", "github", "endpoint"]
        return !words.isDisjoint(with: engineering)
    }

    static func rank(
        kind: ActionIntent.Kind,
        title: String,
        recipientsAreExternal: Bool,
        connections: IntentConnections
    ) -> [ActionIntent.Destination] {
        let reminder = ActionIntent.Destination(id: "reminder", name: "Reminders", configured: true, reason: "Reminders · a personal to-do")
        switch kind {
        case .message:
            let mail = email(connections)
            guard connections.slack else { return [mail] }
            let slack = slack(connections)
            let slackFirst = !recipientsAreExternal || usage("slack", connections) > usage(mail.id, connections) + 2
            return slackFirst ? [slack, mail] : [mail, slack]

        case .document:
            let notion = ActionIntent.Destination(
                id: "notion", name: "Notion", configured: connections.notionPages,
                reason: connections.notionPages ? habitReason("Notion", id: "notion", connections: connections, fallback: "where your meeting notes go") : "Notion · not connected yet"
            )
            let sharing = IntentText.words(title).contains { ["share", "send", "forward", "circulate"].contains($0) }
            if sharing { return [email(connections)] + (connections.notionPages ? [notion] : []) }
            return connections.notionPages ? [notion, email(connections)] : [notion, email(connections), reminder]

        case .ticket:
            var trackers: [ActionIntent.Destination] = []
            if connections.linear { trackers.append(.init(id: "linear", name: "Linear", configured: true, reason: habitReason("Linear", id: "linear", connections: connections, fallback: "your issue tracker"))) }
            if connections.clickUp { trackers.append(.init(id: "clickup", name: "ClickUp", configured: true, reason: habitReason("ClickUp", id: "clickup", connections: connections, fallback: "your task list"))) }
            if connections.notionTasks { trackers.append(.init(id: "notion", name: "Notion", configured: true, reason: habitReason("Notion", id: "notion", connections: connections, fallback: "your tasks database"))) }
            if connections.n8n { trackers.append(.init(id: "n8n", name: "n8n", configured: true, reason: habitReason("n8n", id: "n8n", connections: connections, fallback: "your automation"))) }
            if trackers.isEmpty {
                // Say what's missing instead of quietly using Reminders.
                let engineering = looksLikeEngineering(title)
                let best = ActionIntent.Destination(
                    id: engineering ? "linear" : "clickup", name: engineering ? "Linear" : "ClickUp", configured: false,
                    reason: engineering ? "Linear · connect it to file issues" : "ClickUp · connect it to create tasks"
                )
                return [best, reminder]
            }
            let ranked = trackers.enumerated().sorted { lhs, rhs in
                let l = usage(lhs.element.id, connections), r = usage(rhs.element.id, connections)
                if l != r { return l > r }
                // Engineering work leans to Linear when both are there.
                if looksLikeEngineering(title), lhs.element.id == "linear" || rhs.element.id == "linear" { return lhs.element.id == "linear" }
                return lhs.offset < rhs.offset
            }.map(\.element)
            return ranked + [reminder]

        case .schedule:
            return [.init(id: "calendar", name: "Calendar", configured: true, reason: "Calendar · your events")]

        case .research:
            if connections.notionPages {
                return [.init(id: "notion", name: "Notion", configured: true, reason: habitReason("Notion", id: "notion", connections: connections, fallback: "keeps the notes with your meetings")), reminder]
            }
            return [reminder]

        case .reminder, .unclear:
            return [.init(id: "reminder", name: "Reminders", configured: true, reason: "Reminders · a personal to-do")]
        }
    }

    /// The single button's label.
    static func primaryLabel(
        kind: ActionIntent.Kind,
        direction: ActionIntent.Direction,
        destination: ActionIntent.Destination?,
        recipientLabel: String?,
        proposal: ActionIntent.CalendarProposal? = nil,
        title: String = "",
        calendar: Calendar = .current
    ) -> String {
        guard let destination else { return "Add to Reminders" }
        if !destination.configured { return "Connect \(destination.name)…" }
        let who = recipientLabel ?? "them"
        if direction == .othersOweUser, kind != .schedule {
            return destination.id == "reminder" ? "Remind me to check with \(who)" : "Nudge \(who)"
        }
        switch kind {
        case .message:
            if FollowUpPlanner.isRecapPromise(title) {
                return "Send recap to \(who)" + (destination.id == "slack" ? " on Slack" : "")
            }
            return destination.id == "slack" ? "Message \(who) on Slack" : "Email \(who)"
        case .document:
            switch destination.id {
            case "notion": return "Create Notion page"
            case "reminder": return "Add to Reminders"
            default: return "Share with \(who)"
            }
        case .ticket:
            switch destination.id {
            case "linear": return "Create Linear issue"
            case "clickup": return "Create ClickUp task"
            case "notion": return "Add to Notion"
            case "n8n": return "Send to n8n"
            default: return "Add to Reminders"
            }
        case .schedule:
            guard let proposal else { return "Find a time" }
            let day: String
            if let start = proposal.currentStart {
                var style = Date.FormatStyle.dateTime.weekday(.wide)
                style.timeZone = calendar.timeZone
                day = start.formatted(style) + "'s"
            } else {
                day = "the"
            }
            if ["gmail", "mail"].contains(destination.id) { return "Propose new times for \(day) meeting" }
            if !proposal.editable { return proposal.source == "google" ? "Open in Google Calendar" : "Find a time" }
            return proposal.slots.isEmpty ? "Find a time" : "Move \(day) meeting"
        case .research:
            return destination.id == "notion" ? "Start research page" : "Add research reminder"
        case .reminder, .unclear:
            return "Add to Reminders"
        }
    }
}
