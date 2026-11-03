import Foundation

// MARK: - RAM tier

/// Mac memory tiers used to pick the recommended on-device model.
enum RAMTier: Int, CaseIterable, Comparable, Sendable {
    case gb8 = 8
    case gb16 = 16
    case gb24 = 24
    case gb32 = 32
    case gb48 = 48

    static func < (lhs: RAMTier, rhs: RAMTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Tier for a machine: under 12 GB → 8 GB tier, under 20 → 16, under 28 → 24,
    /// under 44 → 32 (32 and 36 GB Macs), otherwise 48 GB+.
    static func forPhysicalMemory(bytes: UInt64) -> RAMTier {
        let gb = Double(bytes) / 1_073_741_824
        switch gb {
        case ..<12: return .gb8
        case ..<20: return .gb16
        case ..<28: return .gb24
        case ..<44: return .gb32
        default: return .gb48
        }
    }

    static var thisMac: RAMTier {
        forPhysicalMemory(bytes: ProcessInfo.processInfo.physicalMemory)
    }

    var label: String { self == .gb48 ? "48 GB+" : "\(rawValue) GB" }
}

// MARK: - Model family

/// Families differ in how they mark reasoning and which sampling they want.
enum ModelFamily: String, Sendable, Hashable {
    case gemma4
    case qwen35
    case qwen3
    case gemma3
    case phi4
    case embedding

    /// Sampling for free-form chat. Structured output (JSON) always uses
    /// LidIA's low temperature regardless of family.
    var chatSampling: (temperature: Float, topP: Float, topK: Int) {
        switch self {
        case .gemma4:
            // Google's recommended chat sampling for Gemma 4.
            return (1.0, 0.95, 64)
        case .qwen35, .qwen3:
            // Qwen's recommended non-thinking sampling.
            return (0.7, 0.8, 20)
        case .gemma3, .phi4, .embedding:
            return (LLMTemperature.chat, 1.0, 0)
        }
    }
}

// MARK: - Catalogue entry

enum CatalogRole: String, Sendable, Hashable {
    /// The default for its RAM tier.
    case recommended
    /// A listed alternative for its tier.
    case alternate
    /// No longer offered; kept loadable when already on disk.
    case legacy
}

struct ModelCatalogEntry: Identifiable, Sendable, Hashable {
    /// Hugging Face repo ID.
    let id: String
    /// Full commit SHA the app downloads. nil only for legacy entries.
    let revision: String?
    let displayName: String
    let family: ModelFamily
    /// Total repo download in bytes (Hugging Face API, 2026-11-02).
    let downloadBytes: Int64
    /// Minimum Mac memory for a usable experience.
    let minRAMGB: Int
    /// LidIA's context cap in tokens (KV-cache budget, not the model limit).
    let contextCap: Int
    let license: String
    let licenseURL: URL
    let tier: RAMTier
    let role: CatalogRole
    let summary: String

    var downloadGB: Double { Double(downloadBytes) / 1_000_000_000 }
    var modelCardURL: URL { URL(string: "https://huggingface.co/\(id)")! }

    /// Back-compat view used by older call sites.
    var spec: ModelSpec {
        ModelSpec(
            id: id,
            name: displayName,
            description: summary,
            sizeGB: downloadGB,
            ramGB: Double(minRAMGB),
            isDefault: role == .recommended && tier == RAMTier.thisMac
        )
    }
}

// MARK: - Fit

/// How well a model fits this Mac.
enum ModelFit: Sendable, Equatable {
    case recommended
    case fits
    case willBeSlow
    case notEnoughMemory

    var label: String {
        switch self {
        case .recommended: return "Recommended for this Mac"
        case .fits: return "Fits this Mac"
        case .willBeSlow: return "Will be slow"
        case .notEnoughMemory: return "Not enough memory"
        }
    }
}

// MARK: - Catalogue

/// The in-app model catalogue. Kept in the app and updated through releases,
/// so browsing models never makes a network call.
/// Source: docs/research/2026-11-local-llm-byok.md §2.1.
enum ModelCatalog {
    private static let apache = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!

