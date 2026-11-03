import CryptoKit
import Foundation
import HuggingFace

/// Where MLX model weights live on disk, and the single source of truth for
/// "is it downloaded", "where do I load it from" and "delete it".
///
/// The downloader (`HubClient` with a cache rooted at `hubCacheDirectory`) and
/// these checks share one root, so they can't drift apart again (the old
/// `ModelManager` checked `~/Library/Caches/models/<id>` while downloads went
/// to `~/.cache/huggingface/hub`).
///
/// The app owns its models: `~/Library/Application Support/LidIA/Models`,
/// excluded from Time Machine. Models found in the shared Hugging Face cache
/// (`~/.cache/huggingface/hub`, where earlier builds downloaded) are moved
/// in once by `migrateFromLegacyHubCaches(modelIDs:)`.
///
/// Layout under `hubCacheDirectory` is the Hugging Face cache layout:
/// `models--<org>--<name>/{blobs,refs,snapshots/<commit>/…}`.
struct ModelStorage: Sendable {
    /// Root of the Hugging Face–layout cache the app downloads into.
    let hubCacheDirectory: URL
    /// Older plain-layout locations (`<dir>/<org>/<name>/config.json`) that
    /// are still loadable and deletable but never written to.
    let legacyPlainDirectories: [URL]
    /// Older Hugging Face–layout caches. Searched read-only (in case a move
    /// failed) and the source of the one-time migration.
    let legacyHubCacheDirectories: [URL]

    init(hubCacheDirectory: URL, legacyPlainDirectories: [URL] = [], legacyHubCacheDirectories: [URL] = []) {
        self.hubCacheDirectory = hubCacheDirectory
        self.legacyPlainDirectories = legacyPlainDirectories
        self.legacyHubCacheDirectories = legacyHubCacheDirectories
    }

    /// The location the shipping app uses.
    static var `default`: ModelStorage {
        ModelStorage(
            hubCacheDirectory: appModelsDirectory,
            legacyPlainDirectories: [Self.legacyCachesModelsDirectory],
            legacyHubCacheDirectories: [HubCache.default.cacheDirectory]
        )
    }

    /// `~/Library/Application Support/LidIA/Models`.
    static var appModelsDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("LidIA", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Pre-HubClient location used by older mlx-swift-lm builds.
    static var legacyCachesModelsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/models", isDirectory: true)
    }

    // MARK: - Paths

    /// `models--org--name` directory for a repo ID like `org/name`.
    func repoDirectory(for modelID: String) -> URL {
        hubCacheDirectory.appendingPathComponent(Self.repoFolderName(for: modelID), isDirectory: true)
    }

    static func repoFolderName(for modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }

    func blobsDirectory(for modelID: String) -> URL {
        repoDirectory(for: modelID).appendingPathComponent("blobs", isDirectory: true)
    }

    /// A loadable directory for the model: the snapshot for `revision` if
    /// given and complete, else any complete snapshot, else a legacy folder.
    func modelDirectory(for modelID: String, revision: String? = nil) -> URL? {
        let roots = [hubCacheDirectory] + legacyHubCacheDirectories
        for root in roots {
            let repo = root.appendingPathComponent(Self.repoFolderName(for: modelID), isDirectory: true)
            if let snapshot = Self.completeSnapshot(in: repo, revision: revision) {
                return snapshot
            }
        }
        for legacy in legacyPlainDirectories {
            let dir = legacy.appendingPathComponent(modelID, isDirectory: true)
            if Self.isCompleteModelDirectory(dir) { return dir }
        }
        return nil
    }

    /// The pinned snapshot if complete, else the newest complete snapshot.
    private static func completeSnapshot(in repo: URL, revision: String?) -> URL? {
        let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
        if let revision {
            let pinned = snapshots.appendingPathComponent(revision, isDirectory: true)
            if isCompleteModelDirectory(pinned) { return pinned }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let newestFirst = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        return newestFirst.first(where: isCompleteModelDirectory)
    }

    /// Every directory that may hold a copy of the model.
    private func allCopies(of modelID: String) -> [URL] {
        let folder = Self.repoFolderName(for: modelID)
        return ([hubCacheDirectory] + legacyHubCacheDirectories).map { $0.appendingPathComponent(folder, isDirectory: true) }
            + legacyPlainDirectories.map { $0.appendingPathComponent(modelID, isDirectory: true) }
    }

    func isDownloaded(_ modelID: String, revision: String? = nil) -> Bool {
        modelDirectory(for: modelID, revision: revision) != nil
    }

    /// True when partial blobs (`*.incomplete`) exist, so a download can resume.
    func hasPartialDownload(_ modelID: String) -> Bool {
        guard let blobs = try? FileManager.default.contentsOfDirectory(atPath: blobsDirectory(for: modelID).path) else {
            return false
        }
        return blobs.contains { $0.hasSuffix(".incomplete") }
    }

    /// A directory is loadable when it has `config.json` and at least one
    /// readable `.safetensors` file (snapshot entries are symlinks into
    /// `blobs/`; `fileExists` follows them, so dangling links fail).
    static func isCompleteModelDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path),
              let files = try? fm.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return files.contains { name in
            name.hasSuffix(".safetensors") && fm.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }

