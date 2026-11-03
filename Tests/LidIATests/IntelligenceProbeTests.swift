import Foundation
import SwiftData
import Testing
@testable import LidIA

/// Prints what the on-device suggestions find in a COPY of a real library.
/// Off unless `LIDIA_INTEL_PROBE_STORE=<path to a copied LidIA.store>` is set
/// (the copy is migrated in place, so never point it at the real library).
@Suite struct IntelligenceProbeTests {
    static var storePath: String? { ProcessInfo.processInfo.environment["LIDIA_INTEL_PROBE_STORE"] }

    @MainActor
    @Test(.enabled(if: IntelligenceProbeTests.storePath != nil))
    func probeLibraryCopy() throws {
        let url = URL(fileURLWithPath: try #require(Self.storePath))
        #expect(url.path != LibraryLocation.storeURL.path)
        let schema = Schema(versionedSchema: AppSchema.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        let userName = ProcessInfo.processInfo.environment["LIDIA_PROBE_USER"] ?? "Alex Moreno"
        MeetingAttendeeContext.currentUserName = userName

        let signals = meetings.filter { $0.status != .recording }.map { MeetingSignals($0) }
        let ctx = ProjectSuggester.Context.build(signals)
        print("PROBE home companies:", ctx.homeCompanies, "domains:", ctx.homeDomains)

        let clusters = ProjectSuggester.clusters(signals, context: ctx)
        for cluster in clusters {
            print("PROBE cluster \(cluster.name) n=\(cluster.meetingIDs.count) conf=\(String(format: "%.2f", cluster.confidence)) \(cluster.reasons)")
        }

        // Pretend the user accepted the top cluster, then score the rest.
        if let top = clusters.first {
            let ids = Set(top.meetingIDs)
            let half = Set(top.meetingIDs.prefix(top.meetingIDs.count / 2 + 1))
            let assigned = signals.map { signal -> MeetingSignals in
                var copy = signal
                if half.contains(signal.id) { copy.project = top.name }
                return copy
            }
            let suggestions = ProjectSuggester.suggestions(for: assigned, context: ctx)
            for signal in assigned where signal.project == nil {
                if let s = suggestions[signal.id] {
                    print("PROBE suggest '\(signal.title)' → \(s.project) conf=\(String(format: "%.3f", s.confidence)) auto=\(s.isAutoAssignable) inCluster=\(ids.contains(signal.id)) \(s.reasons)")
                }
            }
        }

        var mentions: [UUID: String] = [:]
        for m in meetings { mentions[m.id] = String(m.refinedTranscript.prefix(20_000)) }
        let drafts = FollowUpPlanner.drafts(signals, handled: [], senderName: userName, transcriptMentions: mentions)
        for draft in drafts {
            print("PROBE followup \(draft.primary?.name ?? "-") <\(draft.primary?.email ?? "")> · \(draft.subject) \(draft.reasons)")
            print(draft.body.split(separator: "\n").map { "PROBE   " + $0 }.joined(separator: "\n"))
        }
        let context2 = ProjectSuggester.Context.build(signals)
        for signal in signals.prefix(12) {
            let why = FollowUpPlanner.ineligibility(signal, among: signals, context: context2, handled: [])
            print("PROBE eligibility '\(signal.title)' \(signal.date.formatted(date: .abbreviated, time: .omitted)): \(why.map { "\($0)" } ?? "ELIGIBLE")")
        }

        let documents = meetings.map { m in
            VocabularyMiner.Document(
                id: m.id,
                written: [m.title, m.userEditedSummary ?? m.summary, m.notes, (m.calendarAttendees ?? []).joined(separator: ", ")].joined(separator: "\n"),
                heard: m.refinedTranscript,
                title: m.title
            )
        }
        let exclude = Set(userName.split(separator: " ").map(String.init))
        for suggestion in VocabularyMiner.mine(documents, exclude: exclude, limit: 20) {
            print("PROBE vocab \(suggestion.heardAs ?? "—") → \(suggestion.term) [\(suggestion.kind)] heard=\(suggestion.heardCount) meetings=\(suggestion.meetingCount) variants=\(suggestion.variants) score=\(suggestion.score)")
        }
    }
}