    /// Qwen first: it beat Gemma 4 on the owner's meetings
    /// (docs/research/2026-11-summary-benchmark.md). Order is preference order.
    static let current: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            id: "mlx-community/Qwen3.5-4B-4bit",
            revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
            displayName: "Qwen 3.5 4B",
            family: .qwen35,
            downloadBytes: 3_061_130_647,
            minRAMGB: 8,
            // Hybrid attention: only 8 of 32 layers keep a KV cache (~32 KB/token),
            // so a one-hour meeting fits in one pass even on 8 GB.
            contextCap: 32_768,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb8,
            role: .recommended,
            summary: "Lightweight default. Summary in about a minute for a one-hour meeting."
        ),
        ModelCatalogEntry(
            id: "mlx-community/Qwen3.5-9B-4bit",
            revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53",
            displayName: "Qwen 3.5 9B",
            family: .qwen35,
            downloadBytes: 5_977_073_303,
            minRAMGB: 16,
            contextCap: 65_536,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb16,
            role: .alternate,
            summary: "More detail than 4B, but slower and makes more attribution mistakes."
        ),
        ModelCatalogEntry(
            id: "mlx-community/Qwen3.6-35B-A3B-4bit",
            revision: "38740b847e4cb78f352aba30aa41c76e08e6eb46",
            displayName: "Qwen 3.6 35B-A3B",
            family: .qwen35,
            downloadBytes: 20_429_169_263,
            minRAMGB: 48,
            contextCap: 131_072,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb48,
            role: .recommended,
            summary: "Best on-device notes and fastest writing; uses about 27 GB while summarising."
        ),
        ModelCatalogEntry(
            id: "mlx-community/Qwen3.8-27B-4bit",
            revision: "10c35caafbb80f7dc6a7a432cdd11af10a6d4818",
            displayName: "Qwen 3.8 27B",
            family: .qwen35,
            downloadBytes: 16_081_490_933,
            minRAMGB: 48,
            contextCap: 131_072,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb48,
            role: .alternate,
            summary: "Newest Qwen. Dense, so much slower than 35B-A3B. Not yet benchmarked."
        ),
        ModelCatalogEntry(
            id: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            displayName: "Gemma 4 E4B",
            family: .gemma4,
            downloadBytes: 5_179_241_512,
            minRAMGB: 16,
            contextCap: 32_768,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb16,
            role: .alternate,
            summary: "Fast and careful, but its notes leave out more than Qwen's."
        ),
        ModelCatalogEntry(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
            displayName: "Gemma 4 E2B",
            family: .gemma4,
            downloadBytes: 3_583_088_661,
            minRAMGB: 8,
            contextCap: 16_384,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb8,
            role: .alternate,
            summary: "Very fast, strong multilingual support. Not benchmarked on meetings."
        ),
        ModelCatalogEntry(
            id: "mlx-community/gemma-4-12B-it-4bit",
            revision: "73bcf09092aa277861d5a191b989b666f7f32e8f",
            displayName: "Gemma 4 12B",
            family: .gemma4,
            downloadBytes: 6_773_372_848,
            minRAMGB: 24,
            contextCap: 65_536,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb24,
            role: .alternate,
            summary: "Good for chat over your meeting history. Not benchmarked on meetings."
        ),
        ModelCatalogEntry(
            id: "mlx-community/gemma-4-26b-a4b-it-4bit",
            revision: "0d77464eeb233a2da68ebf9d7dc4edaac7db956d",
            displayName: "Gemma 4 26B-A4B",
            family: .gemma4,
            downloadBytes: 15_373_588_575,
            minRAMGB: 32,
            contextCap: 131_072,
            license: "Apache 2.0",
            licenseURL: apache,
            tier: .gb32,
            role: .alternate,
            summary: "Mixture of experts: near-E4B speed with higher quality. Not benchmarked on meetings."
        ),
    ]

    /// Models offered before November 2026. Not offered for download any
    /// more; shown as "Installed (legacy)" and still loadable when on disk.
    static let legacy: [ModelCatalogEntry] = [
        legacyEntry("mlx-community/Qwen3-4B-Instruct-2507-4bit", "Qwen 3 4B Instruct", .qwen3, gb: 2.3, ram: 8, ctx: 16_384),
        legacyEntry("mlx-community/Phi-4-mini-instruct-4bit", "Phi-4 Mini", .phi4, gb: 2.2, ram: 8, ctx: 16_384),
        legacyEntry("mlx-community/Qwen3-8B-4bit", "Qwen 3 8B", .qwen3, gb: 4.6, ram: 16, ctx: 32_768),
        legacyEntry("mlx-community/gemma-3-4b-it-4bit", "Gemma 3 4B", .gemma3, gb: 3.4, ram: 8, ctx: 16_384),
        legacyEntry("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", "Qwen 3 30B-A3B", .qwen3, gb: 17.2, ram: 32, ctx: 65_536),
    ]

    /// Local embedding model for semantic search (downloaded with the LLM).
    static let embedder = ModelCatalogEntry(
        id: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",
        displayName: "Qwen 3 Embedding 0.6B",
        family: .embedding,
        downloadBytes: 351_233_351,
        minRAMGB: 8,
        contextCap: 8_192,
        license: "Apache 2.0",
        licenseURL: apache,
        tier: .gb8,
        role: .recommended,
        summary: "Small local embedder for semantic search."
    )

    static var all: [ModelCatalogEntry] { current + legacy }

    static func entry(for id: String) -> ModelCatalogEntry? {
        all.first { $0.id == id } ?? (embedder.id == id ? embedder : nil)
    }

    /// The recommended model for a tier. Tiers above 32 GB use the 32 GB pick.
    /// The recommended model for a tier: the recommended entry with the highest
    /// tier that doesn't exceed it (measured picks: Qwen 3.5 4B below 48 GB,
    /// Qwen 3.6 35B-A3B from 48 GB).
    static func recommended(for tier: RAMTier) -> ModelCatalogEntry {
        current
            .filter { $0.role == .recommended && $0.tier <= tier }
            .max { $0.tier < $1.tier }
            ?? current.first { $0.role == .recommended }!
    }

    static var recommendedForThisMac: ModelCatalogEntry {
        recommended(for: .thisMac)
    }

    /// The only MLX model automatic mode may use: the recommended model for
    /// this Mac's memory, and only when it is fully downloaded and verified.
    /// Anything else in the models folder (a partial download, a huge model
    /// someone tried) is ignored; automatic mode then uses Apple Intelligence.
    static func automaticModelID(physicalMemoryBytes: UInt64, isVerified: (ModelCatalogEntry) -> Bool) -> String? {
        let pick = recommended(for: RAMTier.forPhysicalMemory(bytes: physicalMemoryBytes))
        return isVerified(pick) ? pick.id : nil
    }

    /// Models offered for download, best fit first for the given memory.
    static func offered(forPhysicalMemory bytes: UInt64) -> [ModelCatalogEntry] {
        let tier = RAMTier.forPhysicalMemory(bytes: bytes)
        let pick = recommended(for: tier)
        return [pick] + current.filter { $0.id != pick.id }
    }

    static func fit(_ entry: ModelCatalogEntry, physicalMemoryBytes: UInt64) -> ModelFit {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824
        let minRAM = Double(entry.minRAMGB)
        if gb < minRAM * 0.75 { return .notEnoughMemory }
        if gb < minRAM { return .willBeSlow }
        if entry.id == recommended(for: RAMTier.forPhysicalMemory(bytes: physicalMemoryBytes)).id {
            return .recommended
        }
        return .fits
    }

    static func fitForThisMac(_ entry: ModelCatalogEntry) -> ModelFit {
        fit(entry, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    private static func legacyEntry(
        _ id: String, _ name: String, _ family: ModelFamily, gb: Double, ram: Int, ctx: Int
    ) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: id,
            revision: nil,
            displayName: name,
            family: family,
            downloadBytes: Int64(gb * 1_000_000_000),
            minRAMGB: ram,
            contextCap: ctx,
            license: family == .gemma3 ? "Gemma Terms of Use" : family == .phi4 ? "MIT" : "Apache 2.0",
            licenseURL: family == .gemma3
                ? URL(string: "https://ai.google.dev/gemma/terms")!
                : family == .phi4 ? URL(string: "https://opensource.org/license/mit")! : apache,
            tier: RAMTier.forPhysicalMemory(bytes: UInt64(ram) * 1_073_741_824),
            role: .legacy,
            summary: "No longer offered. Still works while installed."
        )
    }
}
