import Foundation
import MLX
import SQLite3
import Testing
@testable import LidIA

/// Summary benchmark over real meetings (see docs/research/2026-11-summary-benchmark.md).
///
/// Skipped unless `LIDIA_BENCH=1`. Reads meetings from a COPY of the library
/// (never the live store), runs LidIA's real streaming summary path with each
/// model and writes one JSON line per (model, meeting) to `LIDIA_BENCH_OUT`.
/// Scoring against Granola's summaries happens outside Swift
/// (`scripts/benchmark/judge.py`), so transcripts never land in the repo.
///
/// Environment:
/// - `LIDIA_BENCH_DB`: path to the copied `LidIA.store` (opened read-only)
/// - `LIDIA_BENCH_MEETINGS`: comma-separated `Z_PK`s
/// - `LIDIA_BENCH_MODELS`: comma-separated MLX repo IDs and/or `apple`
/// - `LIDIA_BENCH_OUT`: output directory
/// - `LIDIA_BENCH_LABEL`: free-form run label (e.g. prompt version)
/// - `LIDIA_BENCH_FACTS`: `same` (default) or `apple` — client for the facts step
@MainActor
@Suite("Summary benchmark", .enabled(if: ProcessInfo.processInfo.environment["LIDIA_BENCH"] == "1"))
struct SummaryBenchmarkTests {
    struct BenchMeeting {
        let pk: Int
        let title: String
        let transcript: String
    }

    struct Record: Encodable {
        let label: String
        let model: String
        let meeting: Int
        let transcriptTokensEstimate: Int
        let parts: Int
        let timeToFirstToken: Double?
        let summaryTotal: Double
        let promptTokens: Int?
        let generatedTokens: Int?
        let generateTokensPerSecond: Double?
        let promptTokensPerSecond: Double?
        let markdown: String
        let factsSeconds: Double
        let factsTitle: String?
        let factsActionItems: [String]
        let nextSteps: [String]
        let error: String?
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @Test func runSummaryBenchmark() async throws {
        let dbPath = try #require(env["LIDIA_BENCH_DB"])
        let pks = (env["LIDIA_BENCH_MEETINGS"] ?? "").split(separator: ",").compactMap { Int($0) }
        let models = (env["LIDIA_BENCH_MODELS"] ?? "").split(separator: ",").map(String.init)
        let outDir = URL(fileURLWithPath: try #require(env["LIDIA_BENCH_OUT"]))
        let label = env["LIDIA_BENCH_LABEL"] ?? "run"
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let meetings = try Self.loadMeetings(dbPath: dbPath, pks: pks)
        #expect(!meetings.isEmpty)

        let manager = ModelManager(storage: try Self.benchmarkStorage())
        for model in models {
            let client: any LLMClient
            let budget: SummarizationBudget
            if model == "apple" {
                client = AppleFoundationClient()
                budget = .appleOnDevice
            } else {
                try await manager.loadModel(model)
                client = MLXLocalClient(modelManager: manager, preferredModelID: model)
                budget = .mlxBudget(modelID: model)
                // Warm-up so load and shader compilation aren't counted.
                _ = try await client.chat(messages: [.init(role: "user", content: "Say OK.")], model: model, format: nil)
            }
            let factsClient: any LLMClient = env["LIDIA_BENCH_FACTS"] == "apple" ? AppleFoundationClient() : client
            let fileName = "\(label)__\(model.replacingOccurrences(of: "/", with: "_")).jsonl"
            let outURL = outDir.appendingPathComponent(fileName)
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: outURL)
            defer { try? handle.close() }

            for meeting in meetings {
                if env["LIDIA_BENCH_MODE"] == "legacy" {
                    let record = await Self.runLegacy(meeting: meeting, model: model, client: client, label: label)
                    handle.write(try JSONEncoder().encode(record) + Data("\n".utf8))
                    print("BENCH legacy \(model) #\(meeting.pk): visible after \(record.summaryTotal)s \(record.error ?? "")")
                    continue
                }
                let record = await Self.run(
                    meeting: meeting, model: model, client: client, factsClient: factsClient,
                    budget: budget, label: label
                )
                let data = try JSONEncoder().encode(record)
                handle.write(data + Data("\n".utf8))
                print("BENCH \(model) #\(meeting.pk): ttft=\(record.timeToFirstToken ?? -1)s total=\(record.summaryTotal)s parts=\(record.parts) gen=\(record.generatedTokens ?? -1) tps=\(record.generateTokensPerSecond ?? -1) facts=\(record.factsSeconds)s \(record.error ?? "")")
            }
            if model != "apple" { manager.unloadModel() }
        }
    }

