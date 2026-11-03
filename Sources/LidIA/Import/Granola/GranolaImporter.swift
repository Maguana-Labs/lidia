import Foundation
import os
import SwiftData

// MARK: - Store

/// One Granola meeting, fully fetched, ready to write.
struct GranolaImportRecord: Equatable, Sendable {
    var granolaID: String
    var title: String
    var date: Date
    var attendees: [String]
    var summary: String
    var notes: String
    var transcript: String
}

/// Writes imported meetings on its own background context.
///
/// Only ever reads or changes meetings whose `externalSourceID` starts with
/// "granola:". Meetings made in LidIA are never fetched, let alone touched.
@ModelActor
actor GranolaImportStore {
    static let sourcePrefix = "granola:"
    static let folderName = "Granola"

    enum Outcome: Equatable, Sendable {
        case inserted
        case updated
        case unchanged
    }

    static func sourceID(for granolaID: String) -> String { sourcePrefix + granolaID }

    /// Meetings written since the last save, for Spotlight. Copied as values:
    /// an inserted model's identifier is temporary and stops resolving once the
    /// context saves, and reading a model through it then crashes.
    private var pendingIndex: [SpotlightIndexer.Entry] = []
    /// Off in tests, which have no Spotlight index of their own.
    private var indexesSpotlight = true
    private var indexEntries: @Sendable ([SpotlightIndexer.Entry]) -> Void = { SpotlightIndexer.indexEntries($0) }

    func setIndexesSpotlight(_ enabled: Bool) { indexesSpotlight = enabled }

    /// Replaces Spotlight in tests.
    func setSpotlightIndexer(_ indexer: @escaping @Sendable ([SpotlightIndexer.Entry]) -> Void) {
        indexesSpotlight = true
        indexEntries = indexer
    }

    /// Granola IDs already in the library. A meeting is only inserted once it
    /// is complete (transcript included), so presence means done.
    func importedGranolaIDs() throws -> Set<String> {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.externalSourceID != nil })
        let prefix = Self.sourcePrefix
        return Set(try modelContext.fetch(descriptor).compactMap { meeting in
            guard let source = meeting.externalSourceID, source.hasPrefix(prefix) else { return nil }
            return String(source.dropFirst(prefix.count))
        })
    }

    /// Inserts a new meeting or updates the one imported earlier.
    ///
    /// On update, anything the user changed in LidIA wins: an edited summary,
    /// a summary LidIA regenerated, notes they wrote, an edited transcript and
    /// the title stay as they are.
    @discardableResult
    func upsert(_ record: GranolaImportRecord) throws -> Outcome {
        let source = Self.sourceID(for: record.granolaID)
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.externalSourceID == source })
        descriptor.fetchLimit = 1

        guard let meeting = try modelContext.fetch(descriptor).first else {
            let meeting = Meeting(
                title: record.title,
                date: record.date,
                refinedTranscript: record.transcript,
                summary: record.summary,
                status: .complete,
                calendarAttendees: record.attendees.isEmpty ? nil : record.attendees,
                notes: record.notes,
                folder: Self.folderName
            )
            meeting.externalSourceID = source
            modelContext.insert(meeting)
            pendingIndex.append(SpotlightIndexer.Entry(meeting))
            return .inserted
        }

        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Meeting, T>, _ value: T) {
            guard meeting[keyPath: keyPath] != value else { return }
            meeting[keyPath: keyPath] = value
            changed = true
        }

        set(\.date, record.date)
        if meeting.title.trimmingCharacters(in: .whitespaces).isEmpty, !record.title.isEmpty {
            set(\.title, record.title)
        }
        if !record.attendees.isEmpty {
            set(\.calendarAttendees, record.attendees)
        }
        let userOwnsSummary = meeting.userEditedSummary != nil || meeting.structuredSummary != nil
        if !userOwnsSummary, !record.summary.isEmpty {
            set(\.summary, record.summary)
        }
        if meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !record.notes.isEmpty {
            set(\.notes, record.notes)
        }
        if meeting.userEditedTranscript == nil, !record.transcript.isEmpty {
            set(\.refinedTranscript, record.transcript)
        }
        guard changed else { return .unchanged }
        pendingIndex.append(SpotlightIndexer.Entry(meeting))
        return .updated
    }

    /// Saves and adds what was written to Spotlight.
    func save() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
        let entries = pendingIndex
        pendingIndex.removeAll()
        guard indexesSpotlight else { return }
        indexEntries(entries)
    }
}

// MARK: - Importer

enum GranolaImportProgress: Equatable, Sendable {
    case connecting
    case listing(found: Int, total: Int?)
    case importing(done: Int, total: Int, title: String, alreadyImported: Int)
}

struct GranolaImportSummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        var title: String
        var reason: String
    }

    var found = 0
    var imported = 0
    var updated = 0
    /// Already imported, unchanged, or not ready yet in Granola.
    var skipped = 0
    /// Of `skipped`: meetings Granola is still processing or that haven't happened.
    var notReady = 0
    var failures: [Failure] = []
    var cancelled = false

    var failed: Int { failures.count }
}

