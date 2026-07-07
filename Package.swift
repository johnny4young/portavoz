// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Portavoz",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PortavozCore", targets: ["PortavozCore"]),
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "DiarizationKit", targets: ["DiarizationKit"]),
        .library(name: "IntelligenceKit", targets: ["IntelligenceKit"]),
        .library(name: "ContextFeedKit", targets: ["ContextFeedKit"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .library(name: "IntegrationsKit", targets: ["IntegrationsKit"]),
        .executable(name: "portavoz-cli", targets: ["portavoz-cli"]),
    ],
    targets: [
        // Shared domain primitives every Kit builds on.
        .target(name: "PortavozCore"),

        .target(name: "AudioCaptureKit", dependencies: ["PortavozCore"]),
        .target(name: "TranscriptionKit", dependencies: ["PortavozCore"]),
        .target(name: "DiarizationKit", dependencies: ["PortavozCore"]),
        .target(name: "IntelligenceKit", dependencies: ["PortavozCore"]),
        .target(name: "ContextFeedKit", dependencies: ["PortavozCore"]),
        .target(name: "StorageKit", dependencies: ["PortavozCore"]),
        .target(name: "SyncKit", dependencies: ["PortavozCore"]),
        .target(name: "IntegrationsKit", dependencies: ["PortavozCore", "IntelligenceKit"]),

        .executableTarget(
            name: "portavoz-cli",
            dependencies: ["AudioCaptureKit", "PortavozCore"]
        ),

        .testTarget(
            name: "PortavozTests",
            dependencies: [
                "PortavozCore",
                "AudioCaptureKit",
                "TranscriptionKit",
                "DiarizationKit",
                "IntelligenceKit",
                "ContextFeedKit",
                "StorageKit",
                "SyncKit",
                "IntegrationsKit",
            ]
        ),
    ]
)
