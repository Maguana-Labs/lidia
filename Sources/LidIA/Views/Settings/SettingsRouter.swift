import AppKit
import Observation
import SwiftUI

// MARK: - Panes

/// A page in the Settings sidebar.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case recording
    case notes
    case ai
    case calendars
    case notifications
    case actionItems
    case voice
    case dictation
    case apps
    case sync
    case privacy
    case importData
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .notes: "Notes & Templates"
        case .ai: "AI"
        case .calendars: "Calendars"
        case .notifications: "Notifications"
        case .actionItems: "Action Items"
        case .voice: "Voice"
        case .dictation: "Dictation"
        case .apps: "Apps & Extensions"
        case .sync: "Sync"
        case .privacy: "Privacy"
        case .importData: "Import"
        case .about: "About"
        }
    }

    /// One line under the large page title.
    var subtitle: String {
        switch self {
        case .general: "How LidIA looks and talks to you."
        case .recording: "What LidIA captures and how it writes the transcript."
        case .notes: "How your meeting notes are laid out."
        case .ai: "Where summaries and answers are made."
        case .calendars: "The calendars LidIA reads to know your meetings."
        case .notifications: "When LidIA taps you on the shoulder."
        case .actionItems: "Where your to-dos go after a meeting."
        case .voice: "Talk to LidIA with a keyboard shortcut."
        case .dictation: "Hold a key and speak to type in any app."
        case .apps: "Connect AI apps and the tools you already use."
        case .sync: "Keep your meetings in step on your Mac and iPhone."
        case .privacy: "What stays on this Mac and what leaves it."
        case .importData: "Bring past meetings into LidIA."
        case .about: "Version, updates and help."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .recording: "waveform"
        case .notes: "note.text"
        case .ai: "sparkles"
        case .calendars: "calendar"
        case .notifications: "bell.badge.fill"
        case .actionItems: "checklist"
        case .voice: "mic.fill"
        case .dictation: "text.cursor"
        case .apps: "puzzlepiece.extension.fill"
        case .sync: "icloud.fill"
        case .privacy: "hand.raised.fill"
        case .importData: "square.and.arrow.down.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .recording: .red
        case .notes: .yellow
        case .ai: .purple
        case .calendars: .orange
        case .notifications: .pink
        case .actionItems: .green
        case .voice: .indigo
        case .dictation: .mint
        case .apps: .teal
        case .sync: .blue
        case .privacy: .blue
        case .importData: .cyan
        case .about: .gray
        }
    }

    /// Sidebar order, in groups separated by a little space.
    static let sidebarGroups: [[SettingsPane]] = [
        [.general, .recording, .notes, .ai],
        [.calendars, .notifications, .actionItems, .voice, .dictation],
        [.apps, .sync, .privacy],
        [.importData, .about],
    ]
}

// MARK: - Sub-pages

/// Integrations listed in Apps & Extensions, each with its own detail page.
enum IntegrationKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case notion
    case slack
    case n8n
    case clickUp
    case linear
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notion: "Notion"
        case .slack: "Slack"
        case .n8n: "n8n"
        case .clickUp: "ClickUp"
        case .linear: "Linear"
        case .markdown: "Markdown export"
        }
    }

    var summary: String {
        switch self {
        case .notion: "Send summaries and action items to a database."
        case .slack: "Post meeting notes to a channel."
        case .n8n: "Send each meeting to a webhook."
        case .clickUp: "Turn action items into ClickUp tasks."
        case .linear: "Turn action items into Linear issues."
        case .markdown: "Save every meeting as a .md file."
        }
    }

    var symbol: String {
        switch self {
        case .notion: "doc.richtext.fill"
        case .slack: "number"
        case .n8n: "point.3.connected.trianglepath.dotted"
        case .clickUp: "checkmark.square.fill"
        case .linear: "line.3.horizontal.decrease.circle.fill"
        case .markdown: "doc.plaintext.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notion: Color(white: 0.32)
        case .slack: .purple
        case .n8n: .pink
        case .clickUp: .purple
        case .linear: .indigo
        case .markdown: .brown
        }
    }

    var anchor: SettingsAnchor {
        switch self {
        case .notion: .notion
        case .slack: .slack
        case .n8n: .n8n
        case .clickUp: .clickUp
        case .linear: .linear
        case .markdown: .markdownExport
        }
    }
}

/// A page pushed on top of a pane.
enum SettingsSubpage: Hashable, Sendable {
    case vocabulary
    case onDeviceModels
    case aiAdvanced
    case template(UUID)
    case integration(IntegrationKind)

    var title: String {
        switch self {
        case .vocabulary: "Custom vocabulary"
        case .onDeviceModels: "On-device models"
        case .aiAdvanced: "Advanced"
        case .template: "Template"
        case .integration(let kind): kind.title
        }
    }
}

// MARK: - Anchors

