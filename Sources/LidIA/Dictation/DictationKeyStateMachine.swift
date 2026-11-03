import Foundation

/// Turns trigger-key presses into dictation commands. Pure and clock-free:
/// every event carries its own time, so tests can drive it exactly.
///
/// Rules, for every activation mode:
/// - Any other key, or another modifier, pressed while the trigger is held is
///   a shortcut (⌥Space, ⌥N, ⌘⌥V…), so a dictation in progress is cancelled.
///   That is what keeps the dictation key from colliding with the voice
///   assistant's hotkey.
/// - Esc cancels whatever is happening and is swallowed.
///
/// `.holdOrDoubleTap` starts capturing on the first press, so nothing said in
/// the first few hundred milliseconds is lost. A press shorter than
/// `holdThreshold` is a tap: a second tap within `doubleTapWindow` locks
/// hands-free listening; otherwise the capture is thrown away.
struct DictationKeyStateMachine: Sendable {
    enum Event: Equatable, Sendable {
        case triggerDown(TimeInterval)
        case triggerUp(TimeInterval)
        /// Any other key or modifier went down.
        case otherKey(TimeInterval)
        case escape(TimeInterval)
        /// A scheduled deadline passed (see `Output.deadline`).
        case tick(TimeInterval)
    }

    enum Command: Equatable, Sendable {
        /// Start capturing audio (show the HUD once it is clearly dictation).
        case start
        /// Hands-free: keep listening after the key is released.
        case lock
        /// Stop, transcribe and insert.
        case finish
        /// Stop and discard.
        case cancel
    }

    struct Output: Equatable, Sendable {
        var commands: [Command] = []
        /// Swallow the key event so the frontmost app doesn't see it.
        var swallow = false
        /// Call back with `.tick` at this time (absolute, same clock as events).
        var deadline: TimeInterval?

        static let none = Output()
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Key down, capture running (hold modes).
        case pressed(since: TimeInterval)
        /// Released quickly; capture running; waiting for a second tap.
        case awaitingSecondTap(releasedAt: TimeInterval)
        /// First tap of a double-tap in `.doubleTap` mode (no capture yet).
        case firstTapDown(since: TimeInterval)
        case firstTapUp(releasedAt: TimeInterval)
        /// Hands-free; the key that locked it is still down.
        case lockedKeyDown
        /// Hands-free listening.
        case locked
        /// Finished/cancelled while the key was down: ignore its release.
        case waitingForRelease
    }

    var activation: DictationActivation
    /// Shorter presses are taps.
    var holdThreshold: TimeInterval = 0.3
    /// Max gap between the taps of a double-tap.
    var doubleTapWindow: TimeInterval = 0.4
    /// Hold mode: shorter presses are accidental and discarded.
    var minimumHold: TimeInterval = 0.15

    private(set) var phase: Phase = .idle

    init(activation: DictationActivation) {
        self.activation = activation
    }

    /// Whether audio is being captured right now.
    var isCapturing: Bool {
        switch phase {
        case .pressed, .awaitingSecondTap, .lockedKeyDown, .locked: true
        case .idle, .firstTapDown, .firstTapUp, .waitingForRelease: false
        }
    }

    var isLocked: Bool { phase == .locked || phase == .lockedKeyDown }

    /// Forget everything (for example after the controller cancelled on its own).
    mutating func reset() { phase = .idle }

    mutating func handle(_ event: Event) -> Output {
        if case .escape = event {
            // Only a running dictation owns Esc; otherwise the app gets it.
            let wasCapturing = isCapturing
            let keyDown: Bool
            switch phase {
            case .pressed, .firstTapDown, .lockedKeyDown: keyDown = true
            default: keyDown = false
            }
            if phase != .idle { phase = keyDown ? .waitingForRelease : .idle }
            return wasCapturing ? Output(commands: [.cancel], swallow: true) : .none
        }

        switch activation {
        case .holdOrDoubleTap: return handleHybrid(event)
        case .hold: return handleHold(event)
        case .doubleTap: return handleDoubleTap(event)
        }
    }

    // MARK: - Hold or double-tap

    private mutating func handleHybrid(_ event: Event) -> Output {
        switch (phase, event) {
        case (.idle, .triggerDown(let t)):
            phase = .pressed(since: t)
            return Output(commands: [.start])
        case (.pressed, .otherKey):
            phase = .waitingForRelease
            return Output(commands: [.cancel])
        case (.pressed(let since), .triggerUp(let t)):
            if t - since >= holdThreshold {
                phase = .idle
                return Output(commands: [.finish])
            }
            phase = .awaitingSecondTap(releasedAt: t)
            return Output(deadline: t + doubleTapWindow)
        case (.awaitingSecondTap(let releasedAt), .triggerDown(let t)):
            if t - releasedAt <= doubleTapWindow {
                phase = .lockedKeyDown
                return Output(commands: [.lock])
            }
            // Too late: the first tap was a stray; this press starts over.
            phase = .pressed(since: t)
            return Output(commands: [.cancel, .start])
        case (.awaitingSecondTap(let releasedAt), .tick(let t)):
            guard t - releasedAt >= doubleTapWindow else { return Output(deadline: releasedAt + doubleTapWindow) }
            phase = .idle
            return Output(commands: [.cancel])
        case (.awaitingSecondTap, .otherKey):
            phase = .idle
            return Output(commands: [.cancel])
        case (.lockedKeyDown, .triggerUp):
            phase = .locked
            return .none
        case (.locked, .triggerDown):
            phase = .waitingForRelease
            return Output(commands: [.finish])
        case (.waitingForRelease, .triggerUp):
            phase = .idle
            return .none
        default:
            return .none
        }
    }

    // MARK: - Hold

    private mutating func handleHold(_ event: Event) -> Output {
        switch (phase, event) {
        case (.idle, .triggerDown(let t)):
            phase = .pressed(since: t)
            return Output(commands: [.start])
        case (.pressed, .otherKey):
            phase = .waitingForRelease
            return Output(commands: [.cancel])
        case (.pressed(let since), .triggerUp(let t)):
            phase = .idle
            return Output(commands: [t - since >= minimumHold ? .finish : .cancel])
        case (.waitingForRelease, .triggerUp):
            phase = .idle
            return .none
        default:
            return .none
        }
    }

    // MARK: - Double-tap

    private mutating func handleDoubleTap(_ event: Event) -> Output {
        switch (phase, event) {
        case (.idle, .triggerDown(let t)):
            phase = .firstTapDown(since: t)
            return .none
        case (.firstTapDown, .otherKey):
            phase = .waitingForRelease
            return .none
        case (.firstTapDown(let since), .triggerUp(let t)):
            guard t - since < holdThreshold else {
                phase = .idle
                return .none
            }
            phase = .firstTapUp(releasedAt: t)
            return Output(deadline: t + doubleTapWindow)
        case (.firstTapUp(let releasedAt), .triggerDown(let t)):
            if t - releasedAt <= doubleTapWindow {
                phase = .lockedKeyDown
                return Output(commands: [.start, .lock])
            }
            phase = .firstTapDown(since: t)
            return .none
        case (.firstTapUp(let releasedAt), .tick(let t)):
            if t - releasedAt >= doubleTapWindow { phase = .idle }
            return .none
        case (.firstTapUp, .otherKey):
            phase = .idle
            return .none
        case (.lockedKeyDown, .triggerUp):
            phase = .locked
            return .none
        case (.locked, .triggerDown):
            phase = .waitingForRelease
            return Output(commands: [.finish])
        case (.waitingForRelease, .triggerUp):
            phase = .idle
            return .none
        default:
            return .none
        }
    }
}
