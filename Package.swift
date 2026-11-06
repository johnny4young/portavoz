// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Portavoz",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "PortavozCore", targets: ["PortavozCore"]),
        .library(name: "ApplicationKit", targets: ["ApplicationKit"]),
        .library(name: "PlatformKit", targets: ["PlatformKit"]),
        .library(name: "ModelStoreKit", targets: ["ModelStoreKit"]),
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "DiarizationKit", targets: ["DiarizationKit"]),
        .library(name: "IntelligenceKit", targets: ["IntelligenceKit"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "AudioPlaybackKit", targets: ["AudioPlaybackKit"]),
        .library(name: "PortavozCLIKit", targets: ["PortavozCLIKit"]),
        .library(name: "IntegrationsKit", targets: ["IntegrationsKit"]),
        .executable(name: "portavoz-cli", targets: ["portavoz-cli"]),
        .executable(name: "portavoz-app", targets: ["portavoz-app"]),
    ],
    traits: [
        // The embedded summarizer (D32). Lanes that never generate pass
        // --disable-default-traits and skip compiling MLX and its C++.
        .trait(name: "EmbeddedMLX", description: "The embedded MLX summarizer."),
        .default(enabledTraits: ["EmbeddedMLX"]),
    ],
    dependencies: [
        // Parakeet ASR + pyannote diarization on CoreML/ANE (Apache-2.0).
        // Exact on purpose (D516): patch releases also change decoder and
        // caption behavior, so an upgrade needs matched ASR, diarization and
        // resource evidence. A minor bump is categorically riskier still —
        // FluidAudio renames public types across minors (0.12 → 0.15 did).
        // Latest upstream plus an explicit raw-token revision contract.
        // Evaluation candidate: no new models, unused TTS/NeMo are not linked.
        .package(
            url: "https://github.com/johnny4young/FluidAudio.git",
            revision: "16ff239818ddb6787629dab38ae43e8bdd0e7546",
            traits: ["Diarizer"]),
        // Cooperative dictation ownership (MIT), shared with Secreteo. Leaves with dictation in 2.0.
        .package(
            url: "https://github.com/johnny4young/secreteo.git",
            revision: "9f1015452ae92eeb023793c37d95d60ae7a33ef6"),
        // The on-disk model store shared with Secreteo (MIT).
        .package(url: "https://github.com/johnny4young/local-model-store.git", exact: "0.1.3"),
        // SQLite toolkit (MIT) — D4: GRDB + FTS5, never SwiftData.
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1")),
        // Whisper on CoreML (MIT) for the quality re-pass (D7). Pinned
        // exact: the package renamed itself at 1.0 and moves API fast.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Auto-updates for the direct-download channel (D10).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMajor(from: "2.10.1")),
        // Embedded local LLM (MLX, MIT) — D25's last mile: summaries on
        // Macs with neither Apple Intelligence nor Ollama. Pinned exact:
        // the LLM API surface moves between minors. No default traits: the
        // FoundationModels adapter and its grammar engine stay out of the app.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3", traits: []),
        // Tokenizer runtime for the embedded summarizer: mlx-swift-lm 3.x
        // deliberately decoupled swift-transformers — the app provides it
        // through the MLXHuggingFace macros.
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.3.5")),
    ],
    targets: [
        // Shared domain primitives every Kit builds on.
        .target(name: "PortavozCore"),

        // Concrete Apple platform/security adapters. Core owns only the ports;
        // executable composition roots inject these implementations.
        .target(name: "PlatformKit", dependencies: ["PortavozCore"]),

        // Application workflows enter through this boundary. Dependencies
        // are added one capability at a time with each extracted use case;
        // local Ask now joins lifecycle, processing, reads, import, and export.
        .target(
            name: "ApplicationKit",
            dependencies: [
                "PortavozCore", "AudioPlaybackKit", "TranscriptionKit",
                "DiarizationKit", "IntelligenceKit", "StorageKit",
            ]),

        // Curated model registry + sha256-verified downloads, shared by every
        // Kit that loads ML models (transcription, diarization, summaries).
        .target(
            name: "ModelStoreKit",
            dependencies: ["PortavozCore", .product(name: "LocalModelStore", package: "local-model-store")]),

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
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["EmbeddedMLX"])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["EmbeddedMLX"])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(traits: ["EmbeddedMLX"])),
                .product(name: "Transformers", package: "swift-transformers", condition: .when(traits: ["EmbeddedMLX"])),
            ],
            resources: [
                .copy("Resources/PortavozLiveQuestionClassifier.mlmodelc"),
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
        // Self-contained over AVFoundation/Accelerate: it exposes no Core
        // types, so it carries no module dependencies.
        .target(name: "AudioPlaybackKit", dependencies: []),

        // D212 research-only static sqlite-vec probe. It is intentionally not
        // a product dependency: only PortavozKitTests compiles this boundary.
        .target(
            name: "CSQLiteVecResearch",
            path: "Sources/CSQLiteVecResearch",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // D213 disposable exact ranker. A test-owned adapter implements the
        // ApplicationKit shadow port; this capability remains a lower layer.
        .target(
            name: "SQLiteVecResearchKit",
            dependencies: [
                "PortavozCore", "StorageKit",
                "CSQLiteVecResearch",
            ]
        ),

        // IntegrationsKit is the outbound-adapter layer over stored meetings
        // (export, MCP protocol, providers, private sync transport). Application
        // orchestration belongs to ApplicationKit, including local Ask.
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
                "PlatformKit",
                "TranscriptionKit", "DiarizationKit", "IntelligenceKit",
                "StorageKit", "IntegrationsKit", "AudioPlaybackKit", "PortavozCLIKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "DictationOwnership", package: "secreteo"),
            ]
        ),

        // The command-line tool is a library so the app executable can serve
        // it too when invoked as `portavoz-cli` (D582); the sources stay put.
        .target(
            name: "PortavozCLIKit",
            dependencies: [
                "ApplicationKit", "AudioCaptureKit", "PortavozCore", "ModelStoreKit",
                "PlatformKit",
                "TranscriptionKit", "DiarizationKit", "IntelligenceKit",
                "StorageKit", "IntegrationsKit", "AudioPlaybackKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/portavoz-cli"
        ),

        .executableTarget(
            name: "portavoz-cli",
            dependencies: ["PortavozCLIKit"],
            path: "Sources/portavoz-cli-main"
        ),

        // Doubles and fixtures both test modules share. It belongs to no product.
        .target(
            name: "PortavozTestSupport",
            dependencies: [
                "ApplicationKit",
                "DiarizationKit",
                "IntelligenceKit",
                "ModelStoreKit",
                "PlatformKit",
                "PortavozCore",
                "StorageKit",
                "TranscriptionKit",
            ],
            path: "Tests/PortavozTestSupport"
        ),
        // Without the app module, so an app change never recompiles these.
        .testTarget(
            name: "PortavozKitTests",
            dependencies: [
                "PortavozCLIKit",
                "PortavozTestSupport",
                "ApplicationKit",
                "PortavozCore",
                "PlatformKit",
                "ModelStoreKit",
                "AudioCaptureKit",
                "TranscriptionKit",
                "DiarizationKit",
                "IntelligenceKit",
                "StorageKit",
                "AudioPlaybackKit",
                "IntegrationsKit",
                "CSQLiteVecResearch",
                "SQLiteVecResearchKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests",
            exclude: [
                "PortavozAppTests", "PortavozTestSupport", "PortavozUITests", "PortavozDictationReceiver",
                "UIInterruptionFixtures", "Tooling", "DictationPeer",
            ],
            sources: ["PortavozKitTests", "Support"]
        ),
        // Another dictation app on the same Mac, for the coexistence tests. Leaves with dictation in 2.0.
        .executableTarget(
            name: "dictation-peer",
            dependencies: [.product(name: "DictationOwnership", package: "secreteo")],
            path: "Tests/DictationPeer"
        ),
        .testTarget(
            name: "PortavozAppTests",
            dependencies: [
                "portavoz-app",
                "dictation-peer",
                "PortavozCLIKit",
                "PortavozTestSupport",
                "ApplicationKit",
                "PortavozCore",
                "PlatformKit",
                "ModelStoreKit",
                "AudioCaptureKit",
                "TranscriptionKit",
                "DiarizationKit",
                "IntelligenceKit",
                "StorageKit",
                "IntegrationsKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/PortavozAppTests"
        ),
    ]
)
