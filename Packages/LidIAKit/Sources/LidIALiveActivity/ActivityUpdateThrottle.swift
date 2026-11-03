import Foundation

/// Lets a fast-changing value (the live transcript's last line) through at most once
/// per `minimumInterval`, the way a Live Activity's update budget wants it. The first
/// value goes through at once; later changes wait until the interval has passed, and
/// until then the last published value stays on screen. Call `accept` on every tick:
/// a change that had to wait goes through on the first tick after the interval.
public struct ActivityUpdateThrottle<Value: Equatable & Sendable>: Sendable {
    public let minimumInterval: TimeInterval
    public private(set) var published: Value?
    public private(set) var publishedAt: Date?

    public init(minimumInterval: TimeInterval = 4) {
        self.minimumInterval = minimumInterval
    }

    /// The value to show now for `candidate`. A nil candidate keeps what's shown.
    public mutating func accept(_ candidate: Value?, at now: Date) -> Value? {
        guard let candidate, candidate != published else { return published }
        if let publishedAt, now.timeIntervalSince(publishedAt) < minimumInterval {
            return published
        }
        published = candidate
        publishedAt = now
        return candidate
    }

    /// Whether `candidate` differs from what's shown and is waiting for the interval.
    public func isPending(_ candidate: Value?, at now: Date) -> Bool {
        guard let candidate, candidate != published, let publishedAt else { return false }
        return now.timeIntervalSince(publishedAt) < minimumInterval
    }

    /// Forgets what was shown (a new recording starts fresh).
    public mutating func reset() {
        published = nil
        publishedAt = nil
    }
}
