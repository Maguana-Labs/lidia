// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LidIAKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "LidIAKit", targets: ["LidIAKit"]),
        // Live-Activity-shaped state for the Mac menu bar (and a future ActivityKit
        // Live Activity). Foundation only, so any app or extension can compile it.
        .library(name: "LidIALiveActivity", targets: ["LidIALiveActivity"]),
        /// On-device meeting notes and Ask: prompts, context fitting and the
        /// Apple Foundation Models generator. Used by the iOS app; the Mac keeps
        /// its own pipeline in Sources/LidIA/Pipeline for now.
        .library(name: "LidIAIntelligence", targets: ["LidIAIntelligence"]),
        /// Siri and Shortcuts: the app entities (meetings, action items, people,
        /// projects), their queries, the privacy policy and the intents both the
        /// Mac and the iPhone offer. Each app adds its own recording intents and
        /// plugs in a `LidIASiriHost`. See docs/siri.md.
        .library(name: "LidIAAppIntents", targets: ["LidIAAppIntents"]),
    ],
    targets: [
        .target(
            name: "LidIAKit",
            path: "Sources/LidIAKit"
        ),
        .target(
            name: "LidIALiveActivity",
            path: "Sources/LidIALiveActivity"
        ),
        .target(
            name: "LidIAIntelligence",
            path: "Sources/LidIAIntelligence"
        ),
        .target(
            name: "LidIAAppIntents",
            dependencies: ["LidIAKit"],
            path: "Sources/LidIAAppIntents"
        ),
        .testTarget(
            name: "LidIAKitTests",
            dependencies: ["LidIAKit"],
            path: "Tests/LidIAKitTests"
        ),
        .testTarget(
            name: "LidIAIntelligenceTests",
            dependencies: ["LidIAIntelligence"],
            path: "Tests/LidIAIntelligenceTests"
        ),
    ]
)
