import AppKit
import Foundation
import LidIALiveActivity
import Testing
@testable import LidIA

// MARK: - Recording state

@Suite("Menu bar Live Activity: recording state")
struct RecordingActivityStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(
        title: String = "Weekly sync",
        elapsed: TimeInterval = 754,
        paused: Bool = false,
        line: RecordingActivityState.Line? = nil,
        at date: Date? = nil,
        previous: RecordingActivityState? = nil
    ) -> RecordingActivityState {
        RecordingActivityState.make(
            title: title, elapsed: elapsed, isPaused: paused, lastLine: line,
            warning: nil, transcriptNotice: nil, now: date ?? now, previous: previous
        )
    }

    @Test func mapsTheTimerToAStartDateSoItTicksWithoutUpdates() {
        let state = make()
        #expect(state.timerStart == now.addingTimeInterval(-754))
        #expect(state.elapsed(at: now) == 754)
        #expect(state.elapsed(at: now.addingTimeInterval(10)) == 764)
        #expect(state.pauseTime == nil)
        #expect(!state.isPaused)
        #expect(state.timerInterval.lowerBound == state.timerStart)
    }

    @Test func pausedFreezesTheTimer() {
        let state = make(elapsed: 120, paused: true)
        #expect(state.isPaused)
        #expect(state.elapsed(at: now.addingTimeInterval(500)) == 120)
        #expect(state.pauseTime == state.timerStart.addingTimeInterval(120))
    }

    @Test func aRunningTimerKeepsItsStartAcrossTicks() {
        // A second later the session reports 755.02 s: same start, so no update.
        let first = make()
        let second = make(elapsed: 755.02, at: now.addingTimeInterval(1), previous: first)
        #expect(second == first)
        // After a pause the start moves forward by the paused time.
        let resumed = make(elapsed: 755, at: now.addingTimeInterval(60), previous: first)
        #expect(resumed.timerStart == now.addingTimeInterval(60 - 755))
    }

    @Test func aPausedTimerKeepsItsStartWhileFrozen() {
        let paused = make(elapsed: 120, paused: true)
        let later = make(elapsed: 120, paused: true, at: now.addingTimeInterval(30), previous: paused)
        #expect(later == paused)
    }

    @Test func emptyTitlesReadUntitled() {
        #expect(make(title: "  \n").title == RecordingActivityState.untitled)
        #expect(make(title: " Board review ").title == "Board review")
    }

    @Test func longLinesKeepTheirNewestWords() {
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        let clipped = RecordingActivityState.clip(words)
        #expect(clipped.hasPrefix("…"))
        #expect(clipped.hasSuffix("word60"))
        #expect(clipped.count <= RecordingActivityState.lineLimit + 1)
        #expect(!clipped.dropFirst().hasPrefix(" "))
        #expect(RecordingActivityState.clip("  short\n line ") == "short line")
        // Whitespace-only lines show nothing.
        #expect(make(line: .init(text: "   ", isLocal: true)).lastLine == nil)
    }

    @Test func roundTripsAsCodable() throws {
        let state = make(line: .init(text: "Sounds good.", isLocal: false))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(RecordingActivityState.self, from: data) == state)
    }
}

// MARK: - Throttling

