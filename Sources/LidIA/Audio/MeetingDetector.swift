import AppKit
import CoreAudio
import CoreGraphics
import Observation
import os

/// Detects active calls/meetings by monitoring system-level audio: when both the
/// microphone (input) and speaker (output) are active simultaneously, a two-way
/// conversation is happening. App-agnostic — works with any meeting app, phone call,
/// or browser-based meeting.
///
/// During active recording, also polls for process/window presence of the detected
/// app since LidIA's own mic usage masks the CoreAudio idle signal.
@MainActor
@Observable
final class MeetingDetector {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "MeetingDetector")

    /// The detected call/meeting context, or nil if no call is active.
    var detectedApp: DetectedApp?
    /// User dismissed the banner for the current detection.
    var isDismissed = false
    /// Fires when a detected call/meeting becomes inactive.
    var meetingAppBecameInactive = false

    struct DetectedApp: Sendable {
        let name: String
        let bundleID: String
        let pid: pid_t
    }

    private var isMonitoring = false
    private var inputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var inputDeviceID: AudioObjectID = 0
    private var outputDeviceID: AudioObjectID = 0

    /// Tracks whether mic (input) and speaker (output) are active.
    private var micActive = false
    private var outputActive = false
    /// Grace period to avoid triggering on momentary mic activations (Siri, dictation).
    private var confirmationTask: Task<Void, Never>?

    /// Task that polls whether the tracked meeting app still has visible windows.
    private var activeMonitorTask: Task<Void, Never>?
    /// The app we are actively tracking during a recording.
    private var trackedApp: DetectedApp?

    /// LidIA's own bundle ID — excluded from detection.
    private static let selfBundleID = Bundle.main.bundleIdentifier ?? "io.lidia.app"

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Get default input device (mic)
        inputDeviceID = getDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        // Get default output device (speaker)
        outputDeviceID = getDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)

        guard inputDeviceID != 0 else {
            Self.logger.error("Could not get default input device")
            isMonitoring = false
            return
        }
        guard outputDeviceID != 0 else {
            Self.logger.error("Could not get default output device")
            isMonitoring = false
            return
        }

        // Listen for mic state changes
        inputListenerBlock = addIsRunningListener(deviceID: inputDeviceID) { [weak self] isRunning in
            Task { @MainActor [weak self] in
                self?.micActive = isRunning
                self?.evaluateCallState()
            }
        }

        // Listen for speaker state changes
        outputListenerBlock = addIsRunningListener(deviceID: outputDeviceID) { [weak self] isRunning in
            Task { @MainActor [weak self] in
                self?.outputActive = isRunning
                self?.evaluateCallState()
            }
        }

        Self.logger.info("Monitoring started — input device \(self.inputDeviceID), output device \(self.outputDeviceID)")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        detectedApp = nil
        isDismissed = false
        micActive = false
        outputActive = false
        confirmationTask?.cancel()
        confirmationTask = nil

        removeIsRunningListener(deviceID: inputDeviceID, block: inputListenerBlock)
        inputListenerBlock = nil
        removeIsRunningListener(deviceID: outputDeviceID, block: outputListenerBlock)
        outputListenerBlock = nil

        Self.logger.info("Monitoring stopped")
    }

    /// Dismiss the current detection (user closed the banner).
    func dismiss() {
        isDismissed = true
    }

    // MARK: - Core Detection Logic

    /// Title of a calendar meeting happening now (with others invited or a call link), if
    /// any. Set by the app; lets a browser or unknown app on the mic count as a meeting.
    var calendarMeetingNow: @MainActor () -> String? = { nil }

    /// Stops offering to record meetings in this app ("Never for this app").
    func neverDetect(bundleID: String) {
        MeetingAppRules.ignore(bundleID)
        Self.logger.info("Meeting detection off for \(bundleID, privacy: .public)")
        dismiss()
    }

    /// Evaluates whether a call is happening: mic + speaker both active = two-way conversation.
    private func evaluateCallState() {
        if micActive && outputActive {
            // Both active — maybe a call. Wait briefly to filter out transient activations,
            // then check which app it is; keep checking while the mic stays on, because a
            // meeting app can join after something else (an assistant) opened the mic.
            if detectedApp == nil && !isDismissed && confirmationTask == nil {
                confirmationTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    while !Task.isCancelled, self.micActive, self.outputActive, self.detectedApp == nil, !self.isDismissed {
                        if let app = self.identifyMeeting() {
                            self.detectedApp = app
                            Self.logger.info("Meeting detected: \(app.name, privacy: .public) (\(app.bundleID, privacy: .public))")
                            break
                        }
                        try? await Task.sleep(for: .seconds(5))
                    }
                    self.confirmationTask = nil
                }
            }
        } else if !micActive {
            // Mic went idle — call likely ended
            confirmationTask?.cancel()
            confirmationTask = nil
            if detectedApp != nil {
                meetingAppBecameInactive = true
                Self.logger.info("Call ended (mic idle)")
            }
            detectedApp = nil
            isDismissed = false
        }
    }

    /// The meeting on the mic, by `MeetingAppRules`, or nil when the mic is used by
    /// something that isn't a meeting (an AI assistant, dictation, a recorder).
    private func identifyMeeting() -> DetectedApp? {
        var micApps = Self.bundleIDsUsingMicrophone()
        if micApps.isEmpty, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            // The process list isn't available: fall back to the app in front.
            micApps = [front]
        }
        let browsersOnMic = Set(micApps.map(MeetingAppRules.owningApp)).filter { MeetingAppRules.browsers[$0] != nil }
        let detection = MeetingAppRules.detect(
            micApps: micApps,
            windowTitles: Self.windowTitles(of: browsersOnMic),
            calendarMeeting: calendarMeetingNow(),
            ignored: MeetingAppRules.ignoredApps(),
            selfBundleID: Self.selfBundleID
        )
        guard let detection else {
            Self.logger.debug("Mic in use by \(micApps.joined(separator: ", "), privacy: .public): not a meeting")
            return nil
        }
        let pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == detection.bundleID }?.processIdentifier ?? 0
        return DetectedApp(name: detection.name, bundleID: detection.bundleID, pid: pid)
    }

    /// Bundle IDs of the processes recording from any input right now (macOS 14.2+
    /// CoreAudio process objects). Helpers keep their own IDs ("com.google.Chrome.helper").
    private static func bundleIDsUsingMicrophone() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else {
            return []
        }
        return processes.compactMap { process -> String? in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var idAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &idAddress, 0, nil, &idSize, &bundleID) == noErr,
                  let value = bundleID?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
            return value
        }
    }

    /// On-screen window titles of these apps (empty without Screen Recording permission).
    private static func windowTitles(of bundleIDs: Set<String>) -> [String: [String]] {
        guard !bundleIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return [:]
        }
        var pidToBundle: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, bundleIDs.contains(id) { pidToBundle[app.processIdentifier] = id }
        }
        var titles: [String: [String]] = [:]
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID] as? pid_t, let id = pidToBundle[pid],
                  let name = window[kCGWindowName] as? String, !name.isEmpty else { continue }
            titles[id, default: []].append(name)
        }
        return titles
    }

    /// Meeting apps and browsers, for following a recording's app until it closes.
    private static var knownMeetingApps: Set<String> {
        Set(MeetingAppRules.nativeMeetingApps.keys).union(MeetingAppRules.browsers.keys)
    }

    private func findKnownMeetingApp() -> DetectedApp? {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Self.selfBundleID,
                  Self.knownMeetingApps.contains(bundleID) else { continue }
            let name = app.localizedName ?? bundleID
            return DetectedApp(name: name, bundleID: bundleID, pid: app.processIdentifier)
        }
        return nil
    }

    // MARK: - CoreAudio Helpers

    private func getDefaultDevice(selector: AudioObjectPropertySelector) -> AudioObjectID {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private func addIsRunningListener(
        deviceID: AudioObjectID,
        handler: @escaping @Sendable (Bool) -> Void
    ) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isRunning)
            handler(isRunning != 0)
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        return block
    }

    private func removeIsRunningListener(deviceID: AudioObjectID, block: AudioObjectPropertyListenerBlock?) {
        guard let block else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
    }

    // MARK: - Active Window/Process Monitoring (for use during recording)

    /// Begin polling for the tracked app's window/process presence.
    /// Call this when a recording starts so that we can detect the meeting ending
    /// even though LidIA's own mic usage masks the CoreAudio idle signal.
    func startActiveMonitoring() {
        trackedApp = detectedApp ?? findKnownMeetingApp()

        guard let tracked = trackedApp else {
            Self.logger.info("No app to track — active monitoring not started")
            return
        }

        Self.logger.info("Active monitoring started for \(tracked.name) (PID \(tracked.pid))")

        activeMonitorTask?.cancel()
        activeMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }

                if let freshApp = self.findKnownMeetingApp(), freshApp.bundleID != tracked.bundleID {
                    Self.logger.info("App changed to \(freshApp.name) — updating tracker")
                    self.trackedApp = freshApp
                    continue
                }

                if !self.isAppStillActive(tracked) {
                    Self.logger.info("\(tracked.name) no longer active — signalling inactive")
                    self.meetingAppBecameInactive = true
                    self.detectedApp = nil
                    return
                }
            }
        }
    }

    /// Stop active window/process monitoring (called when recording stops).
    func stopActiveMonitoring() {
        activeMonitorTask?.cancel()
        activeMonitorTask = nil
        trackedApp = nil
    }

    /// Check if the given app is still running AND has at least one visible on-screen window.
    private func isAppStillActive(_ app: DetectedApp) -> Bool {
        guard app.pid != 0 else { return false }

        let runningApps = NSWorkspace.shared.runningApplications
        let isRunning = runningApps.contains { $0.processIdentifier == app.pid && !$0.isTerminated }
        guard isRunning else {
            Self.logger.debug("\(app.name) process (PID \(app.pid)) no longer running")
            return false
        }

        // For browsers, just check process is running — can't distinguish meeting tabs
        let browserBundleIDs: Set<String> = [
            "com.google.Chrome", "com.apple.Safari", "com.brave.Browser",
            "org.mozilla.firefox", "com.microsoft.edgemac",
        ]
        if browserBundleIDs.contains(app.bundleID) {
            return true
        }

        // For native apps, check for visible windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return true
        }

        let hasVisibleWindow = windowList.contains { info in
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == app.pid else { return false }
            if let bounds = info[kCGWindowBounds] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                if width < 100 || height < 100 { return false }
            }
            return true
        }

        if !hasVisibleWindow {
            Self.logger.debug("\(app.name) has no visible windows")
        }
        return hasVisibleWindow
    }
}
