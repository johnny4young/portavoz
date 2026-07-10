// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Portavoz",
    defaultLocalization: "en",
    platforms: [
        .macOS("14.4"),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PortavozCore", targets: ["PortavozCore"]),
        .library(name: "ModelStoreKit", targets: ["ModelStoreKit"]),
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "DiarizationKit", targets: ["DiarizationKit"]),
        .library(name: "IntelligenceKit", targets: ["IntelligenceKit"]),
        .library(name: "ContextFeedKit", targets: ["ContextFeedKit"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "AudioPlaybackKit", targets: ["AudioPlaybackKit"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .library(name: "IntegrationsKit", targets: ["IntegrationsKit"]),
        .executable(name: "portavoz-cli", targets: ["portavoz-cli"]),
        .executable(name: "portavoz-app", targets: ["portavoz-app"]),
    ],
    dependencies: [
        // Parakeet ASR + pyannote diarization on CoreML/ANE (Apache-2.0).
        // Pinned to the exact commit that fixes a deterministic type-checker
        // timeout in FluidAudioCLI (upstream #732, not yet in a release);
        // return to .upToNextMinor when a release > 0.15.4 ships. Their
        // public API renames types across minors (0.12 → 0.15 did).
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "c367a18e77f9e07a9d0493f6e6fa713d0f774f13"),
        // SQLite toolkit (MIT) — D4: GRDB + FTS5, never SwiftData.
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1")),
        // Whisper on CoreML (MIT) for the quality re-pass (D7). Pinned
        // exact: the package renamed itself at 1.0 and moves API fast.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0"),
        // Auto-updates for the direct-download channel (D10).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMajor(from: "2.9.4")),
    ],
    targets: [
        // Shared domain primitives every Kit builds on.
        .target(name: "PortavozCore"),

        // Curated model registry + sha256-verified downloads, shared by every
        // Kit that loads ML models (transcription, diarization, summaries).
        .target(name: "ModelStoreKit", dependencies: ["PortavozCore"]),

        .target(name: "AudioCaptureKit", dependencies: ["PortavozCore"]),
        .target(
            name: "TranscriptionKit",
            dependencies: [
                "PortavozCore",
                "ModelStoreKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .target(
            name: "DiarizationKit",
            dependencies: [
                "PortavozCore",
                "ModelStoreKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(name: "IntelligenceKit", dependencies: ["PortavozCore"]),
        .target(name: "ContextFeedKit", dependencies: ["PortavozCore"]),
        .target(
            name: "StorageKit",
            dependencies: [
                "PortavozCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // Synchronized meeting playback (M11/D27): mixes the per-channel
        // audio into one timeline, generates waveforms, exports clips.
        .target(name: "AudioPlaybackKit", dependencies: ["PortavozCore"]),

        .target(name: "SyncKit", dependencies: ["PortavozCore"]),
        // IntegrationsKit is the cross-cutting layer over stored meetings
        // (export, MCP-ish surfaces, RAG retrieval): the ONLY Kit allowed to
        // depend on sibling Kits (IntelligenceKit + StorageKit, D31).
        .target(
            name: "IntegrationsKit",
            dependencies: ["PortavozCore", "IntelligenceKit", "StorageKit"]),

        // The macOS app shell (M5). Built as a plain SPM executable and
        // wrapped into Portavoz.app by scripts/make-app.sh (D20); shipping
        // remains script-built, while project.yml exists only for XCUITest (D30).
        .executableTarget(
            name: "portavoz-app",
            dependencies: [
                "AudioCaptureKit", "PortavozCore", "ModelStoreKit",
                "TranscriptionKit", "DiarizationKit", "IntelligenceKit",
                "StorageKit", "IntegrationsKit", "AudioPlaybackKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),

        .executableTarget(
            name: "portavoz-cli",
            dependencies: [
                "AudioCaptureKit", "PortavozCore", "ModelStoreKit",
                "TranscriptionKit", "DiarizationKit", "IntelligenceKit",
                "StorageKit", "IntegrationsKit",
            ]
        ),

        .testTarget(
            name: "PortavozTests",
            dependencies: [
                "PortavozCore",
                "ModelStoreKit",
                "AudioCaptureKit",
                "TranscriptionKit",
                "DiarizationKit",
                "IntelligenceKit",
                "ContextFeedKit",
                "StorageKit",
                "AudioPlaybackKit",
                "SyncKit",
                "IntegrationsKit",
            ]
        ),
    ]
)
