import Foundation
import Dispatch
import MLX
import Observation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import os

// MARK: - ModelSpec

struct ModelSpec: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sizeGB: Double
    let ramGB: Double
    let isDefault: Bool
}

// MARK: - ModelManagerError

enum ModelManagerError: LocalizedError {
    case notDownloaded(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let modelID):
            return "Model '\(modelID)' is not downloaded"
        case .notLoaded:
            return "No model is currently loaded"
        }
    }
}

// MARK: - ModelManager

/// Owns MLX model files and the in-memory model.
///
/// Lifecycle: models load lazily on first use (or when a recording stops),
/// unload after `idleUnloadInterval` without use, and unload on critical
/// memory pressure when nothing is generating. Nothing loads at app launch.
@MainActor
@Observable
final class ModelManager {
    nonisolated private static let logger = Logger(subsystem: "io.lidia.app", category: "ModelManager")

    /// How long a loaded model may sit unused before it is unloaded.
    nonisolated static let idleUnloadInterval: Duration = .seconds(600)

    /// Memory pressure source for tiered resource shedding.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Where weights live. Downloads, checks and deletes all use this.
    let storage: ModelStorage

    init(storage: ModelStorage = .default) {
        self.storage = storage
        // One-time move of models earlier builds left in the shared Hugging
        // Face cache. Same-volume renames: no copying, no re-download.
        let moved = storage.migrateFromLegacyHubCaches(
            modelIDs: ModelCatalog.all.map(\.id) + [ModelCatalog.embedder.id]
        )
        if !moved.isEmpty {
            Self.logger.info("Moved \(moved.count) model(s) into the app's models folder")
        }
    }

    /// Files fetched for a model (the mlx-swift-lm defaults).
    nonisolated static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    // MARK: - Available Models

    /// Models offered for download (see `ModelCatalog`), best fit for this
    /// Mac first. Legacy models are not offered but stay usable when on disk.
    nonisolated static var availableModels: [ModelSpec] {
        ModelCatalog.offered(forPhysicalMemory: ProcessInfo.processInfo.physicalMemory).map(\.spec)
    }

    /// The recommended model for this Mac's memory tier.
    static var defaultModel: ModelSpec {
        ModelCatalog.recommendedForThisMac.spec
    }

    // MARK: - Download State

    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var downloadingModelID: String? = nil
    var downloadError: String? = nil

    // MARK: - Loaded Model State

    var loadedModelID: String? = nil
    var modelContainer: ModelContainer? = nil
    /// The model currently being loaded, if any.
    private(set) var loadingModelID: String? = nil

    var isModelLoaded: Bool {
        modelContainer != nil && loadedModelID != nil
    }

    // MARK: - Private

    private var downloadTask: Task<Void, Never>? = nil
    private var loadTask: Task<ModelContainer, Error>? = nil
    private var idleUnloadTask: Task<Void, Never>? = nil
    /// Generations in flight. The model is never unloaded while > 0.
    private(set) var activeUseCount = 0

    // MARK: - Downloaded Check

    func isDownloaded(_ modelID: String) -> Bool {
        storage.isDownloaded(modelID)
    }

    /// Fully downloaded and verified (no partial blobs, tokenizer and every
    /// weight shard present, expected size on disk). Required before a model
    /// is used without the user picking it.
    func isVerified(_ modelID: String) -> Bool {
        let entry = ModelCatalog.entry(for: modelID)
        // Legacy sizes are estimates, so only the file checks apply to them.
        let expected = entry?.role == .legacy ? nil : entry?.downloadBytes
        return storage.isVerifiedComplete(modelID, expectedBytes: expected, revision: entry?.revision)
    }

    /// Downloaded chat models, current catalogue first, then legacy ones.
    var downloadedModels: [ModelSpec] {
        downloadedEntries.map(\.spec)
    }

    var downloadedEntries: [ModelCatalogEntry] {
        ModelCatalog.all.filter { isDownloaded($0.id) }
    }

    // MARK: - Download

    /// Byte-level status of the current or last download.
    private(set) var downloadStatus: ModelDownloadStatus?

    /// True when a previous download left partial files to resume from.
    func hasPartialDownload(_ modelID: String) -> Bool {
        !isDownloaded(modelID) && storage.hasPartialDownload(modelID)
    }

    /// Checks whether a model can be downloaded on this Mac right now.
    /// Returns the reason it can't, or nil.
    func preflight(_ modelID: String) -> ModelDownloadError? {
        guard let entry = ModelCatalog.entry(for: modelID) else { return nil }
        if ModelCatalog.fitForThisMac(entry) == .notEnoughMemory {
            return .insufficientMemory(model: entry.displayName, requiredGB: entry.minRAMGB)
        }
        let needed = storage.requiredFreeBytes(forDownloadBytes: entry.downloadBytes, modelID: modelID)
        if let available = storage.availableDiskBytes(), available < needed {
            return .insufficientDisk(needed: needed, available: available)
        }
        return nil
    }