/// Pulls meetings from Granola's MCP server into the library. No AI runs on them.
///
/// Resumable: meetings are written only once complete, saved every
/// `saveEvery`, and a re-run skips the ones already in the library unless
/// `refreshExisting` is set.
struct GranolaImporter: Sendable {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "GranolaImporter")

    let client: GranolaMCPClient
    let store: GranolaImportStore
    var saveEvery = 20
    var batchSize = 10

    func run(
        refreshExisting: Bool = false,
        progress: @escaping @Sendable (GranolaImportProgress) async -> Void
    ) async throws -> GranolaImportSummary {
        var summary = GranolaImportSummary()
        await progress(.connecting)
        try await client.connect()
        let listing = try await client.listAllMeetings { found, total in
            await progress(.listing(found: found, total: total))
        }
        summary.found = listing.count

        let already = try await store.importedGranolaIDs()
        // Newest first, so the meetings people look for first arrive first.
        let ordered = listing.sorted { ($0.meetingAt ?? .distantPast) > ($1.meetingAt ?? .distantPast) }
        let todo = refreshExisting ? ordered : ordered.filter { !already.contains($0.id) }
        let alreadyImported = listing.count - todo.count
        summary.skipped = alreadyImported

        var done = 0
        var unsaved = 0
        do {
            for start in stride(from: 0, to: todo.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(todo[start..<min(start + batchSize, todo.count)])
                let fetched = try await fetch(batch)
                for (listingItem, result) in zip(batch, fetched) {
                    done += 1
                    await progress(.importing(done: done, total: todo.count, title: listingItem.title, alreadyImported: alreadyImported))
                    try Task.checkCancellation()
                    switch result {
                    case .record(let record):
                        switch try await store.upsert(record) {
                        case .inserted: summary.imported += 1
                        case .updated: summary.updated += 1
                        case .unchanged: summary.skipped += 1
                        }
                        unsaved += 1
                    case .notReady:
                        summary.skipped += 1
                        summary.notReady += 1
                    case .failed(let reason):
                        summary.failures.append(.init(title: listingItem.title.isEmpty ? "Untitled meeting" : listingItem.title, reason: reason))
                    }
                    if unsaved >= saveEvery {
                        try await store.save()
                        unsaved = 0
                    }
                }
            }
        } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            summary.cancelled = true
        } catch {
            // Keep what was fetched before the error.
            try? await store.save()
            throw error
        }
        try await store.save()
        Self.logger.info("Granola import: \(summary.imported) new, \(summary.updated) updated, \(summary.skipped) skipped, \(summary.failed) failed")
        return summary
    }

    enum FetchResult: Equatable, Sendable {
        case record(GranolaImportRecord)
        case notReady
        case failed(String)
    }

    /// Details for the batch in one call, then transcripts in parallel
    /// (the client keeps at most three calls in flight).
    func fetch(_ batch: [GranolaMeetingListing]) async throws -> [FetchResult] {
        let details: [String: GranolaMeetingDetail]
        do {
            let fetched = try await client.getMeetings(ids: batch.map(\.id))
            details = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            if Self.isFatal(error) { throw error }
            return batch.map { _ in .failed(error.localizedDescription) }
        }

        return try await withThrowingTaskGroup(of: (Int, FetchResult).self) { group in
            for (index, item) in batch.enumerated() {
                let detail = details[item.id]
                group.addTask {
                    guard let detail else {
                        return (index, .failed("Granola didn't return this meeting."))
                    }
                    do {
                        // Always ask: only the transcript call says whether a missing
                        // transcript is gone for good or still being processed.
                        let transcript = try await client.fullTranscript(meetingID: item.id)
                        if let reason = transcript.unavailableReason, Self.isNotReady(reason) {
                            return (index, .notReady)
                        }
                        return (index, .record(Self.record(listing: item, detail: detail, transcript: transcript.text)))
                    } catch {
                        if Self.isFatal(error) { throw error }
                        return (index, .failed(error.localizedDescription))
                    }
                }
            }
            var results = [FetchResult](repeating: .failed("Not fetched."), count: batch.count)
            for try await (index, result) in group {
                results[index] = result
            }
            return results
        }
    }

    static func record(listing: GranolaMeetingListing, detail: GranolaMeetingDetail, transcript: String) -> GranolaImportRecord {
        let participants = detail.participants.isEmpty ? listing.participants : detail.participants
        var seen = Set<String>()
        let attendees = participants.compactMap(\.attendeeString).filter { seen.insert($0.lowercased()).inserted }
        let title = detail.title.isEmpty ? listing.title : detail.title
        return GranolaImportRecord(
            granolaID: listing.id,
            title: title,
            date: detail.meetingAt ?? listing.meetingAt ?? Date(),
            attendees: attendees,
            summary: detail.summary,
            notes: detail.privateNotes,
            transcript: transcript
        )
    }

    /// Granola hasn't finished with these; a later run picks them up.
    static func isNotReady(_ reason: String) -> Bool {
        reason == "transcript_pending" || reason == "not_happened_yet"
    }

    /// Errors that mean every further call would fail too.
    static func isFatal(_ error: Error) -> Bool {
        if error is CancellationError || error is GranolaAuthError { return true }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled || urlError.code == .notConnectedToInternet
                || urlError.code == .networkConnectionLost || urlError.code == .cannotFindHost
                || urlError.code == .dnsLookupFailed || urlError.code == .timedOut
        }
        if let mcp = error as? GranolaMCPError {
            switch mcp {
            case .rateLimited, .toolMissing: return true
            case .http(let status, _): return status >= 500
            default: return false
            }
        }
        return false
    }
}
