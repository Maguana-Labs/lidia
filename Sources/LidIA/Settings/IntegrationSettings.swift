import Foundation
import Observation

@MainActor
@Observable
final class IntegrationSettings {
    private var isLoading = false

    // Notion
    var notionAPIKey: String = "" {
        didSet { SettingsKeychain.save(key: "lidia.notion.apiKey", value: notionAPIKey) }
    }
    var notionDatabaseID: String = "" {
        didSet { saveDefault(notionDatabaseID, forKey: "notionDatabaseID") }
    }
    var notionDatabaseName: String = "" {
        didSet { saveDefault(notionDatabaseName, forKey: "notionDatabaseName") }
    }
    var notionTasksDatabaseID: String = "" {
        didSet { saveDefault(notionTasksDatabaseID, forKey: "notionTasksDatabaseID") }
    }
    var availableDatabases: [AppSettings.DatabaseEntry] = []

    // n8n
    var n8nEnabled: Bool = false {
        didSet { saveDefault(n8nEnabled, forKey: "n8nEnabled") }
    }
    var n8nWebhookURL: String = "" {
        didSet { saveDefault(n8nWebhookURL, forKey: "n8nWebhookURL") }
    }
    var n8nAuthHeader: String = "" {
        didSet { SettingsKeychain.save(key: "lidia.n8n.authHeader", value: n8nAuthHeader) }
    }

    // Slack
    var slackEnabled: Bool = false {
        didSet { saveDefault(slackEnabled, forKey: "slackEnabled") }
    }
    var slackBotToken: String = "" {
        didSet { SettingsKeychain.save(key: "lidia.slack.botToken", value: slackBotToken) }
    }
    var slackChannel: String = "" {
        didSet { saveDefault(slackChannel, forKey: "slackChannel") }
    }
    var slackAutoSend: Bool = false {
        didSet { saveDefault(slackAutoSend, forKey: "slackAutoSend") }
    }
    var slackSendSummary: Bool = true {
        didSet { saveDefault(slackSendSummary, forKey: "slackSendSummary") }
    }
    var slackSendActionItems: Bool = true {
        didSet { saveDefault(slackSendActionItems, forKey: "slackSendActionItems") }
    }
    var slackSendAttendees: Bool = true {
        didSet { saveDefault(slackSendAttendees, forKey: "slackSendAttendees") }
    }

    // ClickUp
    var clickUpAPIKey: String = "" {
        didSet { SettingsKeychain.save(key: "lidia.clickup.apiKey", value: clickUpAPIKey) }
    }
    var clickUpListID: String = "" {
        didSet { saveDefault(clickUpListID, forKey: "clickUpListID") }
    }

    // Linear
    var linearAPIKey: String = "" {
        didSet { SettingsKeychain.save(key: "lidia.linear.apiKey", value: linearAPIKey) }
    }
    var linearTeamID: String = "" {
        didSet { saveDefault(linearTeamID, forKey: "linearTeamID") }
    }
    var linearTeamName: String = "" {
        didSet { saveDefault(linearTeamName, forKey: "linearTeamName") }
    }

    // Sync
    var syncEnabled: Bool = false {
        didSet { saveDefault(syncEnabled, forKey: "syncEnabled") }
    }
    var syncServerURL: String = "" {
        didSet { saveDefault(syncServerURL, forKey: "syncServerURL") }
    }
    var syncAuthToken: String = "" {
        didSet { SettingsKeychain.save(key: "lidia.sync.authToken", value: syncAuthToken) }
    }

    // Integration auto-send
    var notionAutoSend: Bool = false {
        didSet { saveDefault(notionAutoSend, forKey: "notionAutoSend") }
    }
    var n8nAutoSend: Bool = false {
        didSet { saveDefault(n8nAutoSend, forKey: "n8nAutoSend") }
    }
    var remindersAutoSend: Bool = true {
        didSet { saveDefault(remindersAutoSend, forKey: "remindersAutoSend") }
    }

    // Notion field controls
    var notionSendSummary: Bool = true {
        didSet { saveDefault(notionSendSummary, forKey: "notionSendSummary") }
    }
    var notionSendActionItems: Bool = true {
        didSet { saveDefault(notionSendActionItems, forKey: "notionSendActionItems") }
    }

    // n8n field controls
    var n8nSendSummary: Bool = true {
        didSet { saveDefault(n8nSendSummary, forKey: "n8nSendSummary") }
    }
    var n8nSendActionItems: Bool = true {
        didSet { saveDefault(n8nSendActionItems, forKey: "n8nSendActionItems") }
    }
    var n8nSendAttendees: Bool = true {
        didSet { saveDefault(n8nSendAttendees, forKey: "n8nSendAttendees") }
    }
    var n8nSendTranscript: Bool = false {
        didSet { saveDefault(n8nSendTranscript, forKey: "n8nSendTranscript") }
    }

    // Reminders field controls
    var remindersMyItemsOnly: Bool = true {
        didSet { saveDefault(remindersMyItemsOnly, forKey: "remindersMyItemsOnly") }
    }

    // Autopilot
    var autopilotEnabled: Bool = false {
        didSet { saveDefault(autopilotEnabled, forKey: "autopilotEnabled") }
    }

    // Markdown Vault Export
    var vaultExportEnabled: Bool = false {
        didSet { saveDefault(vaultExportEnabled, forKey: "vaultExportEnabled") }
    }
    var vaultExportPath: String = "~/Documents/LidIA" {
        didSet { saveDefault(vaultExportPath, forKey: "vaultExportPath") }
    }
    var vaultExportIncludeTranscript: Bool = false {
        didSet { saveDefault(vaultExportIncludeTranscript, forKey: "vaultExportIncludeTranscript") }
    }

