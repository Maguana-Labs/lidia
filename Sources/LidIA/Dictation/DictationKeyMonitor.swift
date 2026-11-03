import AppKit
import CoreGraphics
import os

/// Watches the keyboard system-wide with a Quartz event tap and reports
/// trigger-key presses, other keys and Esc. Needs Accessibility permission
/// (an active tap is what lets Esc be swallowed while dictating).
///
/// The tap runs on the main run loop, so the callback is on the main thread.
@MainActor
final class DictationKeyMonitor {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "DictationKeys")

    /// Returns whether to swallow the event.
    typealias Handler = @MainActor (DictationKeyStateMachine.Event) -> Bool

    var triggerKey: DictationTriggerKey
    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private var retainedSelf: Unmanaged<DictationKeyMonitor>?

    init(triggerKey: DictationTriggerKey, handler: @escaping Handler) {
        self.triggerKey = triggerKey
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    /// Installs the tap. Returns false without Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let unmanaged = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dictationTapCallback,
            userInfo: unmanaged.toOpaque()
        ) else {
            unmanaged.release()
            Self.logger.info("Event tap unavailable (Accessibility permission missing)")
            return false
        }
        retainedSelf = unmanaged
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        triggerDown = false
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        triggerDown = false
        retainedSelf?.release()
        retainedSelf = nil
    }

    // MARK: - Events

    /// Device-dependent bits that say which side's modifier is down.
    static func deviceMask(for key: DictationTriggerKey) -> UInt64 {
        switch key {
        case .rightOption: 0x40      // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10     // NX_DEVICERCMDKEYMASK
        case .rightControl: 0x2000   // NX_DEVICERCTLKEYMASK
        case .fn: 0x80_0000          // NX_SECONDARYFNMASK
        }
    }

    private static let modifierMask: UInt64 = 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000 | 0x0080_0000

    /// The parts of a CGEvent the monitor looks at (CGEvent itself isn't Sendable).
    struct KeyEventInfo: Sendable {
        var type: CGEventType
        var flags: UInt64
        var keyCode: UInt16
        var isSynthetic: Bool

        init(type: CGEventType, event: CGEvent) {
            self.type = type
            flags = event.flags.rawValue
            keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            isSynthetic = event.getIntegerValueField(.eventSourceUserData) == DictationInserter.syntheticEventTag
        }

        init(type: CGEventType, flags: UInt64, keyCode: UInt16) {
            self.type = type
            self.flags = flags
            self.keyCode = keyCode
            isSynthetic = false
        }
    }

    /// Returns whether to swallow the event. Internal for tests.
    func handle(_ info: KeyEventInfo) -> Bool {
        let type = info.type
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            break
        }
        if info.isSynthetic { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let flags = info.flags
        let keyCode = info.keyCode

        switch type {
        case .flagsChanged:
            let isTrigger = triggerKey.keyCodes.contains(keyCode)
            let nowDown = flags & Self.deviceMask(for: triggerKey) != 0
            if isTrigger, nowDown != triggerDown {
                if nowDown {
                    // Already holding ⌘ or ⇧: that's a shortcut in progress, not dictation.
                    let others = flags & Self.modifierMask & ~triggerKey.flagMask
                    guard others == 0 else { return false }
                }
                triggerDown = nowDown
                let swallow = handler(nowDown ? .triggerDown(now) : .triggerUp(now))
                // Fn alone opens the emoji picker / input source switcher; keep it ours.
                return swallow || triggerKey == .fn
            }
            if !isTrigger, triggerDown, flags & Self.modifierMask & ~triggerKey.flagMask != 0 {
                return handler(.otherKey(now))
            }
            return false
        case .keyDown:
            if keyCode == 53 { return handler(.escape(now)) }
            return handler(.otherKey(now))
        default:
            return false
        }
    }

    /// Delivers a scheduled deadline to the handler.
    func tick() {
        _ = handler(.tick(ProcessInfo.processInfo.systemUptime))
    }
}

/// C callback for the tap. Runs on the main thread (the tap's run loop).
private let dictationTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DictationKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let info = DictationKeyMonitor.KeyEventInfo(type: type, event: event)
    let swallow = MainActor.assumeIsolated { monitor.handle(info) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