    static func run(
        meeting: BenchMeeting,
        model: String,
        client: any LLMClient,
        factsClient: any LLMClient,
        budget: SummarizationBudget,
        label: String
    ) async -> Record {
        let recorder = MLXGenerationStatsRecorder()
        let prompt = SummaryPrompts.markdownSystemPrompt(
            template: .general,
            attendees: nil,
            wordCount: meeting.transcript.split(separator: " ").count
        )!
        let summarizer = MapReduceSummarizer(client: client, model: model, budget: budget)
        let started = Date()
        do {
            let result = try await MLXLocalClient.$statsRecorder.withValue(recorder) {
                try await summarizer.summarizeMarkdown(
                    transcript: meeting.transcript,
                    legend: nil,
                    systemPrompt: prompt,
                    onText: { _ in },
                    onReset: {}
                )
            }
            let total = Date().timeIntervalSince(started)
            // The last entry is the streamed final pass.
            let final = recorder.entries.last
            let factsStart = Date()
            let facts = await MeetingFactsExtractor.extract(client: factsClient, model: model, notes: result.markdown)
            let factsSeconds = Date().timeIntervalSince(factsStart)
            return Record(
                label: label,
                model: model,
                meeting: meeting.pk,
                transcriptTokensEstimate: TokenEstimator.estimate(meeting.transcript),
                parts: result.partCount,
                timeToFirstToken: result.timeToFirstToken,
                summaryTotal: total,
                promptTokens: recorder.entries.isEmpty ? nil : recorder.entries.map(\.promptTokens).reduce(0, +),
                generatedTokens: recorder.entries.isEmpty ? nil : recorder.entries.map(\.generatedTokens).reduce(0, +),
                generateTokensPerSecond: final.map { Double($0.generatedTokens) / max($0.generateTime, 0.001) },
                promptTokensPerSecond: final.map { Double($0.promptTokens) / max($0.promptTime, 0.001) },
                markdown: result.markdown,
                factsSeconds: factsSeconds,
                factsTitle: facts?.title,
                factsActionItems: facts?.actionItems.map { "\($0.assignee ?? "-"): \($0.title) (\($0.deadline ?? "-"))" } ?? [],
                nextSteps: SummaryMarkdownParser.nextSteps(in: result.markdown).map { "\($0.assignee ?? "-"): \($0.title) (\($0.deadline ?? "-"))" },
                error: nil
            )
        } catch {
            return Record(
                label: label, model: model, meeting: meeting.pk,
                transcriptTokensEstimate: TokenEstimator.estimate(meeting.transcript),
                parts: 0, timeToFirstToken: nil, summaryTotal: Date().timeIntervalSince(started),
                promptTokens: nil, generatedTokens: nil, generateTokensPerSecond: nil, promptTokensPerSecond: nil,
                markdown: "", factsSeconds: 0, factsTitle: nil, factsActionItems: [], nextSteps: [],
                error: String(describing: error)
            )
        }
    }

    /// The pipeline as it was before streaming: LLM transcript cleanup, then a
    /// JSON summary with the old fixed 16K MLX budget. Nothing is visible until
    /// the JSON is complete, so time-to-first-visible-text = total.
    static func runLegacy(meeting: BenchMeeting, model: String, client: any LLMClient, label: String) async -> Record {
        let started = Date()
        do {
            let chunks = TranscriptChunker.chunk(meeting.transcript, maxTokens: 3800)
            var refined: [String] = []
            for chunk in chunks {
                refined.append(try await client.refineTranscript(rawText: chunk, model: model))
            }
            let summarizer = MapReduceSummarizer(client: client, model: model, budget: .mlx)
            let result = try await summarizer.summarize(
                transcript: refined.joined(separator: "\n"), legend: nil, template: .general, attendees: nil
            )
            let total = Date().timeIntervalSince(started)
            return Record(
                label: label, model: model, meeting: meeting.pk,
                transcriptTokensEstimate: TokenEstimator.estimate(meeting.transcript),
                parts: result.partCount, timeToFirstToken: total, summaryTotal: total,
                promptTokens: nil, generatedTokens: nil, generateTokensPerSecond: nil, promptTokensPerSecond: nil,
                markdown: result.response.flatSummary, factsSeconds: 0, factsTitle: result.response.title,
                factsActionItems: result.response.actionItems.map(\.title), nextSteps: [], error: nil
            )
        } catch {
            return Record(
                label: label, model: model, meeting: meeting.pk,
                transcriptTokensEstimate: TokenEstimator.estimate(meeting.transcript),
                parts: 0, timeToFirstToken: nil, summaryTotal: Date().timeIntervalSince(started),
                promptTokens: nil, generatedTokens: nil, generateTokensPerSecond: nil, promptTokensPerSecond: nil,
                markdown: "", factsSeconds: 0, factsTitle: nil, factsActionItems: [], nextSteps: [],
                error: String(describing: error)
            )
        }
    }