    /// Downloads a model's files, verifies them, and stops. Loading is a
    /// separate step (`loadModel`), done lazily on first use unless
    /// `thenLoad` is true. Downloads resume from partial files.
    func downloadModel(_ modelID: String, thenLoad: Bool = false) {
        guard !isDownloading else { return }

        let entry = ModelCatalog.entry(for: modelID)
        let name = entry?.displayName ?? modelID
        let total = entry?.downloadBytes ?? 0
        let revision = entry?.revision ?? "main"

        if let problem = preflight(modelID) {
            fail(modelID: modelID, bytesTotal: total, message: problem.localizedDescription)
            return
        }
        do {
            try storage.prepareRoot()
        } catch {
            fail(modelID: modelID, bytesTotal: total, message: "Couldn't create the models folder: \(error.localizedDescription)")
            return
        }

        downloadGeneration += 1
        let generation = downloadGeneration
        isDownloading = true
        downloadProgress = 0.0
        downloadingModelID = modelID
        downloadError = nil
        downloadStatus = ModelDownloadStatus(
            modelID: modelID, phase: .preparing, bytesDone: 0, bytesTotal: total,
            bytesPerSecond: 0, secondsRemaining: nil
        )
        let storage = self.storage
        let meter = MainActorBox(ThroughputMeter())

        downloadTask = Task {
            // Tell macOS this is a user-initiated, long-running activity so it
            // doesn't kill us for excessive disk writes during model download.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Downloading on-device model \(name)"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }

            do {
                guard let repo = Repo.ID(rawValue: modelID) else {
                    throw ModelDownloadError.invalidModelID(modelID)
                }
                let hub = HubClient(cache: HubCache(cacheDirectory: storage.hubCacheDirectory))

                for attempt in 1...2 {
                    _ = try await hub.downloadSnapshot(
                        of: repo,
                        revision: revision,
                        matching: Self.downloadPatterns,
                        progressHandler: { @MainActor progress in
                            guard generation == self.downloadGeneration else { return }
                            let fraction = progress.fractionCompleted
                            let bytesTotal = total > 0 ? total : progress.totalUnitCount
                            let bytesDone = Int64(Double(bytesTotal) * fraction)
                            let rate = meter.value.record(bytesDone: bytesDone, bytesTotal: bytesTotal)
                            self.downloadProgress = fraction
                            self.downloadStatus = ModelDownloadStatus(
                                modelID: modelID, phase: .downloading, bytesDone: bytesDone,
                                bytesTotal: bytesTotal, bytesPerSecond: rate.bytesPerSecond,
                                secondsRemaining: rate.secondsRemaining
                            )
                        }
                    )

                    try Task.checkCancellation()
                    if generation == self.downloadGeneration {
                        self.downloadStatus?.phase = .verifying
                    }
                    let corrupt = try await Task.detached(priority: .utility) {
                        try storage.corruptBlobs(for: modelID)
                    }.value
                    if corrupt.isEmpty { break }

                    Self.logger.error("\(corrupt.count) blob(s) of \(modelID, privacy: .public) failed SHA-256 verification (attempt \(attempt))")
                    storage.discardCorruptBlobs(corrupt, modelID: modelID)
                    if attempt == 2 {
                        throw ModelDownloadError.verificationFailed(model: name)
                    }
                }

                guard storage.isDownloaded(modelID, revision: entry?.revision) || storage.isDownloaded(modelID) else {
                    throw ModelDownloadError.incomplete(model: name)
                }

                Self.logger.info("Model \(modelID, privacy: .public) downloaded and verified")
                if generation == self.downloadGeneration {
                    self.downloadProgress = 1.0
                    self.downloadStatus = ModelDownloadStatus(
                        modelID: modelID, phase: .finished, bytesDone: total, bytesTotal: total,
                        bytesPerSecond: 0, secondsRemaining: 0
                    )
                    self.finishDownloadTask()
                }

                if thenLoad {
                    do {
                        try await self.loadModel(modelID)
                    } catch {
                        Self.logger.error("Load after download failed for \(modelID, privacy: .public): \(error)")
                    }
                }
                return
            } catch let error where Self.isCancellation(error) {
                Self.logger.info("Download paused for \(modelID, privacy: .public)")
                // A newer download (e.g. a quick resume) owns the state now.
                guard generation == self.downloadGeneration else { return }
                self.downloadStatus?.phase = .paused
            } catch {
                Self.logger.error("Failed to download model \(modelID, privacy: .public): \(error)")
                guard generation == self.downloadGeneration else { return }
                self.downloadError = error.localizedDescription
                self.downloadStatus?.phase = .failed(error.localizedDescription)
            }
            self.finishDownloadTask()
        }
    }

    /// Incremented per download so a cancelled task can't overwrite the
    /// state of the download that replaced it.
    private var downloadGeneration = 0

    private func finishDownloadTask() {
        isDownloading = false
        downloadingModelID = nil
        downloadTask = nil
    }