/// A row search can scroll to. Each anchor is placed on exactly one row.
enum SettingsAnchor: String, CaseIterable, Hashable, Sendable {
    // General
    case appearance, displayName, personality, soulMemory
    // Recording
    case captureMode, noteTranscription, sttEngine, sttLanguage, diarization, autoDetect, autoStop, vocabulary
    case consentReminder, allPartyConsent
    case vadPrefilter, speechEnhancement, whisperModel
    // Notes & Templates
    case templates, defaultTemplate
    // AI
    case aiLocation, aiProvider, apiKey, aiModel, onDeviceModels
    case taskModels, routing, fallback, cloudFallback, otherKeys, keySync, allModels
    // Calendars
    case calendarReminder, googleCalendar, appleCalendar, googleOAuth
    // Notifications
    case meetingReminder, prepNotes, reviewNudge, morningDigest, actionItemReminders, quietHours
    // Action Items
    case remindersSync, remindersWho, autopilot
    // Voice
    case voiceAssistant, voiceHotkey, voiceOutput, readAloud, voiceSilence, grokVoice
    // Dictation
    case dictationEnabled, dictationKey, dictationMode, dictationInsertion, dictationTidy
    case dictationPolish, dictationLanguage, dictationEngine, dictationHistory
    // Apps & Extensions
    case connectAIApps, notion, slack, n8n, clickUp, linear, markdownExport
    // Sync
    case iCloudSync, iCloudStatus, deviceSync
    // Privacy
    case localOnly, siriContent, companyLogos, whatLeaves
    // Import
    case importGranola, importNotes
    // About
    case version, checkUpdates, autoUpdates
}

/// Where a search result lives.
struct SettingsLocation: Hashable, Sendable {
    var pane: SettingsPane
    var subpage: SettingsSubpage?
    var anchor: SettingsAnchor
    /// The row sits in the pane's collapsed "Advanced" section.
    var inAdvanced = false
}

// MARK: - Router

/// Which Settings page is showing, and where search wants to go.
///
/// Open Settings at a page from anywhere:
/// ```swift
/// SettingsRouter.shared.open(.calendars)
/// SettingsRouter.shared.open(.ai, subpage: .aiAdvanced, anchor: .fallback)
/// ```
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()

    private static let lastPaneKey = "settings.lastPane"

    /// The pane in the detail column. Remembered across launches.
    var pane: SettingsPane {
        didSet {
            guard pane != oldValue else { return }
            UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey)
            path = []
        }
    }

    /// Pages pushed on top of the pane.
    var path: [SettingsSubpage] = []

    /// Sidebar search text.
    var searchText = ""

    /// A row to scroll to once its page is on screen.
    private(set) var pendingTarget: SettingsLocation?

    /// The row flashing after a search jump.
    private(set) var highlighted: SettingsAnchor?

    /// Panes whose "Advanced" section is open.
    var expandedAdvanced: Set<SettingsPane> = []

    private var highlightTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: Self.lastPaneKey).flatMap(SettingsPane.init(rawValue:))
        pane = stored ?? .general
    }

    /// Shows a pane (and optionally a sub-page and row) in the Settings window
    /// without bringing it forward.
    func show(_ pane: SettingsPane, subpage: SettingsSubpage? = nil, anchor: SettingsAnchor? = nil) {
        let paneChanged = pane != self.pane
        self.pane = pane
        let newPath = subpage.map { [$0] } ?? []
        if paneChanged && !newPath.isEmpty {
            // The stack swaps its root when the pane changes; push once the
            // new root is in place, or the push is dropped.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.pane == pane else { return }
                self.path = newPath
            }
        } else {
            path = newPath
        }
        if let anchor {
            pendingTarget = SettingsLocation(pane: pane, subpage: subpage, anchor: anchor)
        }
    }

    /// Opens the Settings window at a pane.
    func open(_ pane: SettingsPane, subpage: SettingsSubpage? = nil, anchor: SettingsAnchor? = nil) {
        show(pane, subpage: subpage, anchor: anchor)
        Self.bringWindowForward()
    }

    /// Jumps to a search result: opens its page, expands "Advanced" if needed,
    /// scrolls to the row and flashes it.
    func reveal(_ location: SettingsLocation) {
        if location.inAdvanced {
            expandedAdvanced.insert(location.pane)
        }
        show(location.pane, subpage: location.subpage, anchor: location.anchor)
    }

    /// Called by a page once it has scrolled to its pending row.
    func didScroll(to location: SettingsLocation) {
        guard pendingTarget == location else { return }
        pendingTarget = nil
        flash(location.anchor)
    }

    func flash(_ anchor: SettingsAnchor) {
        highlightTask?.cancel()
        highlighted = anchor
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.highlighted = nil
        }
    }

    /// SwiftUI's `openSettings`, handed over by the main window so code
    /// outside a view can open the Settings scene reliably.
    private var openSettingsAction: OpenSettingsAction?

    func register(_ action: OpenSettingsAction) {
        openSettingsAction = action
    }

    /// Opens (or brings forward) the SwiftUI Settings window.
    static func bringWindowForward() {
        NSApp.activate()
        if let action = shared.openSettingsAction {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

/// Lives in the main window and gives the router SwiftUI's `openSettings`.
struct SettingsOpenerRegistrar: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { SettingsRouter.shared.register(openSettings) }
    }
}
