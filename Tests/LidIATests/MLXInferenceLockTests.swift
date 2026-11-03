import Foundation
import Testing
@testable import LidIA

/// Counts how many "generations" overlap.
actor OverlapProbe {
    private(set) var running = 0
    private(set) var maxRunning = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) {
        running += 1
        maxRunning = max(maxRunning, running)
        order.append(id)
    }

    func leave() { running -= 1 }
}

@Suite("MLX inference lock")
struct MLXInferenceLockTests {
    /// Stands in for an MLX generation: encodes GPU work for a while.
    private func fakeGeneration(_ id: Int, probe: OverlapProbe, lock: MLXInferenceLock) async throws -> Int {
        try await lock.run {
            await probe.enter(id)
            try await Task.sleep(for: .milliseconds(30))
            await probe.leave()
            return id
        }
    }

    @Test func concurrentGenerationsRunOneAtATime() async throws {
        let lock = MLXInferenceLock()
        let probe = OverlapProbe()
        // A summary, a prep brief and a chat answer all start at once.
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 0..<6 {
                group.addTask { try await fakeGeneration(id, probe: probe, lock: lock) }
            }
            var done: [Int] = []
            for try await id in group { done.append(id) }
            return done
        }
        #expect(results.sorted() == Array(0..<6))
        #expect(await probe.maxRunning == 1)
    }

    @Test func aFailedGenerationReleasesTheLock() async throws {
        let lock = MLXInferenceLock()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await lock.run { () async throws -> Int in throw Boom() }
        }
        let value = try await lock.run { 7 }
        #expect(value == 7)
    }

    @Test func theAppUsesOneSharedLock() {
        #expect(MLXInferenceLock.shared === MLXInferenceLock.shared)
    }
}