    // MARK: - Init

    init() {
        loadFromDefaults()
    }

    func loadFromDefaults() {
        isLoading = true
        defer { isLoading = false }
        let defaults = UserDefaults.standard
        notionAPIKey = SettingsKeychain.load(key: "lidia.notion.apiKey") ?? ""
        notionDatabaseID = defaults.string(forKey: "notionDatabaseID") ?? ""
        notionDatabaseName = defaults.string(forKey: "notionDatabaseName") ?? ""
        notionTasksDatabaseID = defaults.string(forKey: "notionTasksDatabaseID") ?? ""
        n8nEnabled = defaults.bool(forKey: "n8nEnabled")
        n8nWebhookURL = defaults.string(forKey: "n8nWebhookURL") ?? ""
        n8nAuthHeader = SettingsKeychain.load(key: "lidia.n8n.authHeader") ?? ""
        slackEnabled = defaults.bool(forKey: "slackEnabled")
        slackBotToken = SettingsKeychain.load(key: "lidia.slack.botToken") ?? ""
        slackChannel = defaults.string(forKey: "slackChannel") ?? ""
        Self.migrateIntegrationDefaults(
            in: defaults,
            notionConfigured: !notionAPIKey.isEmpty && !notionDatabaseID.isEmpty,
            n8nConfigured: n8nEnabled && !n8nWebhookURL.isEmpty,
            slackConfigured: slackEnabled && !slackBotToken.isEmpty
        )
        if let val = defaults.object(forKey: "slackAutoSend") as? Bool {
            slackAutoSend = val
        }
        if let val = defaults.object(forKey: "slackSendSummary") as? Bool {
            slackSendSummary = val
        }
        if let val = defaults.object(forKey: "slackSendActionItems") as? Bool {
            slackSendActionItems = val
        }
        if let val = defaults.object(forKey: "slackSendAttendees") as? Bool {
            slackSendAttendees = val
        }
        clickUpAPIKey = SettingsKeychain.load(key: "lidia.clickup.apiKey") ?? ""
        clickUpListID = defaults.string(forKey: "clickUpListID") ?? ""
        linearAPIKey = SettingsKeychain.load(key: "lidia.linear.apiKey") ?? ""
        linearTeamID = defaults.string(forKey: "linearTeamID") ?? ""
        linearTeamName = defaults.string(forKey: "linearTeamName") ?? ""
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncServerURL = defaults.string(forKey: "syncServerURL") ?? ""
        syncAuthToken = SettingsKeychain.load(key: "lidia.sync.authToken") ?? ""
        if let autoSend = defaults.object(forKey: "notionAutoSend") as? Bool {
            notionAutoSend = autoSend
        }
        if let autoSend = defaults.object(forKey: "n8nAutoSend") as? Bool {
            n8nAutoSend = autoSend
        }
        if let autoSend = defaults.object(forKey: "remindersAutoSend") as? Bool {
            remindersAutoSend = autoSend
        }
        if let val = defaults.object(forKey: "notionSendSummary") as? Bool {
            notionSendSummary = val
        }
        if let val = defaults.object(forKey: "notionSendActionItems") as? Bool {
            notionSendActionItems = val
        }
        if let val = defaults.object(forKey: "n8nSendSummary") as? Bool {
            n8nSendSummary = val
        }
        if let val = defaults.object(forKey: "n8nSendActionItems") as? Bool {
            n8nSendActionItems = val
        }
        if let val = defaults.object(forKey: "n8nSendAttendees") as? Bool {
            n8nSendAttendees = val
        }
        if let val = defaults.object(forKey: "n8nSendTranscript") as? Bool {
            n8nSendTranscript = val
        }
        if let val = defaults.object(forKey: "remindersMyItemsOnly") as? Bool {
            remindersMyItemsOnly = val
        }
        autopilotEnabled = defaults.bool(forKey: "autopilotEnabled")
        vaultExportEnabled = defaults.bool(forKey: "vaultExportEnabled")
        if let path = defaults.string(forKey: "vaultExportPath"), !path.isEmpty {
            vaultExportPath = path
        }
        vaultExportIncludeTranscript = defaults.bool(forKey: "vaultExportIncludeTranscript")
    }

    // MARK: - Default Migration

    static let integrationDefaultsVersionKey = "integrationDefaultsVersion"

    /// Notion, n8n and Slack auto-send, and n8n's full transcript, used to
    /// default to on and now default to off. Settings only persist once the
    /// user flips them, so an existing user who set an integration up and
    /// never touched these toggles has nothing stored and relies on the old
    /// "on". For those users, pin the old value once so their workflow keeps
    /// working; everyone else (and every new setup) gets the new off defaults.
    /// Explicitly stored values are never changed.
    static func migrateIntegrationDefaults(
        in defaults: UserDefaults,
        notionConfigured: Bool,
        n8nConfigured: Bool,
        slackConfigured: Bool
    ) {
        guard defaults.integer(forKey: integrationDefaultsVersionKey) < 1 else { return }
        defer { defaults.set(1, forKey: integrationDefaultsVersionKey) }

        func pinLegacyValue(_ key: String, if configured: Bool) {
            guard configured, defaults.object(forKey: key) == nil else { return }
            defaults.set(true, forKey: key)
        }
        pinLegacyValue("notionAutoSend", if: notionConfigured)
        pinLegacyValue("n8nAutoSend", if: n8nConfigured)
        pinLegacyValue("n8nSendTranscript", if: n8nConfigured)
        pinLegacyValue("slackAutoSend", if: slackConfigured)
    }

    // MARK: - Persistence Helpers

    private func saveDefault(_ value: some Any, forKey key: String) {
        guard !isLoading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
