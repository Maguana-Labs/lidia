import Foundation
import Observation
import os

/// One finished dictation.
struct DictationRecord: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var date: Date
    /// What was inserted (after cleanup and polish).
    var text: String
    /// What the recogniser heard.
    var rawText: String
    /// Bundle name of the app it went into ("Mail"), if known.
    var appName: String?
    /// How it was inserted: "accessibility", "paste", or why it wasn't.
    var outcome: String
    /// Key release to text inserted.
    var latencyMilliseconds: Int?
}

/// Recent dictations, kept only on this Mac in
/// `~/Library/Application Support/LidIA/Dictation/history.json`.
@MainActor
@Observable
final class DictationHistory {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "DictationHistory")

    private(set) var records: [DictationRecord] = []
    @ObservationIgnored private let fileURL: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LidIA/Dictation/history.json")
    }

    init(fileURL: URL = DictationHistory.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    func add(_ record: DictationRecord, limit: Int) {
        records.insert(record, at: 0)
        trim(to: limit)
        save()
    }

    func trim(to limit: Int) {
        if records.count > max(limit, 0) {
            records.removeLast(records.count - max(limit, 0))
            save()
        }
    }

    func remove(_ id: DictationRecord.ID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([DictationRecord].self, from: data)
        } catch {
            Self.logger.error("Couldn't read dictation history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL, options: [.atomic])
        } catch {
            Self.logger.error("Couldn't save dictation history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
