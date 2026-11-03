import Foundation

/// Decides whether the apps using the microphone are a meeting worth offering to record.
///
/// Rules, in order:
/// 1. Never: LidIA itself, apps the user said "Never for this app" to, and apps that use
///    the mic for other reasons (AI assistants such as Claude or ChatGPT, dictation,
///    recorders, music and video tools, other note takers).
/// 2. A native meeting app on the mic (Zoom, Teams, Webex, Slack huddles, FaceTime,
///    Discord, WhatsApp, …) is a meeting.
/// 3. A browser on the mic is a meeting when one of its windows is a meeting (Google
///    Meet, Teams, Zoom, Webex, Whereby, Jitsi…), or when the calendar has a meeting now.
/// 4. Any other app on the mic is a meeting only while the calendar has a meeting now.
enum MeetingAppRules {
    struct Detection: Equatable, Sendable {
        /// What the banner says: "Zoom", "Google Meet", or the calendar meeting's title.
        var name: String
        var bundleID: String
    }

    static let nativeMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.skype.skype": "Skype",
        "com.logmein.GoToMeeting": "GoTo Meeting",
        "com.logmein.goto": "GoTo",
        "com.ringcentral.glip": "RingCentral",
        "com.amazon.Amazon-Chime": "Amazon Chime",
        "co.teamport.around": "Around",
        "app.tuple.app": "Tuple",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.Telegram": "Telegram",
        "com.apple.mobilephone": "Phone",
    ]

    static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    /// Apps that use the mic without being a meeting.
    static let neverMeetings: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.openai.codex",
        "com.google.GeminiMacOS",
        "com.perplexity.mac",
        "com.apple.VoiceMemos",
        "com.apple.QuickTimePlayerX",
        "com.apple.garageband10",
        "com.apple.logic10",
        "com.apple.Siri",
        "com.apple.assistant_service",
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.corespeechd",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "com.superduper.superwhisper",
        "com.electron.wispr-flow",
        "com.goodsnooze.MacWhisper",
        "com.granola.app",
        "so.granola.app",
        "com.otter.desktop",
        "com.apple.dt.Xcode",
        "com.apple.CoreSimulator.SimulatorTrampoline",
    ]

    /// Window-title fragments that mean a browser tab is a meeting.
    static let meetingTitlePatterns: [(fragment: String, name: String)] = [
        ("Meet - ", "Google Meet"),
        ("Google Meet", "Google Meet"),
        ("meet.google.com", "Google Meet"),
        ("Microsoft Teams", "Microsoft Teams"),
        ("teams.microsoft.com", "Microsoft Teams"),
        ("Zoom Meeting", "Zoom"),
        ("zoom.us", "Zoom"),
        ("Webex", "Webex"),
        ("Whereby", "Whereby"),
        ("Jitsi Meet", "Jitsi"),
        ("meet.jit.si", "Jitsi"),
        ("Slack | Huddle", "Slack"),
    ]

    /// The bundle ID of the app a helper process belongs to ("com.google.Chrome.helper"
    /// → "com.google.Chrome"); unknown IDs come back unchanged.
    static func owningApp(_ bundleID: String) -> String {
        let known = Array(nativeMeetingApps.keys) + Array(browsers.keys) + Array(neverMeetings)
        let match = known
            .filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
        return match ?? bundleID
    }

    /// - Parameters:
    ///   - micApps: bundle IDs of processes using the microphone (helpers included).
    ///   - windowTitles: window titles of browsers on the mic, by bundle ID (needs Screen
    ///     Recording permission; empty when unknown).
    ///   - calendarMeeting: title of a calendar meeting happening now, if any.
    ///   - ignored: apps the user said "Never for this app" to.
    static func detect(
        micApps: [String],
        windowTitles: [String: [String]] = [:],
        calendarMeeting: String? = nil,
        ignored: Set<String> = [],
        selfBundleID: String = Bundle.main.bundleIdentifier ?? "io.lidia.app"
    ) -> Detection? {
        var seen = Set<String>()
        let apps = micApps.map(owningApp).filter { id in
            guard seen.insert(id).inserted else { return false }
            return id != selfBundleID && !id.hasPrefix("io.lidia.app")
                && !ignored.contains(id) && !neverMeetings.contains(id)
        }

        if let native = apps.first(where: { nativeMeetingApps[$0] != nil }) {
            return Detection(name: nativeMeetingApps[native]!, bundleID: native)
        }
        for browser in apps where browsers[browser] != nil {
            let titles = windowTitles[browser] ?? []
            if let service = meetingService(inTitles: titles) {
                return Detection(name: service, bundleID: browser)
            }
            if let calendarMeeting {
                return Detection(name: calendarMeeting, bundleID: browser)
            }
        }
        if let calendarMeeting, let other = apps.first(where: { browsers[$0] == nil }) {
            return Detection(name: calendarMeeting, bundleID: other)
        }
        return nil
    }

    static func meetingService(inTitles titles: [String]) -> String? {
        for title in titles {
            if let match = meetingTitlePatterns.first(where: { title.localizedCaseInsensitiveContains($0.fragment) }) {
                return match.name
            }
        }
        return nil
    }

    /// "Never for this app": stored per user, never sent anywhere.
    static let ignoredDefaultsKey = "meetingDetection.ignoredBundleIDs"

    static func ignoredApps(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: ignoredDefaultsKey) ?? [])
    }

    static func ignore(_ bundleID: String, _ defaults: UserDefaults = .standard) {
        var apps = ignoredApps(defaults)
        apps.insert(bundleID)
        defaults.set(apps.sorted(), forKey: ignoredDefaultsKey)
    }
}
