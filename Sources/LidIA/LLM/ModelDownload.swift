import Foundation

// MARK: - Download status

/// Byte-level state of a model download, for progress UI.
struct ModelDownloadStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case downloading
        case verifying
        /// Stopped by the user; partial files are kept and the next
        /// download resumes from them.
        case paused
        case failed(String)
        case finished
    }

    var modelID: String
    var phase: Phase
    var bytesDone: Int64
    var bytesTotal: Int64
    var bytesPerSecond: Double
    var secondsRemaining: TimeInterval?

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    var isActive: Bool {
        switch phase {
        case .preparing, .downloading, .verifying: return true
        case .paused, .failed, .finished: return false
        }
    }

    /// "1.2 GB of 5.2 GB · 18 MB/s · 4 min left"
    var progressDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var parts = ["\(formatter.string(fromByteCount: bytesDone)) of \(formatter.string(fromByteCount: bytesTotal))"]
        if bytesPerSecond > 0 {
            parts.append("\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s")
        }
        if let secondsRemaining, secondsRemaining.isFinite {
            parts.append(Self.formatRemaining(secondsRemaining))
        }
        return parts.joined(separator: " · ")
    }

    static func formatRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60
        return "\(hours) h \(minutes % 60) min left"
    }
}

// MARK: - Errors

enum ModelDownloadError: LocalizedError, Equatable {
    case insufficientDisk(needed: Int64, available: Int64)
    case insufficientMemory(model: String, requiredGB: Int)
    case verificationFailed(model: String)
    case invalidModelID(String)
    case incomplete(model: String)

    var errorDescription: String? {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        switch self {
        case .insufficientDisk(let needed, let available):
            return "Not enough disk space: this download needs \(formatter.string(fromByteCount: needed)) free and \(formatter.string(fromByteCount: available)) is available."
        case .insufficientMemory(let model, let requiredGB):
            return "\(model) needs at least \(requiredGB) GB of memory. Pick the model recommended for this Mac."
        case .verificationFailed(let model):
            return "\(model) failed its integrity check twice. The damaged files were removed; try again later."
        case .invalidModelID(let id):
            return "'\(id)' isn't a valid model ID (expected organisation/name)."
        case .incomplete(let model):
            return "\(model) finished downloading but some files are missing. Try again."
        }
    }
}

/// Mutable state shared with `@MainActor @Sendable` callbacks.
@MainActor
final class MainActorBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Throughput

/// Smoothed transfer speed and time remaining.
struct ThroughputMeter: Sendable {
    /// Minimum time between samples, so bursts don't swing the estimate.
    var minimumInterval: TimeInterval = 0.5
    /// Weight of the newest sample in the moving average.
    var smoothing: Double = 0.3

    private var lastBytes: Int64?
    private var lastTime: Date?
    private(set) var bytesPerSecond: Double = 0

    init(minimumInterval: TimeInterval = 0.5, smoothing: Double = 0.3) {
        self.minimumInterval = minimumInterval
        self.smoothing = smoothing
    }

    /// Records progress; returns the smoothed speed and seconds remaining.
    mutating func record(bytesDone: Int64, bytesTotal: Int64, at time: Date = Date()) -> (bytesPerSecond: Double, secondsRemaining: TimeInterval?) {
        defer {
            if lastTime == nil || time.timeIntervalSince(lastTime!) >= minimumInterval {
                lastBytes = bytesDone
                lastTime = time
            }
        }
        if let lastBytes, let lastTime {
            let elapsed = time.timeIntervalSince(lastTime)
            if elapsed >= minimumInterval, bytesDone >= lastBytes {
                let instant = Double(bytesDone - lastBytes) / elapsed
                bytesPerSecond = bytesPerSecond == 0 ? instant : smoothing * instant + (1 - smoothing) * bytesPerSecond
            }
        }
        let remaining: TimeInterval? = bytesPerSecond > 0
            ? Double(max(0, bytesTotal - bytesDone)) / bytesPerSecond
            : nil
        return (bytesPerSecond, remaining)
    }
}
