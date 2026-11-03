import Testing
import Foundation
@testable import LidIA

@Suite("Model storage")
struct ModelStorageTests {

    /// A fresh temp root per test.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidia-model-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a Hugging Face–layout snapshot with blobs and symlinks.
    private func writeSnapshot(storage: ModelStorage, id: String, revision: String, blobBytes: Int = 1024) throws {
        let fm = FileManager.default
        let repo = storage.repoDirectory(for: id)
        let blobs = repo.appendingPathComponent("blobs")
        let snapshot = repo.appendingPathComponent("snapshots/\(revision)")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)

        let weights = blobs.appendingPathComponent("weightsblob")
        try Data(repeating: 7, count: blobBytes).write(to: weights)
        let config = blobs.appendingPathComponent("configblob")
        try Data("{}".utf8).write(to: config)

        // Relative links, as swift-huggingface writes them, so moving the
        // repo folder keeps them valid.
        try fm.createSymbolicLink(atPath: snapshot.appendingPathComponent("model.safetensors").path, withDestinationPath: "../../blobs/\(weights.lastPathComponent)")
        try fm.createSymbolicLink(atPath: snapshot.appendingPathComponent("config.json").path, withDestinationPath: "../../blobs/\(config.lastPathComponent)")
    }

    @Test("Repo folder name follows the Hugging Face cache layout")
    func repoFolderName() {
        #expect(ModelStorage.repoFolderName(for: "mlx-community/gemma-4-e4b-it-4bit") == "models--mlx-community--gemma-4-e4b-it-4bit")
    }

    @Test("isDownloaded finds a snapshot in the same cache the downloader writes to")
    func detectsHubSnapshot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        let id = "mlx-community/test-model"

        #expect(!storage.isDownloaded(id))
        try writeSnapshot(storage: storage, id: id, revision: "abc123")
        #expect(storage.isDownloaded(id))
        #expect(storage.isDownloaded(id, revision: "abc123"))
        #expect(storage.modelDirectory(for: id)?.lastPathComponent == "abc123")
    }

    @Test("A snapshot whose weights link is dangling is not downloaded")
    func danglingLinkIsNotDownloaded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        let id = "mlx-community/test-model"
        try writeSnapshot(storage: storage, id: id, revision: "abc123")
        try FileManager.default.removeItem(at: storage.blobsDirectory(for: id).appendingPathComponent("weightsblob"))
        #expect(!storage.isDownloaded(id))
    }

    @Test("Legacy plain-layout folders are still found")
    func legacyFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy")
        let storage = ModelStorage(hubCacheDirectory: root.appendingPathComponent("hub"), legacyPlainDirectories: [legacy])
        let id = "mlx-community/old-model"
        let dir = legacy.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("model.safetensors"))
        #expect(storage.isDownloaded(id))
    }

    @Test("Delete removes the whole repo directory and reports bytes freed")
    func deleteRemovesEverything() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        let id = "mlx-community/test-model"
        try writeSnapshot(storage: storage, id: id, revision: "abc123", blobBytes: 64 * 1024)

        let sizeBefore = storage.sizeOnDisk(id)
        #expect(sizeBefore >= 64 * 1024)
        let freed = try storage.delete(id)
        #expect(freed == sizeBefore)
        #expect(!FileManager.default.fileExists(atPath: storage.repoDirectory(for: id).path))
        #expect(!storage.isDownloaded(id))
    }

    @Test("Partial downloads are detected for resume")
    func partialDownload() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        let id = "mlx-community/test-model"
        let blobs = storage.blobsDirectory(for: id)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        #expect(!storage.hasPartialDownload(id))
        try Data([1, 2, 3]).write(to: blobs.appendingPathComponent("deadbeef.incomplete"))
        #expect(storage.hasPartialDownload(id))
    }

    @MainActor
    @Test("ModelManager uses its storage for isDownloaded and delete")
    func managerUsesStorage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        let manager = ModelManager(storage: storage)
        let id = ModelManager.availableModels[0].id
        #expect(!manager.isDownloaded(id))
        try writeSnapshot(storage: storage, id: id, revision: "r1")
        #expect(manager.isDownloaded(id))
        #expect(manager.downloadedModels.map(\.id).contains(id))
        manager.deleteModel(id)
        #expect(!manager.isDownloaded(id))
    }

    // MARK: - Migration

    @Test("Models in the shared Hugging Face cache move into the app folder")
    func migratesFromSharedCache() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = ModelStorage(hubCacheDirectory: root.appendingPathComponent("shared"))
        let id = "mlx-community/gemma-4-e4b-it-4bit"
        try writeSnapshot(storage: shared, id: id, revision: "r1")
        let unrelated = "mlx-community/Kokoro-82M-bf16"
        try writeSnapshot(storage: shared, id: unrelated, revision: "r1")

        let app = ModelStorage(
            hubCacheDirectory: root.appendingPathComponent("app"),
            legacyHubCacheDirectories: [shared.hubCacheDirectory]
        )
        let moved = app.migrateFromLegacyHubCaches(modelIDs: [id])
        #expect(moved == [id])
        #expect(FileManager.default.fileExists(atPath: app.repoDirectory(for: id).path))
        #expect(!FileManager.default.fileExists(atPath: shared.repoDirectory(for: id).path))
        #expect(app.isDownloaded(id))
        // Other apps' models (e.g. TTS) in the shared cache are left alone.
        #expect(FileManager.default.fileExists(atPath: shared.repoDirectory(for: unrelated).path))
        // Running again is a no-op.
        #expect(app.migrateFromLegacyHubCaches(modelIDs: [id]).isEmpty)
    }

    @Test("A model left in the shared cache is still found read-only")
    func findsLegacyHubCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = ModelStorage(hubCacheDirectory: root.appendingPathComponent("shared"))
        let id = "mlx-community/test-model"
        try writeSnapshot(storage: shared, id: id, revision: "r1")
        let app = ModelStorage(
            hubCacheDirectory: root.appendingPathComponent("app"),
            legacyHubCacheDirectories: [shared.hubCacheDirectory]
        )
        #expect(app.isDownloaded(id))
        try app.delete(id)
        #expect(!app.isDownloaded(id))
    }

    // MARK: - Verification

    @Test("Blobs named by SHA-256 are verified; mismatches are reported")
    func verifiesBlobs() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        let id = "mlx-community/test-model"
        let blobs = storage.blobsDirectory(for: id)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        let good = Data("weights".utf8)
        let goodName = try ModelStorage.sha256Hex(of: { let u = root.appendingPathComponent("tmp"); try good.write(to: u); return u }())
        try good.write(to: blobs.appendingPathComponent(goodName))
        // Named for different content: corrupt.
        let badName = String(repeating: "a", count: 64)
        try Data("tampered".utf8).write(to: blobs.appendingPathComponent(badName))
        // Git blob (not SHA-256 named): skipped.
        try Data("{}".utf8).write(to: blobs.appendingPathComponent("0123456789abcdef0123456789abcdef01234567"))

        let corrupt = try storage.corruptBlobs(for: id)
        #expect(corrupt.map(\.lastPathComponent) == [badName])

        storage.discardCorruptBlobs(corrupt, modelID: id)
        #expect(try storage.corruptBlobs(for: id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(goodName).path))
    }

    @Test("SHA-256 of a known string")
    func sha256Known() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try ModelStorage.sha256Hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Pre-flight and progress

    @Test("Required free space is 1.15x the download minus what's already there")
    func requiredFreeBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(hubCacheDirectory: root)
        #expect(storage.requiredFreeBytes(forDownloadBytes: 1_000_000, modelID: "a/b") == 1_150_000)
        #expect(storage.availableDiskBytes() ?? 0 > 0)
    }

    @Test("Throughput meter smooths speed and estimates time left")
    func throughput() {
        var meter = ThroughputMeter(minimumInterval: 0.5, smoothing: 0.5)
        let start = Date(timeIntervalSince1970: 0)
        _ = meter.record(bytesDone: 0, bytesTotal: 1000, at: start)
        let first = meter.record(bytesDone: 100, bytesTotal: 1000, at: start.addingTimeInterval(1))
        #expect(first.bytesPerSecond == 100)
        #expect(first.secondsRemaining == 9)
        let second = meter.record(bytesDone: 400, bytesTotal: 1000, at: start.addingTimeInterval(2))
        #expect(second.bytesPerSecond == 200)  // 0.5 * 300 + 0.5 * 100
        #expect(second.secondsRemaining == 3)
    }

    @Test("Download status text")
    func statusText() {
        let status = ModelDownloadStatus(
            modelID: "x", phase: .downloading, bytesDone: 1_000_000_000, bytesTotal: 5_000_000_000,
            bytesPerSecond: 20_000_000, secondsRemaining: 200
        )
        #expect(status.fraction == 0.2)
        #expect(status.progressDescription.contains("3 min left"))
        #expect(status.isActive)
    }

    @MainActor
    @Test("Pre-flight refuses models this Mac can't run")
    func preflightMemory() {
        let manager = ModelManager(storage: ModelStorage(hubCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let huge = ModelCatalog.current.max(by: { $0.minRAMGB < $1.minRAMGB })!
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if physicalGB < Double(huge.minRAMGB) * 0.75 {
            #expect(manager.preflight(huge.id) == .insufficientMemory(model: huge.displayName, requiredGB: huge.minRAMGB))
        }
        #expect(manager.preflight("not/in-catalogue") == nil)
    }

    @MainActor
    @Test("warmKeepalive does not load anything")
    func warmKeepaliveIsLazy() {
        let manager = ModelManager(storage: ModelStorage(hubCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        manager.warmKeepalive()
        #expect(!manager.isModelLoaded)
        #expect(manager.loadingModelID == nil)
    }
}
