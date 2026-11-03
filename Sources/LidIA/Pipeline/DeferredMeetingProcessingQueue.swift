import Foundation

/// Persistent FIFO of meeting IDs waiting for (re)processing. Drained by
/// `PostProcessingService.drainQueuedMeetings` every 60 s and at launch.
///
/// Stable API used by other workstreams: `shared`, `enqueue(_:)`, `remove(_:)`, `all()`, `clear()`.
actor DeferredMeetingProcessingQueue {
    static let shared = DeferredMeetingProcessingQueue()

    private let defaults: UserDefaults
    private let defaultsKey: String

    init(defaults: UserDefaults = .standard, defaultsKey: String = "meetingProcessingQueue.v1") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    func enqueue(_ meetingID: UUID) {
        var queue = loadQueue()
        if !queue.contains(meetingID) {
            queue.append(meetingID)
            saveQueue(queue)
        }
    }

    func remove(_ meetingID: UUID) {
        var queue = loadQueue()
        queue.removeAll { $0 == meetingID }
        saveQueue(queue)
    }

    func all() -> [UUID] {
        loadQueue()
    }

    func clear() {
        saveQueue([])
    }

    private func loadQueue() -> [UUID] {
        guard let data = defaults.data(forKey: defaultsKey),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return ids
    }

    private func saveQueue(_ queue: [UUID]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
