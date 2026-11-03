import Testing
import Foundation
@testable import LidIA

@Suite("Model catalogue")
struct ModelCatalogTests {
    private let gib: UInt64 = 1_073_741_824

    @Test("RAM tiers follow the research thresholds")
    func tiers() {
        #expect(RAMTier.forPhysicalMemory(bytes: 8 * gib) == .gb8)
        #expect(RAMTier.forPhysicalMemory(bytes: 11 * gib) == .gb8)
        #expect(RAMTier.forPhysicalMemory(bytes: 16 * gib) == .gb16)
        #expect(RAMTier.forPhysicalMemory(bytes: 18 * gib) == .gb16)
        #expect(RAMTier.forPhysicalMemory(bytes: 24 * gib) == .gb24)
        #expect(RAMTier.forPhysicalMemory(bytes: 32 * gib) == .gb32)
        #expect(RAMTier.forPhysicalMemory(bytes: 36 * gib) == .gb32)
        #expect(RAMTier.forPhysicalMemory(bytes: 48 * gib) == .gb48)
        #expect(RAMTier.forPhysicalMemory(bytes: 128 * gib) == .gb48)
    }

    @Test("Recommended model per tier comes from the benchmark")
    func recommendedPerTier() {
        for tier in [RAMTier.gb8, .gb16, .gb24, .gb32] {
            #expect(ModelCatalog.recommended(for: tier).id == "mlx-community/Qwen3.5-4B-4bit")
        }
        #expect(ModelCatalog.recommended(for: .gb48).id == "mlx-community/Qwen3.6-35B-A3B-4bit")
    }

    @Test("Qwen comes first in the catalogue")
    func qwenFirst() {
        let families = ModelCatalog.current.map(\.family)
        let firstGemma = families.firstIndex(of: .gemma4) ?? families.count
        #expect(families.prefix(firstGemma).allSatisfy { $0 == .qwen35 })
        #expect(firstGemma >= 3)
    }
    @Test("Current models are pinned to full commit SHAs; legacy ones are not offered")
    func pinnedRevisions() {
        for entry in ModelCatalog.current + [ModelCatalog.embedder] {
            let revision = try? #require(entry.revision)
            #expect(revision?.count == 40, "\(entry.id) must pin a full commit SHA")
            #expect(revision?.allSatisfy(\.isHexDigit) == true)
            #expect(entry.role != .legacy)
        }
        let offered = Set(ModelCatalog.offered(forPhysicalMemory: 16 * gib).map(\.id))
        for legacy in ModelCatalog.legacy {
            #expect(legacy.role == .legacy)
            #expect(!offered.contains(legacy.id))
        }
    }

    @Test("Dropped models stay known so installed copies keep working")
    func legacyStillKnown() {
        for id in [
            "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            "mlx-community/Phi-4-mini-instruct-4bit",
            "mlx-community/Qwen3-8B-4bit",
            "mlx-community/gemma-3-4b-it-4bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
        ] {
            #expect(ModelCatalog.entry(for: id)?.role == .legacy)
        }
    }

    @Test("Fit badges")
    func fit() {
        let small = ModelCatalog.recommended(for: .gb16)
        let big = ModelCatalog.recommended(for: .gb48)
        let nine = try! #require(ModelCatalog.entry(for: "mlx-community/Qwen3.5-9B-4bit"))
        #expect(ModelCatalog.fit(small, physicalMemoryBytes: 16 * gib) == .recommended)
        #expect(ModelCatalog.fit(nine, physicalMemoryBytes: 32 * gib) == .fits)
        #expect(ModelCatalog.fit(nine, physicalMemoryBytes: 8 * gib) == .notEnoughMemory)
        #expect(ModelCatalog.fit(big, physicalMemoryBytes: 36 * gib) == .willBeSlow)
        #expect(ModelCatalog.fit(big, physicalMemoryBytes: 24 * gib) == .notEnoughMemory)
    }

    @Test("Offered list puts this tier's pick first")
    func offeredOrder() {
        #expect(ModelCatalog.offered(forPhysicalMemory: 8 * gib).first?.id == "mlx-community/Qwen3.5-4B-4bit")
        #expect(ModelCatalog.offered(forPhysicalMemory: 64 * gib).first?.id == "mlx-community/Qwen3.6-35B-A3B-4bit")
        #expect(ModelCatalog.offered(forPhysicalMemory: 16 * gib).count == ModelCatalog.current.count)
    }

    @Test("Context caps grow with tier")
    func contextCaps() {
        let caps = RAMTier.allCases.map { ModelCatalog.recommended(for: $0).contextCap }
        #expect(caps == caps.sorted())
        #expect(ModelCatalog.recommended(for: .gb8).contextCap >= 32_768)
    }

    @Test("Automatic uses only this Mac's recommended model, and only when verified")
    func automaticPick() {
        let mac36 = 36 * gib
        #expect(ModelCatalog.automaticModelID(physicalMemoryBytes: mac36) { _ in true } == "mlx-community/Qwen3.5-4B-4bit")
        // Another model being installed never matters.
        #expect(ModelCatalog.automaticModelID(physicalMemoryBytes: mac36) { $0.id != "mlx-community/Qwen3.5-4B-4bit" } == nil)
        #expect(ModelCatalog.automaticModelID(physicalMemoryBytes: 64 * gib) { _ in true } == "mlx-community/Qwen3.6-35B-A3B-4bit")
    }

    @Test("Verification rejects partial or incomplete model folders")
    func verification() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("verify-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(count: 10).write(to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#
        try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
        // A shard is missing and there is no tokenizer: loadable-looking, but not verified.
        #expect(ModelStorage.isCompleteModelDirectory(dir))
        #expect(!ModelStorage.isVerifiedModelDirectory(dir))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        #expect(!ModelStorage.isVerifiedModelDirectory(dir))
        try Data(count: 10).write(to: dir.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(ModelStorage.isVerifiedModelDirectory(dir))
        #expect(!ModelStorage.isVerifiedModelDirectory(dir, expectedBytes: 1_000_000))
    }
}