    /// Stricter than `isDownloaded`, for models used without the user picking
    /// them (automatic mode): no partial blobs, a config and tokenizer, every
    /// weight shard named in `model.safetensors.index.json` present and
    /// non-empty, and (when the catalogue knows the size) at least 95% of the
    /// expected bytes on disk.
    func isVerifiedComplete(_ modelID: String, expectedBytes: Int64? = nil, revision: String? = nil) -> Bool {
        guard !hasPartialDownload(modelID),
              let directory = modelDirectory(for: modelID, revision: revision) else { return false }
        return Self.isVerifiedModelDirectory(directory, expectedBytes: expectedBytes)
    }

    static func isVerifiedModelDirectory(_ url: URL, expectedBytes: Int64? = nil) -> Bool {
        let fm = FileManager.default
        guard isCompleteModelDirectory(url) else { return false }
        let hasTokenizer = ["tokenizer.json", "tokenizer_config.json"].contains {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        guard hasTokenizer else { return false }

        func size(_ name: String) -> Int64 {
            let path = url.appendingPathComponent(name).resolvingSymlinksInPath().path
            return ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var weightFiles: Set<String>
        let indexURL = url.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = index["weight_map"] as? [String: String] {
            weightFiles = Set(map.values)
        } else {
            let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            weightFiles = Set(files.filter { $0.hasSuffix(".safetensors") })
        }
        guard !weightFiles.isEmpty, weightFiles.allSatisfy({ size($0) > 0 }) else { return false }

        if let expectedBytes, expectedBytes > 0 {
            let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let total = files.reduce(Int64(0)) { $0 + size($1) }
            guard Double(total) >= Double(expectedBytes) * 0.95 else { return false }
        }
        return true
    }

    // MARK: - Size and deletion

    /// Bytes on disk for a model across the hub cache and legacy folders.
    func sizeOnDisk(_ modelID: String) -> Int64 {
        allCopies(of: modelID).reduce(0) { $0 + Self.allocatedSize(of: $1) }
    }

    /// Bytes used by everything under the app's models directory.
    func totalSizeOnDisk() -> Int64 {
        Self.allocatedSize(of: hubCacheDirectory)
    }

    /// Removes every copy of the model (blobs, refs, snapshots and legacy
    /// folders). Returns the bytes freed.
    @discardableResult
    func delete(_ modelID: String) throws -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for dir in allCopies(of: modelID) where fm.fileExists(atPath: dir.path) {
            freed += Self.allocatedSize(of: dir)
            try fm.removeItem(at: dir)
        }
        return freed
    }

    // MARK: - Setup and migration

    /// Creates the models directory and excludes it from backups (weights
    /// can be downloaded again; Time Machine shouldn't copy 15 GB of them).
    func prepareRoot() throws {
        try FileManager.default.createDirectory(at: hubCacheDirectory, withIntermediateDirectories: true)
        var root = hubCacheDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    /// Moves the given models from legacy Hugging Face caches into the app's
    /// directory (a rename on the same volume: no re-download). Skips models
    /// already present. Returns the IDs moved.
    @discardableResult
    func migrateFromLegacyHubCaches(modelIDs: [String]) -> [String] {
        let fm = FileManager.default
        var moved: [String] = []
        for modelID in modelIDs {
            let destination = repoDirectory(for: modelID)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            for legacyRoot in legacyHubCacheDirectories {
                let source = legacyRoot.appendingPathComponent(Self.repoFolderName(for: modelID), isDirectory: true)
                guard fm.fileExists(atPath: source.path) else { continue }
                do {
                    try prepareRoot()
                    try fm.moveItem(at: source, to: destination)
                    moved.append(modelID)
                    break
                } catch {
                    // Left in place; modelDirectory still finds it read-only.
                    continue
                }
            }
        }
        return moved
    }

    // MARK: - Pre-flight

    /// Free space usable for important data on the models volume.
    func availableDiskBytes() -> Int64? {
        var probe = hubCacheDirectory
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Bytes that must be free before downloading: 1.15 × the download,
    /// minus what is already on disk for this model (resumed downloads).
    func requiredFreeBytes(forDownloadBytes downloadBytes: Int64, modelID: String) -> Int64 {
        let needed = Int64(Double(downloadBytes) * 1.15)
        return max(0, needed - sizeOnDisk(modelID))
    }

    // MARK: - Verification

    /// Hashes every content-addressed blob of the model (LFS blobs are named
    /// by their SHA-256) and returns the ones whose content doesn't match.
    /// Blobs with non-SHA-256 names (small git files) are skipped.
    func corruptBlobs(for modelID: String) throws -> [URL] {
        let fm = FileManager.default
        let blobs = blobsDirectory(for: modelID)
        guard let names = try? fm.contentsOfDirectory(atPath: blobs.path) else { return [] }
        var corrupt: [URL] = []
        for name in names where Self.isSHA256(name) {
            try Task.checkCancellation()
            let url = blobs.appendingPathComponent(name)
            if try Self.sha256Hex(of: url) != name.lowercased() {
                corrupt.append(url)
            }
        }
        return corrupt
    }

    static func isSHA256(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Removes corrupt blobs and the snapshots that point at them, so the
    /// next download fetches them again.
    func discardCorruptBlobs(_ blobs: [URL], modelID: String) {
        let fm = FileManager.default
        for blob in blobs { try? fm.removeItem(at: blob) }
        let snapshots = repoDirectory(for: modelID).appendingPathComponent("snapshots", isDirectory: true)
        try? fm.removeItem(at: snapshots)
    }

    /// Total allocated size of a directory tree, without following symlinks
    /// (snapshot links point into `blobs/`, which is counted directly).
    static func allocatedSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