    private func fail(modelID: String, bytesTotal: Int64, message: String) {
        downloadError = message
        downloadStatus = ModelDownloadStatus(
            modelID: modelID, phase: .failed(message), bytesDone: 0, bytesTotal: bytesTotal,
            bytesPerSecond: 0, secondsRemaining: nil
        )
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    // MARK: - Pause / Cancel Download

    /// Stops the download and keeps partial files; `downloadModel` resumes.
    func pauseDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadingModelID = nil
        if downloadStatus?.isActive == true {
            downloadStatus?.phase = .paused
        }
    }

    /// Kept for existing callers: same as `pauseDownload()`.
    func cancelDownload() {
        pauseDownload()
        downloadProgress = 0.0
    }

    /// Deletes partial files from a paused or failed download.
    func discardPartialDownload(_ modelID: String) {
        guard !isDownloaded(modelID) else { return }
        if downloadingModelID == modelID { pauseDownload() }
        _ = try? storage.delete(modelID)
        if downloadStatus?.modelID == modelID { downloadStatus = nil }
    }

    /// Bytes used by all downloaded models.
    var modelsDiskUsage: Int64 {
        storage.totalSizeOnDisk()
    }

    // MARK: - Load Model

    /// Loads a downloaded model from disk. Concurrent calls for the same model
    /// share one load; a different model replaces the loaded one.
    func loadModel(_ modelID: String) async throws {
        if loadedModelID == modelID, modelContainer != nil {
            scheduleIdleUnloadIfIdle()
            return
        }
        if loadingModelID == modelID, let loadTask {
            _ = try await loadTask.value
            return
        }
        let revision = ModelCatalog.entry(for: modelID)?.revision
        guard let directory = storage.modelDirectory(for: modelID, revision: revision) else {
            throw ModelManagerError.notDownloaded(modelID)
        }

        // Drop the previous model first so two never sit in memory together.
        if modelContainer != nil { unloadModel() }

        loadingModelID = modelID
        let task = Task.detached {
            try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
        }
        loadTask = task
        defer {
            if loadingModelID == modelID {
                loadingModelID = nil
                loadTask = nil
            }
        }

        let container = try await task.value
        self.modelContainer = container
        self.loadedModelID = modelID
        scheduleIdleUnloadIfIdle()
        Self.logger.info("Model \(modelID, privacy: .public) loaded into memory")
    }

    // MARK: - Use tracking and idle unload

    /// Marks the start of a generation. Pair with `endUse()`.
    func beginUse() {
        activeUseCount += 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    /// Marks the end of a generation; the idle-unload timer restarts.
    func endUse() {
        activeUseCount = max(0, activeUseCount - 1)
        scheduleIdleUnloadIfIdle()
    }

    private func scheduleIdleUnloadIfIdle() {
        guard activeUseCount == 0 else { return }
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard modelContainer != nil else { return }
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadInterval)
            guard !Task.isCancelled, let self else { return }
            guard self.activeUseCount == 0, self.modelContainer != nil else { return }
            Self.logger.info("Unloading idle model \(self.loadedModelID ?? "?", privacy: .public)")
            self.unloadModel()
        }
    }

    // MARK: - Unload Model

    func unloadModel() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        modelContainer = nil
        loadedModelID = nil
        // Flush MLX framework caches — without this, GPU/memory buffers stay allocated
        // even after dropping the Swift reference to ModelContainer.
        Memory.clearCache()
        Self.logger.info("Model unloaded from memory, MLX cache cleared")
    }

    // MARK: - Delete Model

    /// Unloads the model if needed and removes every copy of it from disk
    /// (the whole `models--org--name` directory, plus legacy folders).
    /// Returns the bytes freed.
    @discardableResult
    func deleteModel(_ modelID: String) -> Int64 {
        if loadedModelID == modelID {
            unloadModel()
        }
        do {
            let freed = try storage.delete(modelID)
            Self.logger.info("Deleted model \(modelID, privacy: .public) from disk (\(freed) bytes)")
            return freed
        } catch {
            Self.logger.error("Failed to delete model \(modelID, privacy: .public): \(error)")
            return 0
        }
    }

    // MARK: - Warm Keepalive

    /// Kept for call-site compatibility. Models no longer load at launch:
    /// holding 3–17 GB of weights for an app that may not summarise anything
    /// is the wrong default. They load on first use or when a recording stops.
    func warmKeepalive() {
        Self.logger.info("Launch preload skipped; MLX models load on first use")
    }

    // MARK: - Memory Pressure Handling

    /// Start monitoring system memory pressure for tiered resource shedding.
    func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            Task { @MainActor in
                self.handleMemoryPressure(event)
            }
        }

        source.resume()
        memoryPressureSource = source
        Self.logger.info("Memory pressure monitoring started")
    }

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            if activeUseCount == 0, modelContainer != nil {
                Self.logger.warning("Memory pressure CRITICAL — unloading idle model")
                unloadModel()
            } else {
                Self.logger.warning("Memory pressure CRITICAL — model in use, clearing MLX cache")
                Memory.clearCache()
            }
        } else if event.contains(.warning) {
            Self.logger.warning("Memory pressure WARNING — clearing MLX cache")
            Memory.clearCache()
        }
    }
}