    // MARK: - Real pipeline on recorded meetings

    /// Runs the full `MeetingPipeline` on recorded meetings' raw words
    /// (`LIDIA_PIPELINE_PKS`) with the provider in `LIDIA_BENCH_MODELS`
    /// (first entry; `apple` for Apple Intelligence), in memory.
    @Test func runPipelineOnRecordedMeetings() async throws {
        guard let pkList = env["LIDIA_PIPELINE_PKS"], let dbPath = env["LIDIA_BENCH_DB"] else { return }
        let model = (env["LIDIA_BENCH_MODELS"] ?? "apple").split(separator: ",").first.map(String.init) ?? "apple"
        let manager = ModelManager(storage: try Self.benchmarkStorage())
        let client: any LLMClient
        if model == "apple" {
            client = AppleFoundationClient()
        } else {
            try await manager.loadModel(model)
            client = MLXLocalClient(modelManager: manager, preferredModelID: model)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        for pk in pkList.split(separator: ",").compactMap({ Int($0) }) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ZRAWTRANSCRIPT FROM ZMEETING WHERE Z_PK = ?", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(pk))
            var words: [TranscriptWord] = []
            if sqlite3_step(statement) == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
                words = (try? JSONDecoder().decode([TranscriptWord].self, from: data)) ?? []
            }
            sqlite3_finalize(statement)

            let context = try makeInMemoryContext()
            let meeting = Meeting(title: "", rawTranscript: words, status: .processing)
            context.insert(meeting)
            let center = ProcessingProgressCenter()
            let pipeline = MeetingPipeline(llmClient: client, modelContext: context, progressCenter: center)
            let started = Date()
            var firstVisible: TimeInterval?
            let watcher = Task { @MainActor in
                while firstVisible == nil, !Task.isCancelled {
                    if center.streamingSummary[meeting.id]?.isEmpty == false { firstVisible = Date().timeIntervalSince(started) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            do {
                try await pipeline.process(meeting: meeting, model: model == "apple" ? AppleFoundationClient.modelID : model)
            } catch {
                print("PIPELINE #\(pk) threw: \(error.localizedDescription)")
            }
            watcher.cancel()
            print("PIPELINE #\(pk) \(model): words=\(words.count) status=\(meeting.status) firstVisible=\(firstVisible ?? -1)s total=\(Date().timeIntervalSince(started))s summaryWords=\(meeting.summary.split(separator: " ").count) items=\(meeting.actionItems.count) error=\(meeting.processingError ?? "-")")
        }
    }

    // MARK: - Dedicated action-item extraction ("decision model")

    /// Runs `ActionRouting.extractionPrompt` over each transcript with each
    /// model (`LIDIA_ACTIONS=1`) and records answers, latency and peak GPU memory.
    @Test func runActionExtraction() async throws {
        guard env["LIDIA_ACTIONS"] == "1" else { return }
        struct Answer: Encodable { let model: String; let meeting: Int; let seconds: Double; let peakGB: Double; let raw: String }
        let dbPath = try #require(env["LIDIA_BENCH_DB"])
        let pks = (env["LIDIA_BENCH_MEETINGS"] ?? "").split(separator: ",").compactMap { Int($0) }
        let models = (env["LIDIA_BENCH_MODELS"] ?? "").split(separator: ",").map(String.init)
        let outDir = URL(fileURLWithPath: try #require(env["LIDIA_BENCH_OUT"]))
        let meetings = try Self.loadMeetings(dbPath: dbPath, pks: pks)
        let manager = ModelManager(storage: try Self.benchmarkStorage())
        var answers: [Answer] = []
        for model in models {
            try await manager.loadModel(model)
            let client = MLXLocalClient(modelManager: manager, preferredModelID: model)
            _ = try await client.chat(messages: [.init(role: "user", content: "Say OK.")], model: model, format: nil)
            for meeting in meetings {
                GPU.resetPeakMemory()
                let start = Date()
                let raw = (try? await client.chat(
                    messages: [
                        .init(role: "system", content: ActionRouting.extractionPrompt),
                        .init(role: "user", content: "Meeting: \(meeting.title)\n\n\(meeting.transcript)"),
                    ],
                    model: model,
                    format: .json
                )) ?? "ERROR"
                let peak = Double(GPU.peakMemory) / 1_073_741_824
                answers.append(Answer(model: model, meeting: meeting.pk, seconds: Date().timeIntervalSince(start), peakGB: peak, raw: raw))
                print("ACTIONS \(model) #\(meeting.pk): \(Date().timeIntervalSince(start))s peak \(peak) GB")
            }
            manager.unloadModel()
        }
        try JSONEncoder().encode(answers).write(to: outDir.appendingPathComponent("action_extraction.json"))
    }

    // MARK: - Action routing ("decision model") evaluation

    /// Classifies action items (from `LIDIA_ROUTING_ITEMS`, a JSON array of
    /// {"id", "meeting_title", "text"}) with each model and writes the raw
    /// answers for scoring against reference labels.
    @Test func runRoutingBenchmark() async throws {
        guard let itemsPath = env["LIDIA_ROUTING_ITEMS"] else { return }
        struct Item: Codable { let id: String; let meeting_title: String; let text: String }
        struct Answer: Encodable { let model: String; let id: String; let seconds: Double; let raw: String }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: itemsPath)))
        let models = (env["LIDIA_BENCH_MODELS"] ?? "").split(separator: ",").map(String.init)
        let outDir = URL(fileURLWithPath: try #require(env["LIDIA_BENCH_OUT"]))
        let manager = ModelManager(storage: try Self.benchmarkStorage())
        var answers: [Answer] = []
        for model in models {
            let client: any LLMClient
            if model == "apple" {
                client = AppleFoundationClient()
            } else {
                try await manager.loadModel(model)
                client = MLXLocalClient(modelManager: manager, preferredModelID: model)
                _ = try await client.chat(messages: [.init(role: "user", content: "Say OK.")], model: model, format: nil)
            }
            for item in items {
                let start = Date()
                let raw = (try? await client.chat(
                    messages: [
                        .init(role: "system", content: ActionRouting.systemPrompt),
                        .init(role: "user", content: ActionRouting.userPrompt(meetingTitle: item.meeting_title, item: item.text)),
                    ],
                    model: model,
                    format: .json
                )) ?? "ERROR"
                answers.append(Answer(model: model, id: item.id, seconds: Date().timeIntervalSince(start), raw: raw))
            }
            if model != "apple" { manager.unloadModel() }
        }
        let data = try JSONEncoder().encode(answers)
        try data.write(to: outDir.appendingPathComponent("routing_answers.json"))
    }

    // MARK: - Data

    /// Benchmark models live in their own folder (`LIDIA_BENCH_MODELS_DIR`),
    /// never the app's: automatic mode must not pick up benchmark downloads.
    static func benchmarkStorage() throws -> ModelStorage {
        guard let path = ProcessInfo.processInfo.environment["LIDIA_BENCH_MODELS_DIR"] else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Set LIDIA_BENCH_MODELS_DIR to a benchmark-only folder"])
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url != ModelStorage.appModelsDirectory.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Benchmarks must not use the app's models folder"])
        }
        return ModelStorage(hubCacheDirectory: url)
    }

    static func loadMeetings(dbPath: String, pks: [Int]) throws -> [BenchMeeting] {
        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var meetings: [BenchMeeting] = []
        for pk in pks {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ZTITLE, ZREFINEDTRANSCRIPT FROM ZMEETING WHERE Z_PK = ?", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(pk))
            if sqlite3_step(statement) == SQLITE_ROW {
                let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let transcript = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                if !transcript.isEmpty {
                    meetings.append(BenchMeeting(pk: pk, title: title, transcript: transcript))
                }
            }
            sqlite3_finalize(statement)
        }
        return meetings
    }
}
