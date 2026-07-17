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
        .library(name: "ApplicationKit", targets: ["ApplicationKit"]),
        .library(name: "ModelStoreKit", targets: ["ModelStoreKit"]),
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "DiarizationKit", targets: ["DiarizationKit"]),
        .library(name: "IntelligenceKit", targets: ["IntelligenceKit"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "AudioPlaybackKit", targets: ["AudioPlaybackKit"]),
        .library(name: "IntegrationsKit", targets: ["IntegrationsKit"]),
        .executable(name: "portavoz-cli", targets: ["portavoz-cli"]),
        .executable(name: "portavoz-app", targets: ["portavoz-app"]),
    ],
    dependencies: [
        // Parakeet ASR + pyannote diarization on CoreML/ANE (Apache-2.0).
        // upToNextMinor on purpose: their public API renames types across
        // minors (0.12 → 0.15 did). 0.15.5 ships the #732 type-checker fix
        // we used to pin by revision.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.15.5")),
        // SQLite toolkit (MIT) — D4: GRDB + FTS5, never SwiftData.
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1")),
        // Whisper on CoreML (MIT) for the quality re-pass (D7). Pinned
        // exact: the package renamed itself at 1.0 and moves API fast.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0"),
        // Auto-updates for the direct-download channel (D10).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMajor(from: "2.9.4")),
        // Embedded local LLM (MLX, MIT) — D25's last mile: summaries on
        // Macs with neither Apple Intelligence nor Ollama. Pinned exact:
        // the LLM API surface moves between minors.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        // Tokenizer runtime for the embedded summarizer: mlx-swift-lm 3.x
        // deliberately decoupled swift-transformers — the app provides it
        // through the MLXHuggingFace macros.
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.3.3")),
    ],
    targets: [
        // Shared domain primitives every Kit builds on.
        .target(name: "PortavozCore"),

        // Application workflows enter through this boundary. Dependencies
        // are added one capability at a time with each extracted use case;
        // trash lifecycle, summary regeneration, and audio import are the
        // first ratcheted capability slices.
        .target(
            name: "ApplicationKit",
            dependencies: [
                "PortavozCore", "TranscriptionKit", "DiarizationKit",
                "IntelligenceKit", "StorageKit",
            ]),

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
        // IntelligenceKit carries the MLX dependency directly (D32): the
        // embedded provider needs the prompt/parsing stack that lives here,
        // and a separate Kit would force moving all of it to Core.
        .target(
            name: "IntelligenceKit",
            dependencies: [
                "PortavozCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]),
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

        // IntegrationsKit is the outbound adapter layer over stored meetings
        // (export, MCP surfaces, RAG retrieval): the ONLY Kit allowed to
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
                "ApplicationKit", "AudioCaptureKit", "PortavozCore", "ModelStoreKit",
                "TranscriptionKit", "DiarizationKit", "IntelligenceKit",
                "StorageKit", "IntegrationsKit", "AudioPlaybackKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),

        .executableTarget(
            name: "portavoz-cli",
            dependencies: [
                "ApplicationKit", "AudioCaptureKit", "PortavozCore", "ModelStoreKit",
                "TranscriptionKit", "DiarizationKit", "IntelligenceKit",
                "StorageKit", "IntegrationsKit", "AudioPlaybackKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .testTarget(
            name: "PortavozTests",
            dependencies: [
                "portavoz-app",
                "ApplicationKit",
                "PortavozCore",
                "ModelStoreKit",
                "AudioCaptureKit",
                "TranscriptionKit",
                "DiarizationKit",
                "IntelligenceKit",
                "StorageKit",
                "AudioPlaybackKit",
                "IntegrationsKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
