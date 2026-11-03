import AppKit
import Foundation
import Testing
@testable import LidIA

// MARK: - Meeting detection rules

@Suite("Meeting detection")
struct MeetingDetectionRuleTests {
    private let selfID = "io.lidia.app"

    @Test func claudeOnTheMicIsNotAMeeting() {
        // The owner's case: the Claude desktop app had the mic open.
        #expect(MeetingAppRules.detect(micApps: ["com.anthropic.claudefordesktop"], selfBundleID: selfID) == nil)
        #expect(MeetingAppRules.detect(micApps: ["com.openai.chat", "com.apple.VoiceMemos"], selfBundleID: selfID) == nil)
    }

    @Test func nativeMeetingAppsAreMeetings() {
        #expect(MeetingAppRules.detect(micApps: ["us.zoom.xos"], selfBundleID: selfID)?.name == "Zoom")
        #expect(MeetingAppRules.detect(micApps: ["com.microsoft.teams2"], selfBundleID: selfID)?.name == "Microsoft Teams")
        #expect(MeetingAppRules.detect(micApps: ["com.tinyspeck.slackmacgap.helper"], selfBundleID: selfID)?.bundleID == "com.tinyspeck.slackmacgap")
        // Zoom joins while Claude already holds the mic: still Zoom.
        #expect(MeetingAppRules.detect(micApps: ["com.anthropic.claudefordesktop", "us.zoom.xos"], selfBundleID: selfID)?.name == "Zoom")
    }

    @Test func aBrowserNeedsAMeetingTabOrACalendarMeeting() {
        let chrome = "com.google.Chrome.helper"
        #expect(MeetingAppRules.detect(micApps: [chrome], selfBundleID: selfID) == nil)
        let meet = MeetingAppRules.detect(
            micApps: [chrome],
            windowTitles: ["com.google.Chrome": ["Meet - abc-defg-hij"]],
            selfBundleID: selfID
        )
        #expect(meet == .init(name: "Google Meet", bundleID: "com.google.Chrome"))
        let calendar = MeetingAppRules.detect(micApps: [chrome], calendarMeeting: "Weekly sync", selfBundleID: selfID)
        #expect(calendar?.name == "Weekly sync")
    }

    @Test func unknownAppsNeedACalendarMeeting() {
        #expect(MeetingAppRules.detect(micApps: ["com.example.recorder"], selfBundleID: selfID) == nil)
        #expect(MeetingAppRules.detect(micApps: ["com.example.recorder"], calendarMeeting: "Client call", selfBundleID: selfID)?.name == "Client call")
        // An assistant is never a meeting, calendar or not.
        #expect(MeetingAppRules.detect(micApps: ["com.anthropic.claudefordesktop"], calendarMeeting: "Client call", selfBundleID: selfID) == nil)
    }

    @Test func neverForThisAppAndLidIAItself() {
        #expect(MeetingAppRules.detect(micApps: ["us.zoom.xos"], ignored: ["us.zoom.xos"], selfBundleID: selfID) == nil)
        #expect(MeetingAppRules.detect(micApps: [selfID, "io.lidia.app.snapshot"], calendarMeeting: "x", selfBundleID: selfID) == nil)
        let defaults = UserDefaults(suiteName: "lidia.tests.detection.\(UUID().uuidString)")!
        MeetingAppRules.ignore("com.hnc.Discord", defaults)
        #expect(MeetingAppRules.ignoredApps(defaults) == ["com.hnc.Discord"])
    }

    @Test func bannerSitsTopRightUnderTheMenuBarAndOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 372, height: 64)
        let noItem = MeetingDetectionBannerLayout.origin(bannerSize: size, visibleFrame: screen, statusItemFrame: nil)
        #expect(noItem.x + size.width <= screen.maxX && noItem.x > screen.midX)
        #expect(noItem.y + size.height <= screen.maxY && noItem.y > screen.maxY - 100)
        // Under LidIA's menu bar icon, but never off the left edge.
        let item = MeetingDetectionBannerLayout.origin(bannerSize: size, visibleFrame: screen, statusItemFrame: NSRect(x: 100, y: 875, width: 30, height: 24))
        #expect(item.x >= screen.minX + 10)
    }
}

// MARK: - Calendar match, notices, pill

@Suite("Recording page rules")
struct RecordingPageRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func personalBlocksAreNotCalendarMatches() {
        let block = RecordingCalendarMatch.Candidate(id: "1", title: "Close-down routine", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200), attendees: [], hasMeetingLink: false)
        #expect(RecordingCalendarMatch.pick([block], now: now) == nil)
        let call = RecordingCalendarMatch.Candidate(id: "2", title: "Client call", start: now.addingTimeInterval(300), end: now.addingTimeInterval(2100), attendees: ["ana@example.com"], hasMeetingLink: false)
        #expect(RecordingCalendarMatch.pick([block, call], now: now)?.title == "Client call")
        // A meeting already under way (started 20 min ago) still matches.
        let ongoing = RecordingCalendarMatch.Candidate(id: "3", title: "Standup", start: now.addingTimeInterval(-1200), end: now.addingTimeInterval(600), attendees: [], hasMeetingLink: true)
        #expect(RecordingCalendarMatch.pick([ongoing], now: now)?.title == "Standup")
        // Too far ahead.
        let later = RecordingCalendarMatch.Candidate(id: "4", title: "Later", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), attendees: ["x@y.com"], hasMeetingLink: true)
        #expect(RecordingCalendarMatch.pick([later], now: now) == nil)
    }

    @Test func missingSystemAudioIsOneSentenceWithAFix() {
        let notice = LiveNotice.current(isPaused: false, autoStopSeconds: nil, autoStopReason: nil, quality: .good, systemAudioMissing: true, liveTranscriptNotice: nil, captureMessage: "Screen Recording permission is off…")
        #expect(notice?.text == "Other people aren't being recorded, only your microphone.")
        #expect(notice?.action == .openScreenRecordingSettings)
        #expect(LiveNotice.settingsURL(for: .openScreenRecordingSettings)?.absoluteString.contains("Privacy_ScreenCapture") == true)
    }

    @Test func noticePriority() {
        // Auto-stop beats everything and offers Keep Recording.
        let stop = LiveNotice.current(isPaused: false, autoStopSeconds: 20, autoStopReason: "Silence detected", quality: .noInput, systemAudioMissing: true, liveTranscriptNotice: nil, captureMessage: nil)
        #expect(stop?.action == .keepRecording && stop?.text == "Stopping in 20 s. Silence detected.")
        // Nothing wrong: nothing shown (mic only by choice included).
        #expect(LiveNotice.current(isPaused: false, autoStopSeconds: nil, autoStopReason: nil, quality: .good, systemAudioMissing: false, liveTranscriptNotice: nil, captureMessage: nil) == nil)
        let mic = LiveNotice.current(isPaused: false, autoStopSeconds: nil, autoStopReason: nil, quality: .noInput, systemAudioMissing: true, liveTranscriptNotice: nil, captureMessage: nil)
        #expect(mic?.action == .openSoundSettings)
    }

    @Test func pillHidesWhileLidIAIsInFront() {
        #expect(!RecordingPillVisibility.shouldShow(appIsActive: true, hasVisibleMainWindow: true))
        #expect(RecordingPillVisibility.shouldShow(appIsActive: false, hasVisibleMainWindow: true))
        #expect(RecordingPillVisibility.shouldShow(appIsActive: true, hasVisibleMainWindow: false))
    }
}
