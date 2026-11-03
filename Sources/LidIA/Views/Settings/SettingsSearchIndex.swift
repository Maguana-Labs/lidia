import Foundation

/// One searchable setting.
struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    /// Same as the anchor's raw value, so ids are unique when anchors are.
    var id: String { location.anchor.rawValue }
    let title: String
    /// Words people might type instead of the title.
    let keywords: [String]
    let location: SettingsLocation

    var pane: SettingsPane { location.pane }
    var anchor: SettingsAnchor { location.anchor }

    /// "Notifications" or "AI › Advanced", shown under the title.
    var breadcrumb: String {
        if let subpage = location.subpage {
            switch subpage {
            case .template: return pane.title
            default: return "\(pane.title) › \(subpage.title)"
            }
        }
        return location.inAdvanced ? "\(pane.title) › Advanced" : pane.title
    }
}

/// Static registry of every setting search can find, and the ranking.
enum SettingsSearchIndex {
    private static func entry(
        _ title: String,
        _ pane: SettingsPane,
        _ anchor: SettingsAnchor,
        subpage: SettingsSubpage? = nil,
        advanced: Bool = false,
        keywords: [String] = []
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: title,
            keywords: keywords,
            location: SettingsLocation(pane: pane, subpage: subpage, anchor: anchor, inAdvanced: advanced)
        )
    }

    static let entries: [SettingsSearchEntry] = [
        // General
        entry("Appearance", .general, .appearance,
              keywords: ["theme", "dark mode", "light mode", "colors", "look"]),
        entry("Your name", .general, .displayName,
              keywords: ["name", "display name", "me", "profile", "speaker label", "who am i"]),
        entry("Assistant personality", .general, .personality,
              keywords: ["tone", "professional", "friendly", "witty", "style", "voice"]),
        entry("Assistant instructions and memory", .general, .soulMemory,
              keywords: ["soul", "soul.md", "memory", "memory.md", "instructions", "custom prompt"]),

        // Recording
        entry("What to record", .recording, .captureMode,
              keywords: ["microphone", "mic", "system audio", "capture", "screen recording", "audio", "speakers"]),
        entry("Transcription engine", .recording, .sttEngine,
              keywords: ["parakeet", "whisper", "whisperkit", "granite", "apple speech", "speech to text", "stt", "transcribe"]),
        entry("Transcription language", .recording, .sttLanguage,
              keywords: ["language", "spanish", "english", "french", "german", "portuguese", "multilingual"]),
        entry("Tell speakers apart", .recording, .diarization,
              keywords: ["diarization", "speakers", "who said what", "speaker labels"]),
        entry("Transcribe when I create a note", .recording, .noteTranscription,
              keywords: ["new note", "note", "transcribe", "auto transcribe", "automatic transcription", "during meetings", "granola"]),
        entry("Detect meetings automatically", .recording, .autoDetect,
              keywords: ["auto-detect", "auto detect", "zoom", "teams", "meet", "banner", "start recording"]),
        entry("Stop when it goes quiet", .recording, .autoStop,
              keywords: ["auto-stop", "auto stop", "silence", "timeout", "end recording"]),
        entry("Custom vocabulary", .recording, .vocabulary, subpage: .vocabulary,
              keywords: ["words", "replacements", "misheard", "glossary", "names", "jargon", "spelling"]),
        entry("Remind me to tell people", .recording, .consentReminder,
              keywords: ["consent", "disclosure", "ai notes", "recording notice", "tell participants"]),
        entry("Everyone must agree to be recorded", .recording, .allPartyConsent,
              keywords: ["all-party consent", "two-party", "california", "legal", "consent"]),
        entry("Skip silence before transcribing", .recording, .vadPrefilter, advanced: true,
              keywords: ["vad", "voice activity", "pre-filter", "silence"]),
        entry("Reduce background noise", .recording, .speechEnhancement, advanced: true,
              keywords: ["speech enhancement", "noise", "deepfilternet", "denoise"]),
        entry("Whisper model", .recording, .whisperModel, advanced: true,
              keywords: ["whisperkit", "large-v3", "model size"]),

        // Notes & Templates
        entry("Meeting templates", .notes, .templates,
              keywords: ["template", "sections", "prompt", "format", "summary layout", "1:1", "standup", "brainstorm"]),
        entry("Default template", .notes, .defaultTemplate,
              keywords: ["template", "fallback", "summary", "notes style"]),

        // AI
        entry("Where AI runs", .ai, .aiLocation,
              keywords: ["on this mac", "local", "cloud", "llm", "ai provider", "offline", "private"]),
        entry("AI provider", .ai, .aiProvider,
              keywords: ["provider", "anthropic", "claude", "openai", "chatgpt", "gpt", "gemini", "groq", "openrouter",
                         "deepseek", "ollama", "lm studio", "apple intelligence", "mlx", "llm"]),
        entry("API key", .ai, .apiKey,
              keywords: ["api key", "key", "token", "secret", "anthropic", "claude", "openai", "validate"]),
        entry("AI model", .ai, .aiModel,
              keywords: ["model", "default model", "claude", "sonnet", "opus", "haiku", "gpt", "fetch models"]),
        entry("On-device models", .ai, .onDeviceModels, subpage: .onDeviceModels,
              keywords: ["download", "mlx", "local model", "qwen", "llama", "gemma", "storage", "disk"]),
        entry("Models per task", .ai, .taskModels, subpage: .aiAdvanced,
              keywords: ["query model", "summary model", "chat model"]),
        entry("Model routing", .ai, .routing, subpage: .aiAdvanced,
              keywords: ["routing", "route", "per task", "provider per task"]),
        entry("Fallback provider", .ai, .fallback, subpage: .aiAdvanced,
              keywords: ["fallback", "backup", "retry", "failover"]),
        entry("If the on-device model fails", .ai, .cloudFallback, subpage: .aiAdvanced,
              keywords: ["cloud fallback", "ask before cloud", "never use the cloud"]),
        entry("Other API keys", .ai, .otherKeys, subpage: .aiAdvanced,
              keywords: ["api key", "keys", "anthropic", "claude", "openai", "gemini", "groq", "openrouter",
                         "deepseek", "cerebras", "nvidia", "nim"]),
        entry("Sync API keys with iCloud", .ai, .keySync, subpage: .aiAdvanced,
              keywords: ["icloud", "keychain", "iphone", "sync keys"]),
        entry("Show every model", .ai, .allModels, subpage: .aiAdvanced,
              keywords: ["all models", "model list", "advanced models"]),

        // Calendars
        entry("Calendar reminder", .calendars, .calendarReminder,
              keywords: ["reminder", "minutes before", "alert", "heads up", "upcoming"]),
        entry("Google Calendar", .calendars, .googleCalendar,
              keywords: ["google", "gmail", "sign in", "workspace", "account"]),
        entry("Apple Calendar", .calendars, .appleCalendar,
              keywords: ["icloud", "exchange", "outlook", "calendar list", "show calendars", "hide calendar", "eventkit"]),
        entry("Use your own Google OAuth client", .calendars, .googleOAuth, advanced: true,
              keywords: ["oauth", "client id", "client secret", "google cloud"]),

        // Notifications
        entry("Remind me before meetings", .notifications, .meetingReminder,
              keywords: ["reminder", "before a meeting", "minutes before", "notification", "alert", "join",
                         "ask to record", "record prompt", "join & record", "banner"]),
        entry("Show prep notes", .notifications, .prepNotes,
              keywords: ["prep", "prepare", "brief", "context", "last meeting"]),
        entry("Nudge me to review", .notifications, .reviewNudge,
              keywords: ["after a meeting", "post-meeting", "follow up", "review notes"]),
        entry("Morning digest", .notifications, .morningDigest,
              keywords: ["digest", "daily", "morning", "agenda", "summary of the day", "mondays"]),
        entry("Action item reminders", .notifications, .actionItemReminders,
              keywords: ["due", "overdue", "to-dos", "tasks", "reminder"]),
        entry("Quiet hours", .notifications, .quietHours,
              keywords: ["do not disturb", "dnd", "night", "mute", "silence notifications", "focus"]),

        // Action Items
        entry("Sync to Apple Reminders", .actionItems, .remindersSync,
              keywords: ["reminders", "apple reminders", "to-dos", "tasks", "reminder"]),
        entry("Which items to sync", .actionItems, .remindersWho,
              keywords: ["assigned to me", "all items", "mine"]),
        entry("Autopilot", .actionItems, .autopilot,
              keywords: ["auto-dispatch", "dispatch", "clickup", "send action items", "automation"]),

        // Voice
        entry("Voice assistant", .voice, .voiceAssistant,
              keywords: ["voice", "talk", "speak", "assistant", "siri"]),
        entry("Voice shortcut", .voice, .voiceHotkey,
              keywords: ["hotkey", "shortcut", "keyboard", "option space"]),
        entry("Spoken answers", .voice, .voiceOutput,
              keywords: ["text to speech", "tts", "voice", "openai voice", "system voice"]),
        entry("Read answers aloud", .voice, .readAloud,
              keywords: ["speak", "read aloud", "audio replies"]),
        entry("Wait before answering", .voice, .voiceSilence,
              keywords: ["silence timeout", "pause", "end of speech"]),
        entry("Grok voice", .voice, .grokVoice,
              keywords: ["xai", "x.ai", "grok", "realtime", "better voice", "own key", "cloud voice"]),

        // Dictation
        entry("Dictation", .dictation, .dictationEnabled,
              keywords: ["dictate", "voice typing", "speech to text", "type with your voice", "any app",
                         "wispr", "superwhisper", "accessibility"]),
        entry("Dictation key", .dictation, .dictationKey,
              keywords: ["fn", "globe", "right option", "push to talk", "hold to talk", "hotkey", "shortcut", "trigger"]),
        entry("Hold or double-tap", .dictation, .dictationMode,
              keywords: ["hands-free", "toggle", "double tap", "push to talk", "mode"]),
        entry("How text is inserted", .dictation, .dictationInsertion,
              keywords: ["paste", "clipboard", "accessibility", "insert", "cursor", "type"]),
        entry("Tidy dictated text", .dictation, .dictationTidy,
              keywords: ["filler words", "um", "uh", "self-correction", "lists", "punctuation", "cleanup"]),
        entry("Polish with AI", .dictation, .dictationPolish,
              keywords: ["ai cleanup", "rewrite", "grammar", "llm", "polish"]),
        entry("Which language you speak", .dictation, .dictationLanguage,
              keywords: ["dictation language", "spanish", "english", "locale"]),
        entry("Speech recognition for dictation", .dictation, .dictationEngine,
              keywords: ["engine", "speechanalyzer", "parakeet", "on-device", "recognizer"]),
        entry("Dictation history", .dictation, .dictationHistory,
              keywords: ["recent dictations", "history", "clear", "log"]),

        // Apps & Extensions
        entry("Connect AI apps", .apps, .connectAIApps,
              keywords: ["mcp", "claude", "claude desktop", "claude code", "cursor", "codex", "vs code", "windsurf",
                         "model context protocol", "ai apps"]),
        entry("Notion", .apps, .notion, subpage: .integration(.notion),
              keywords: ["notion", "database", "export", "integration"]),
        entry("Slack", .apps, .slack, subpage: .integration(.slack),
              keywords: ["slack", "channel", "bot token", "post", "integration"]),
        entry("n8n", .apps, .n8n, subpage: .integration(.n8n),
              keywords: ["webhook", "automation", "zapier", "make", "integration"]),
        entry("ClickUp", .apps, .clickUp, subpage: .integration(.clickUp),
              keywords: ["clickup", "tasks", "ticket", "list", "api token", "integration"]),
        entry("Linear", .apps, .linear, subpage: .integration(.linear),
              keywords: ["linear", "issues", "ticket", "bug", "team", "api key", "integration"]),
        entry("Markdown export", .apps, .markdownExport, subpage: .integration(.markdown),
              keywords: ["markdown", "obsidian", "vault", "md", "files", "export", "folder"]),

        // Sync
        entry("Sync with iCloud", .sync, .iCloudSync,
              keywords: ["icloud", "sync", "iphone", "ipad", "devices", "cloudkit", "apple account", "backup"]),
        entry("iCloud sync status", .sync, .iCloudStatus,
              keywords: ["last synced", "sync status", "sync error", "icloud account", "storage full", "signed in"]),
        entry("Self-hosted sync (advanced)", .sync, .deviceSync, advanced: true,
              keywords: ["sync server", "lidia-sync", "own server", "self-hosted", "device sync", "token"]),

        // Privacy
        entry("Local-only mode", .privacy, .localOnly,
              keywords: ["offline", "private", "privacy", "no cloud", "local", "block network"]),
        entry("Let Siri read meeting content", .privacy, .siriContent,
              keywords: ["siri", "apple intelligence", "shortcuts", "voice", "assistant", "summaries", "app intents", "spotlight"]),
        entry("Company logos", .privacy, .companyLogos,
              keywords: ["logos", "icons", "favicons", "websites"]),
        entry("What leaves this Mac", .privacy, .whatLeaves,
              keywords: ["data", "privacy", "network", "sent", "cloud", "disclosure"]),

        // Import
        entry("Import from Granola", .importData, .importGranola,
              keywords: ["granola", "migrate", "move from"]),
        entry("Import notes", .importData, .importNotes,
              keywords: ["markdown", "md", "txt", "files", "obsidian", "notes"]),

        // About
        entry("Version", .about, .version,
              keywords: ["about", "build", "version number"]),
        entry("Check for updates", .about, .checkUpdates,
              keywords: ["update", "upgrade", "sparkle", "new version"]),
        entry("Check automatically", .about, .autoUpdates,
              keywords: ["automatic updates", "auto update"]),
    ]

    // MARK: - Ranking

    /// Entries matching `query`, best first. Every word of the query must
    /// match the title, a keyword or the pane name.
    static func search(_ query: String, in entries: [SettingsSearchEntry] = entries) -> [SettingsSearchEntry] {
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let scored: [(entry: SettingsSearchEntry, score: Int)] = entries.compactMap { entry in
            guard let score = score(entry, query: normalizedQuery, tokens: tokens) else { return nil }
            return (entry, score)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
            }
            .map(\.entry)
    }

    /// nil when some query word matches nothing.
    static func score(_ entry: SettingsSearchEntry, query: String, tokens: [String]) -> Int? {
        let title = normalize(entry.title)
        let keywords = entry.keywords.map(normalize)
        let pane = normalize(entry.pane.title)

        var total = 0
        for token in tokens {
            let best = max(
                textScore(title, token, exact: 100, prefix: 80, wordPrefix: 60, contains: 30),
                keywords.map { textScore($0, token, exact: 50, prefix: 40, wordPrefix: 35, contains: 15) }.max() ?? 0,
                textScore(pane, token, exact: 12, prefix: 10, wordPrefix: 8, contains: 0)
            )
            guard best > 0 else { return nil }
            total += best
        }

        // The whole phrase matching beats scattered words.
        if tokens.count > 1 {
            if title == query { total += 120 }
            else if title.hasPrefix(query) { total += 90 }
            else if title.contains(query) { total += 60 }
            else if keywords.contains(query) { total += 70 }
            else if keywords.contains(where: { $0.hasPrefix(query) }) { total += 50 }
            else if keywords.contains(where: { $0.contains(query) }) { total += 30 }
        }
        return total
    }

    private static func textScore(_ text: String, _ token: String, exact: Int, prefix: Int, wordPrefix: Int, contains: Int) -> Int {
        if text == token { return exact }
        if text.hasPrefix(token) { return prefix }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(token) }) { return wordPrefix }
        if contains > 0, token.count >= 3, text.contains(token) { return contains }
        return 0
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
