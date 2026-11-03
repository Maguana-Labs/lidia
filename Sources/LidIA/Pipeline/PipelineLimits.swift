import Foundation

/// Hard bounds on post-meeting processing, so a meeting always ends
/// `.complete` or `.failed` instead of sitting in `.processing`.
///
/// Background: a 19-minute meeting on Apple Intelligence (4K context) stayed
/// "processing" for over an hour at 100% CPU. The LLM cleanup pass had grown the
/// transcript 3× (a runaway answer), the summary then needed dozens of small
/// map calls, and every streamed snapshot was diffed in O(n). Each cause is
/// fixed on its own; these limits are the backstop.
enum PipelineLimits {
    /// Most map (condense) calls one summary may make. Above this the parts are
    /// made bigger by truncating each one (with a warning) rather than making
    /// more calls; see `MapReduceSummarizer.condenseToFit`.
    static let maxMapParts = 24

    /// Overall time allowed for the summary step: 10 minutes plus 20 seconds
    /// per 1,000 transcript tokens, at most 40 minutes.
    static func summaryTimeout(transcriptTokens: Int) -> TimeInterval {
        min(40 * 60, 10 * 60 + Double(transcriptTokens) / 1000 * 20)
    }

    /// Small structured steps (facts, destinations, notes' action items).
    static let auxiliaryTimeout: TimeInterval = 180
}

/// Thrown when a pipeline step runs past its deadline.
struct PipelineTimeoutError: LocalizedError, Equatable {
    let step: String
    let seconds: TimeInterval

    var errorDescription: String? {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return String(localized: "The \(step) took longer than \(minutes) minutes and was stopped. Your transcript is saved; try Regenerate, or pick a faster model in Settings → AI.")
    }
}

/// Runs `operation` and returns its result, or throws `PipelineTimeoutError`
/// once `seconds` pass. Returns at the deadline even if the operation ignores
/// cancellation: it is cancelled and its eventual result is dropped.
@MainActor
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    step: String,
    _ operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    let state = DeadlineState()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task { @MainActor in
                do {
                    let value = try await operation()
                    if state.claim() { continuation.resume(returning: value) }
                } catch {
                    if state.claim() { continuation.resume(throwing: error) }
                }
            }
            state.setWork(work)
            // Detached: an inherited actor (often the busy main actor) would
            // delay the timer, and a deadline that waits for the main actor
            // isn't a deadline.
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                if state.claim() {
                    work.cancel()
                    continuation.resume(throwing: PipelineTimeoutError(step: step, seconds: seconds))
                }
            }
        }
    } onCancel: {
        state.cancelWork()
    }
}

/// Shared state for `withDeadline`: resumes the continuation exactly once and
/// lets outer cancellation reach the work.
final class DeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var work: Task<Void, Never>?
    private var cancelled = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    func setWork(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            work = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancelWork() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return work
        }
        task?.cancel()
    }
}
