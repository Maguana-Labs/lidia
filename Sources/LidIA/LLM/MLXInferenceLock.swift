import Foundation

/// Process-wide lock around MLX inference.
///
/// MLX encodes work into a shared Metal command buffer per stream. Two
/// generations evaluating at once (a meeting summary and a prep brief, or a
/// chat answer) crash the app with `MTLReleaseAssertionFailure` in
/// `setCurrentCommandEncoder:` (seen 2026-11-03). `ModelContainer` only
/// serialises calls on the same container, so every MLX generation in the app
/// runs through this lock: one at a time, in arrival order. Cloud providers and
/// Apple Intelligence don't use it and may run in parallel.
actor MLXInferenceLock {
    static let shared = MLXInferenceLock()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` while holding the lock.
    nonisolated func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the lock straight to the next waiter (busy stays true).
            waiters.removeFirst().resume()
        }
    }
}
