// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LidIA",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // 0.13.4+ fixes the Parakeet EOU streaming encoder being fed 63 mel frames instead of
        // 64 (FluidAudio #441), which made every live chunk fail with a CoreML error.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", "0.13.4"..<"0.14.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        // Pinned: the last commit that builds against mlx-swift 0.32.x (required by
        // mlx-swift-lm 3.32.3). Later commits require mlx-swift 0.33.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "d4fa7be1c2fef65ed13a4f73bd58e0a23a0ba307"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(path: "Packages/LidIAKit"),
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "LidIA",
            dependencies: [
                "WhisperKit",
                "FluidAudio",
                "LidIAKit",
                .product(name: "LidIALiveActivity", package: "LidIAKit"),
                .product(name: "LidIAAppIntents", package: "LidIAKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "SpeechEnhancement", package: "speech-swift"),
            ],
            path: "Sources/LidIA",
            // AppShortcuts: App Shortcut phrases per language, copied into the app's
            // Contents/Resources by run.sh (they must sit in the main bundle).
            exclude: ["Resources/LidIA.entitlements", "Resources/Info.plist", "Resources/AppIcon.icns", "Resources/AppShortcuts"],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/en.lproj"),
                .process("Resources/es.lproj"),
            ]
        ),
        .executableTarget(
            name: "LidiaMCP",
            dependencies: [],
            path: "Sources/LidiaMCP",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "LidIATests",
            dependencies: [
                "LidIA",
                "LidIAKit",
                .product(name: "LidIALiveActivity", package: "LidIAKit"),
                .product(name: "LidIAAppIntents", package: "LidIAKit"),
            ],
            path: "Tests/LidIATests",
            // Read straight from disk by the tests (see GranolaImportTests).
            exclude: ["Fixtures"]
        ),
    ]
)