@Suite("Menu bar Live Activity: update throttling")
struct ActivityUpdateThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstValueGoesThroughAtOnce() {
        var throttle = ActivityUpdateThrottle<String>(minimumInterval: 4)
        #expect(throttle.accept("Hello", at: t0) == "Hello")
    }

    @Test func changesWaitForTheIntervalThenGoThrough() {
        var throttle = ActivityUpdateThrottle<String>(minimumInterval: 4)
        _ = throttle.accept("one", at: t0)
        #expect(throttle.accept("one two", at: t0.addingTimeInterval(1)) == "one")
        #expect(throttle.isPending("one two", at: t0.addingTimeInterval(1)))
        #expect(throttle.accept("one two three", at: t0.addingTimeInterval(3.9)) == "one")
        // The first tick after the interval publishes the newest value, not a stale one.
        #expect(throttle.accept("one two three", at: t0.addingTimeInterval(4)) == "one two three")
        #expect(!throttle.isPending("one two three", at: t0.addingTimeInterval(4)))
        #expect(throttle.publishedAt == t0.addingTimeInterval(4))
    }

    @Test func sameOrMissingValuesKeepWhatIsShown() {
        var throttle = ActivityUpdateThrottle<String>(minimumInterval: 4)
        _ = throttle.accept("one", at: t0)
        #expect(throttle.accept(nil, at: t0.addingTimeInterval(10)) == "one")
        #expect(throttle.accept("one", at: t0.addingTimeInterval(11)) == "one")
        // Repeating the same value doesn't restart the interval.
        #expect(throttle.publishedAt == t0)
        #expect(!throttle.isPending(nil, at: t0.addingTimeInterval(1)))
    }

    @Test func resetStartsFresh() {
        var throttle = ActivityUpdateThrottle<String>(minimumInterval: 4)
        _ = throttle.accept("old recording", at: t0)
        throttle.reset()
        #expect(throttle.published == nil)
        #expect(throttle.accept("new recording", at: t0.addingTimeInterval(1)) == "new recording")
    }

    /// A minute of words arriving every 300 ms: the line changes on screen at most every
    /// 4 s, and the timer alone causes no updates.
    @MainActor
    @Test func theFeedStaysWithinTheUpdateBudget() {
        let feed = RecordingActivityFeed()
        var words: [String] = []
        var lastShown: String?
        var changes: [TimeInterval] = []
        for tick in 0..<60 {
            let now = t0.addingTimeInterval(TimeInterval(tick))
            // Several new words per second.
            words.append(contentsOf: ["w\(tick)a", "w\(tick)b", "w\(tick)c"])
            feed.apply(
                title: "Weekly sync",
                elapsed: TimeInterval(tick),
                isPaused: false,
                latestLine: .init(text: words.suffix(12).joined(separator: " "), isLocal: tick % 10 < 5),
                warning: nil,
                transcriptNotice: nil,
                now: now
            )
            let shown = feed.state?.lastLine?.text
            if shown != lastShown {
                changes.append(TimeInterval(tick))
                lastShown = shown
            }
        }
        let gaps = zip(changes.dropFirst(), changes).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= RecordingActivityFeed.lineInterval })
        #expect(changes.count == 15)
        // Every state change is a line change: the ticking timer never costs an update.
        #expect(feed.updateCount == changes.count)
    }

    @MainActor
    @Test func theFeedMapsPauseAndWarningsAtOnce() {
        let feed = RecordingActivityFeed()
        feed.apply(title: "", elapsed: 10, isPaused: false, latestLine: nil, warning: nil, transcriptNotice: nil, now: t0)
        #expect(feed.state?.title == RecordingActivityState.untitled)
        #expect(feed.state?.lastLine == nil)
        // Pause and warnings aren't throttled.
        feed.apply(title: "Sync", elapsed: 11, isPaused: true, latestLine: nil,
                   warning: "Your microphone isn't picking up any sound.", transcriptNotice: nil,
                   now: t0.addingTimeInterval(1))
        #expect(feed.state?.isPaused == true)
        #expect(feed.state?.title == "Sync")
        #expect(feed.state?.warning == "Your microphone isn't picking up any sound.")
        feed.reset()
        #expect(feed.state == nil)
        #expect(feed.updateCount == 0)
    }
}

// MARK: - Meeting detected

@Suite("Menu bar Live Activity: meeting detected")
struct MeetingDetectedActivityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func readsLikeTheCallThatStarted() {
        let zoom = MeetingDetectedActivityState(meetingName: "Zoom", appName: "Zoom", bundleID: "us.zoom.xos", detectedAt: t0)
        #expect(zoom.headline == "Zoom call started")
        #expect(zoom.neverTitle == "Never for Zoom")
        #expect(zoom.subtitle == "Record it and take notes?")
        // A web meeting: "Never" applies to the browser.
        let meet = MeetingDetectedActivityState(
            meetingName: "Google Meet", appName: "Google Chrome", bundleID: "com.google.Chrome",
            calendarTitle: "  Weekly sync ", detectedAt: t0
        )
        #expect(meet.headline == "Google Meet call started")
        #expect(meet.neverTitle == "Never for Google Chrome")
        #expect(meet.subtitle == "Weekly sync")
        #expect(MeetingDetectedActivityState(meetingName: "Zoom", appName: "Zoom", bundleID: "z", calendarTitle: " ", detectedAt: t0).calendarTitle == nil)
    }

    @Test func endsByItselfAfterAboutTwoMinutes() {
        let state = MeetingDetectedActivityState(meetingName: "Zoom", appName: "Zoom", bundleID: "us.zoom.xos", detectedAt: t0)
        #expect(MeetingDetectedActivityState.lifetime == 120)
        #expect(state.endsAt == t0.addingTimeInterval(120))
        #expect(state.remaining(at: t0.addingTimeInterval(30)) == 90)
        #expect(!state.isExpired(at: t0.addingTimeInterval(119)))
        #expect(state.isExpired(at: t0.addingTimeInterval(120)))
        #expect(state.remaining(at: t0.addingTimeInterval(500)) == 0)
    }

    @Test func dropsFromTheIconAndStaysOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 332, height: 140)
        let icon = NSRect(x: 1200, y: 875, width: 30, height: 24)
        let origin = MenuBarAnchoredLayout.origin(size: size, anchor: icon, visibleFrame: screen)
        #expect(origin.x + size.width / 2 == icon.midX)
        #expect(origin.y + size.height == icon.minY - MenuBarAnchoredLayout.gap)
        // An icon near the right edge: the prompt is pulled back inside the screen.
        let edge = MenuBarAnchoredLayout.origin(size: size, anchor: NSRect(x: 1420, y: 875, width: 20, height: 24), visibleFrame: screen)
        #expect(edge.x + size.width <= screen.maxX - MenuBarAnchoredLayout.margin)
    }

    @Test func anIconInTheOverflowIsNotAnAnchor() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        #expect(MenuBarAnchoredLayout.isOnScreen(NSRect(x: 1200, y: 876, width: 30, height: 24), screens: screens))
        #expect(!MenuBarAnchoredLayout.isOnScreen(NSRect(x: -200, y: 876, width: 30, height: 24), screens: screens))
        #expect(!MenuBarAnchoredLayout.isOnScreen(NSRect(x: 1200, y: 876, width: 0, height: 24), screens: screens))
    }
}
