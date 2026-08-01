import ApplicationKit
import Foundation
import XCTest

final class ArchitectureDependencyTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testPackageExposesOnlyImplementedKitBoundaries() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let targets = try TargetManifestParser.declarations(in: manifest)

        for name in ["ContextFeedKit", "SyncKit"] {
            XCTAssertNil(
                targets[name],
                "Speculative package target \(name) must not return without a vertical use case")
            XCTAssertFalse(
                manifest.contains(#".library(name: "\#(name)""#),
                "Speculative package product \(name) must not return without a vertical use case")
        }
    }

    func testApplicationKitManifestBoundaryAdmitsOnlyExtractedCapabilities() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let targets = try TargetManifestParser.declarations(in: manifest)
        let application = try XCTUnwrap(targets["ApplicationKit"])

        XCTAssertEqual(
            application.dependencies,
            [
                "AudioPlaybackKit", "DiarizationKit", "IntelligenceKit",
                "PortavozCore", "StorageKit", "TranscriptionKit",
            ])
        XCTAssertTrue(try XCTUnwrap(targets["portavoz-app"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["portavoz-cli"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["PortavozTests"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(manifest.contains(
            #".library(name: "ApplicationKit", targets: ["ApplicationKit"])"#))
        XCTAssertTrue(try Self.contents(of: "project.yml").contains("- ApplicationKit"))
    }

    func testCapabilityTargetsNeverDependBackOnApplicationKit() throws {
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))
        let allowedConsumers = Set([
            "ApplicationKit", "portavoz-app", "portavoz-cli", "PortavozTests",
        ])
        let violations = targets.values
            .filter { !allowedConsumers.contains($0.name) }
            .filter { $0.dependencies.contains("ApplicationKit") }
            .map(\.name)
            .sorted()

        XCTAssertTrue(
            violations.isEmpty,
            "Capability targets must not depend on ApplicationKit: \(violations)")
    }

    func testProductionTargetGraphMatchesTheCurrentArchitecture() throws {
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))
        let productionTargets = Set([
            "PortavozCore", "ApplicationKit", "PlatformKit", "ModelStoreKit",
            "AudioCaptureKit", "TranscriptionKit", "DiarizationKit",
            "IntelligenceKit", "StorageKit", "AudioPlaybackKit",
            "IntegrationsKit", "portavoz-app", "portavoz-cli",
        ])
        let expected: [String: Set<String>] = [
            "PortavozCore": [],
            "PlatformKit": ["PortavozCore"],
            "ModelStoreKit": ["PortavozCore"],
            "AudioCaptureKit": ["PortavozCore"],
            "TranscriptionKit": ["ModelStoreKit", "PortavozCore"],
            "DiarizationKit": ["ModelStoreKit", "PortavozCore"],
            "IntelligenceKit": ["PortavozCore"],
            "StorageKit": ["PortavozCore"],
            "AudioPlaybackKit": [],
            "IntegrationsKit": ["IntelligenceKit", "PortavozCore", "StorageKit"],
            "ApplicationKit": [
                "AudioPlaybackKit", "DiarizationKit", "IntelligenceKit",
                "PortavozCore", "StorageKit", "TranscriptionKit",
            ],
            "portavoz-app": productionTargets.subtracting(["portavoz-app", "portavoz-cli"]),
            "portavoz-cli": productionTargets.subtracting(["portavoz-app", "portavoz-cli"]),
        ]

        XCTAssertEqual(Set(expected.keys), productionTargets)
        for (target, expectedDependencies) in expected {
            let declaration = try XCTUnwrap(targets[target], target)
            XCTAssertEqual(
                declaration.dependencies.intersection(productionTargets),
                expectedDependencies,
                "\(target) drifted from the implemented dependency graph")
        }
    }

    func testSwiftUIPresentationDoesNotConstructCapabilitiesOrCallPersistence() throws {
        let viewFiles = Set(try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\bstruct\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*<[^>]+>)?\s*:\s*View\b"#))
        XCTAssertFalse(viewFiles.isEmpty)

        let concreteCapabilities = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\b(?:MeetingStore|ModelStore|ParakeetEngine|WhisperEngine|PyannoteDiarizer|MLXSummaryProvider|FoundationModelSummaryProvider|OllamaService|MeetingPlayer|AudioTranscoder|AudioClipExporter|MicrophoneSource|RecordingSession|KeychainSecretStore|CalendarAttendeeSource|URLSessionDataEgressGateway|GistPublisher|MeetingExporter|VoiceGallery|VoiceprintStore)\s*\("#)
        let persistenceCalls = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\b(?:services\.)?store\.[A-Za-z_][A-Za-z0-9_]*\s*\("#)
        let forbiddenFrameworkImports = try Self.imports(under: "Sources/portavoz-app")
            .filter { viewFiles.contains($0.file) }
            .filter {
                [
                    "AVFoundation", "CloudKit", "CoreAudio", "EventKit",
                    "GRDB", "Network", "Security",
                ].contains($0.module)
            }
            .map { "\($0.file): \($0.module)" }
            .sorted()

        XCTAssertTrue(
            viewFiles.intersection(concreteCapabilities).isEmpty,
            "SwiftUI presentation constructed a concrete capability: \(concreteCapabilities)")
        XCTAssertTrue(
            viewFiles.intersection(persistenceCalls).isEmpty,
            "SwiftUI presentation called persistence directly: \(persistenceCalls)")
        XCTAssertTrue(
            forbiddenFrameworkImports.isEmpty,
            "SwiftUI presentation imported an adapter framework: \(forbiddenFrameworkImports)")
    }

    func testCurrentSDKDiagnosticsStayClosedAtFrameworkBoundaries() throws {
        let focused = try Self.contents(
            of: "Sources/portavoz-app/FocusedTranscriptView.swift")
        let mlx = try Self.contents(
            of: "Sources/IntelligenceKit/MLXSummaryProvider.swift")
        let speech = try Self.contents(
            of: "Sources/TranscriptionKit/SpeechAnalyzerEngine.swift")
        let exporter = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingExporter.swift")
        let showcase = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Showcase.swift")
        let translation = try Self.contents(
            of: "Sources/portavoz-app/LiveTranslation.swift")
        let ci = try Self.contents(of: ".github/workflows/ci.yml")
        let ios = try Self.contents(of: "docs/IOS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(focused.contains(".scrollView(axis: .vertical)"))
        XCTAssertFalse(focused.contains(".named(space)"))
        XCTAssertFalse(focused.contains(".coordinateSpace(.named("))
        XCTAssertTrue(mlx.contains("MLX.Memory.cacheLimit ="))
        XCTAssertFalse(mlx.contains("MLX.GPU.set(cacheLimit:"))
        XCTAssertTrue(speech.contains("AudioConverterInputBox: @unchecked Sendable"))
        XCTAssertTrue(speech.contains("private let lock = NSLock()"))
        XCTAssertTrue(speech.contains("input.nextBuffer(status: status)"))
        XCTAssertFalse(speech.contains("@preconcurrency import AVFoundation"))
        XCTAssertFalse(speech.contains("var fed = false"))
        XCTAssertFalse(exporter.contains("let bold = CTFontCreateWithName"))
        XCTAssertTrue(showcase.contains("_ = try? await store.saveSummary"))
        XCTAssertTrue(translation.contains("status = await availability.status("))
        XCTAssertFalse(translation.contains("try? await availability.status("))
        XCTAssertTrue(ci.contains("run: swift build -Xswiftc -warnings-as-errors"))
        XCTAssertTrue(ios.contains("destination supports"))
        XCTAssertTrue(decisions.contains("## D118"))
        XCTAssertTrue(decisions.contains("## D119"))
    }

    func testCoreForbiddenImportsRemainAtDocumentedBaseline() throws {
        let forbidden = Set([
            "AppKit", "SwiftUI", "GRDB", "Security", "Network", "FoundationNetworking",
            "OSLog",
        ])
        let actual = try Self.imports(under: "Sources/PortavozCore")
            .filter { forbidden.contains($0.module) }
            .reduce(into: [String: [String]]()) { result, item in
                result[item.module, default: []].append(item.file)
            }
            .mapValues { $0.sorted() }

        XCTAssertTrue(
            actual.isEmpty,
            "Core must contain ports and domain values, never platform frameworks: \(actual)")
    }

    func testResourceWorkloadTelemetryRemainsContentFreeAndOutsideAudioCallbacks() throws {
        let contract = try Self.contents(
            of: "Sources/PortavozCore/ResourceWorkload.swift")
        guard let descriptorStart = contract.range(
            of: "public struct ResourceWorkloadDescriptor"),
            let spanStart = contract.range(
                of: "public struct ResourceWorkloadSpan",
                range: descriptorStart.upperBound..<contract.endIndex)
        else {
            return XCTFail("Resource workload descriptor boundary is missing")
        }
        let descriptor = contract[
            descriptorStart.lowerBound..<spanStart.lowerBound]
        for forbidden in [
            "String", "URL", "MeetingID", "Transcript", "modelID", "path", "Error",
        ] {
            XCTAssertFalse(
                descriptor.contains(forbidden),
                "Workload descriptors must not admit content field \(forbidden)")
        }

        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppResourceWorkloadTelemetry.swift")
        for forbidden in [
            "MeetingID", "TranscriptSegment", "URL", "localizedDescription",
            "modelID", "relativePath", "Logger(",
        ] {
            XCTAssertFalse(
                adapter.contains(forbidden),
                "Platform telemetry must not record \(forbidden)")
        }
        XCTAssertTrue(adapter.contains("workloadClass.rawValue"))
        XCTAssertTrue(adapter.contains("kind.rawValue"))
        XCTAssertTrue(adapter.contains("operation.rawValue"))
        XCTAssertTrue(adapter.contains("outcome.rawValue"))
        XCTAssertFalse(adapter.contains("span.id, privacy:"))

        let audioCallbackInstrumentation = try Self.sourceMatches(
            under: "Sources/AudioCaptureKit",
            pattern: #"ResourceWorkload(?:Telemetry|Descriptor|Event|Span)"#)
        XCTAssertTrue(
            audioCallbackInstrumentation.isEmpty,
            "Measurement must never enter capture callbacks: \(audioCallbackInstrumentation)")

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Resource measurement preserves those owners"))
        XCTAssertTrue(decisions.contains("## D148"))
        XCTAssertTrue(appSpec.contains(
            "### Resource workload measurement (D148)"))
    }

    func testAskPipelineTelemetryRemainsContentFreeAndPlatformRecorded() throws {
        let contract = try Self.contents(
            of: "Sources/ApplicationKit/AskPipelineTelemetry.swift")
        guard let identityStart = contract.range(
            of: "public struct AskPipelineTraceIdentity"),
            let traceStart = contract.range(
                of: "public struct AskPipelineTrace:",
                range: identityStart.upperBound..<contract.endIndex)
        else {
            return XCTFail("Ask pipeline telemetry boundary is missing")
        }
        let eventContract = contract[
            identityStart.lowerBound..<traceStart.lowerBound]
        for forbidden in [
            "String", "URL", "MeetingID", "Transcript", "question",
            "citation", "model", "path", "Error",
        ] {
            XCTAssertFalse(
                eventContract.contains(forbidden),
                "Ask telemetry events must not admit content field \(forbidden)")
        }

        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppAskPipelineTelemetry.swift")
        for forbidden in [
            "MeetingID", "TranscriptSegment", "URL", "localizedDescription",
            "modelID", "relativePath", "Logger(",
        ] {
            XCTAssertFalse(
                adapter.contains(forbidden),
                "Platform Ask telemetry must not record \(forbidden)")
        }
        XCTAssertTrue(adapter.contains("operation.rawValue"))
        XCTAssertTrue(adapter.contains("stage.rawValue"))
        XCTAssertTrue(adapter.contains("milestone.rawValue"))
        XCTAssertTrue(adapter.contains("outcome.rawValue"))
        XCTAssertFalse(adapter.contains("trace.id, privacy:"))

        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        XCTAssertTrue(composition.contains("pipelineTelemetry: AskPipelineTelemetry"))
        XCTAssertTrue(composition.contains("pipelineTelemetry: pipelineTelemetry"))

        let benchmarkProbe = try Self.contents(
            of: "Sources/portavoz-app/AskPipelineRunProbe.swift")
        guard let sampleStart = benchmarkProbe.range(
            of: "struct AskPipelineTiming"),
            let errorStart = benchmarkProbe.range(
                of: "enum AskPipelineRunProbeError")
        else {
            return XCTFail("Ask pipeline benchmark receipt is missing")
        }
        let receiptContract = benchmarkProbe[
            sampleStart.lowerBound..<errorStart.lowerBound]
        for forbidden in [
            "question", "meetingTitle", "Transcript", "generatedText",
            "segmentID", "model", "path", "URL",
        ] {
            XCTAssertFalse(
                receiptContract.contains(forbidden),
                "Ask benchmark receipts must not admit content field \(forbidden)")
        }
        XCTAssertTrue(benchmarkProbe.contains("AskPipelineStage.allCases"))
        XCTAssertTrue(benchmarkProbe.contains("pendingAtSeed"))
        XCTAssertTrue(benchmarkProbe.contains("pendingBefore"))
        XCTAssertTrue(benchmarkProbe.contains("readyAfter"))
        XCTAssertTrue(benchmarkProbe.contains("outputAlreadyExists"))

        let qualityHarness = try Self.contents(of: "scripts/ask_quality.py")
        for required in [
            "RELATIONSHIP_COUNTS", "RETRIEVAL_FLOORS", "ANSWER_FLOORS",
            "exactFactsRankFirst", "retrievalQualityFloor",
            "answerQualityFloor", "citationsCanonical",
            "hardNegativesExcluded", "adapter", "commit",
        ] {
            XCTAssertTrue(
                qualityHarness.contains(required),
                "Ask quality contract is missing \(required)")
        }
        XCTAssertFalse(qualityHarness.contains("generatedText"))

        let productionAdapter = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchAskQuality.swift")
        for required in [
            "LocalAskMeetingRetrieval", "MeetingStore(",
            "local-hybrid-preindexed-no-expansion-evidence-v2", "notEvaluated",
            "transcriptRevision", "outputAlreadyExists",
        ] {
            XCTAssertTrue(
                productionAdapter.contains(required),
                "Ask production observation adapter is missing \(required)")
        }
        XCTAssertFalse(productionAdapter.contains("RecordingsLocation.default"))

        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        XCTAssertTrue(decisions.contains("## D194"))
        XCTAssertTrue(decisions.contains("## D195"))
        XCTAssertTrue(quality.contains(
            "The same run must emit a content-free pipeline sidecar"))
        XCTAssertTrue(quality.contains("exactly 240 judged queries"))
        XCTAssertTrue(quality.contains("portavoz-cli bench-ask-quality"))
    }

    func testResourceGovernorPolicyRemainsPureExplicitAndOutsideAudioCallbacks() throws {
        let policy = try Self.contents(
            of: "Sources/PortavozCore/ResourceGovernorPolicy.swift")
        for required in [
            "public struct ResourceGovernorPolicy: Sendable",
            "public struct ResourceGovernorSnapshot: Equatable, Sendable",
            "public enum ResourceAdmissionDisposition: Equatable, Sendable",
            "case admitNow",
            "case admitWithReducedConcurrency",
            "case `defer`(until: ResourceDeferralCondition)",
            "case pauseAfterCheckpoint",
            "case reject(recovery: ResourceRecoveryAction)",
            "public let evictIdleModels: [ResourceModelFamily]",
            "public let measuredFootprintBytes: UInt64?"
        ] {
            XCTAssertTrue(policy.contains(required), "Missing GOV-1 contract: \(required)")
        }
        for forbidden in [
            "import AppKit", "import Foundation", "ProcessInfo", "FileManager",
            "DispatchQueue", "NSLock", "Task {", " async ", " await ", "sleep(",
            "MeetingID", "TranscriptSegment", "URL"
        ] {
            XCTAssertFalse(
                policy.contains(forbidden),
                "Core resource policy must not own runtime operation \(forbidden)")
        }

        let audioCallbackPolicy = try Self.sourceMatches(
            under: "Sources/AudioCaptureKit",
            pattern: #"ResourceGovernor(?:Policy|Decision|Snapshot|Request)"#)
        XCTAssertTrue(
            audioCallbackPolicy.isEmpty,
            "Resource policy must never enter capture callbacks: \(audioCallbackPolicy)")

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Core also owns one pure resource-admission policy"))
        XCTAssertTrue(decisions.contains("## D157"))
        XCTAssertTrue(appSpec.contains(
            "### Pure resource admission policy (D157)"))
    }

    func testModelResidencyLedgerIsPureGenerationFencedAndRuntimeFree() throws {
        let ledger = try Self.contents(
            of: "Sources/PortavozCore/ResourceModelResidency.swift")
        for required in [
            "public struct ResourceModelResidencyLedger: Equatable, Sendable",
            "public enum ResourceModelResidencyStatus: String, CaseIterable, Sendable",
            "public let activeUseCount: Int",
            "public mutating func beginLoad(",
            "public mutating func beginUse(",
            "public mutating func beginRelease(",
            "entry.transitionGeneration == ticket.generation",
            "entry.activeUses.remove(lease.generation)",
            "public var residentModels: [ResourceResidentModel]",
        ] {
            XCTAssertTrue(
                ledger.contains(required),
                "Missing residency lifecycle contract: \(required)")
        }
        for forbidden in [
            "import ", "Task", "Duration", "sleep(", "ProcessInfo",
            "FileManager", "ModelStore", "Parakeet", "Whisper", "Pyannote",
            "MLX", "SentenceEmbedder", "URL",
        ] {
            XCTAssertFalse(
                ledger.contains(forbidden),
                "Core residency state must not own runtime operation \(forbidden)")
        }

        let audioCallbackResidency = try Self.sourceMatches(
            under: "Sources/AudioCaptureKit",
            pattern: #"ResourceModelResidency(?:Ledger|Record|Status)"#)
        XCTAssertTrue(
            audioCallbackResidency.isEmpty,
            "Model residency state must never enter capture callbacks: \(audioCallbackResidency)")

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Core additionally owns a pure model-residency lifecycle ledger"))
        XCTAssertTrue(decisions.contains("## D158"))
        XCTAssertTrue(appSpec.contains(
            "### Pure model-residency lifecycle (D158)"))
    }

    func testModelResidencyHasOneCompositionOwnerAndNoRuntimeBypasses() throws {
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let liveSpeech = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LiveSpeechModels.swift")
        let whisper = try Self.contents(
            of: "Sources/portavoz-app/AppServices+WhisperModels.swift")
        let mlx = try Self.contents(
            of: "Sources/IntelligenceKit/MLXSummaryProvider.swift")
        let ask = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let library = try Self.contents(
            of: "Sources/ApplicationKit/LocalLibrarySemanticSearch.swift")

        XCTAssertTrue(services.contains(
            "@ObservationIgnored let modelResidencyLedger ="))
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources",
                pattern: #"ResourceModelResidencyLedger\s*\(\s*\)"#),
            ["portavoz-app/AppModelResidencyLedger.swift"])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources",
                pattern: #"modelResidencyLedger\."#),
            [
                "portavoz-app/AppSemanticEmbeddingRuntime.swift",
                "portavoz-app/AppServices+DiarizationModels.swift",
                "portavoz-app/AppServices+LiveSpeechModels.swift",
                "portavoz-app/AppServices+MLXModels.swift",
                "portavoz-app/AppServices+ResourceGovernor.swift",
                "portavoz-app/AppServices+WhisperModels.swift",
            ],
            "Only runtime adapters and the governor coordinator may report residency")

        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"ParakeetEngine\.loadRecommended"#),
            ["AppServices+LiveSpeechModels.swift"])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"WhisperEngine\.loadPrepared"#),
            ["AppServices+WhisperModels.swift"])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"PyannoteDiarizer\.loadRecommended"#),
            [])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"PyannoteDiarizationRuntime\.loadRecommended"#),
            ["AppServices+DiarizationModels.swift"])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/ApplicationKit",
                pattern: #"SentenceEmbedder\s*\("#),
            [],
            "Application workflows must receive an injected embedding runtime")
        XCTAssertTrue(whisper.contains("Task.sleep(for: .seconds(120))"))
        XCTAssertTrue(services.contains("Task.sleep(for: .seconds(600))"))
        XCTAssertTrue(liveSpeech.contains("modelResidencyLedger.beginUse(.liveSpeech)"))
        XCTAssertTrue(mlx.contains("private static let idleRelease: Duration = .seconds(120)"))
        XCTAssertFalse(mlx.contains("static let shared"))
        XCTAssertTrue(services.contains(
            "@ObservationIgnored let mlxSummaryRuntime = MLXSummaryRuntime()"))
        XCTAssertTrue(services.contains(
            "@ObservationIgnored let semanticEmbeddingRuntime:"))
        XCTAssertTrue(ask.contains(
            "private let runtime: any SemanticEmbeddingRuntimeClient"))
        XCTAssertTrue(library.contains(
            "private let runtime: any SemanticEmbeddingRuntimeClient"))

        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(decisions.contains("## D159"))
        XCTAssertTrue(appSpec.contains("#### Characterized runtime topology"))
    }

    func testSemanticEmbeddingRuntimePinsAskLibraryAndResourceBenchmarks() throws {
        let protocolSource = try Self.contents(
            of: "Sources/ApplicationKit/IndexSemanticCorpus.swift")
        let runtime = try Self.contents(
            of: "Sources/portavoz-app/AppSemanticEmbeddingRuntime.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let ask = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let library = try Self.contents(
            of: "Sources/ApplicationKit/LocalLibrarySemanticSearch.swift")
        let indexingBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceIndexing.swift")
        let askBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode.swift")

        XCTAssertTrue(protocolSource.contains(
            "public protocol SemanticEmbeddingRuntimeClient: Sendable"))
        XCTAssertTrue(protocolSource.contains(
            "func withPreparedEmbedding<Result: Sendable>("))
        XCTAssertTrue(services.contains(
            "semanticRuntime: semanticEmbeddingRuntime"))

        for transition in [
            "modelResidencyLedger.beginLoad(.semanticEmbedding)",
            "modelResidencyLedger.finishLoad(",
            "modelResidencyLedger.finishLoadAndBeginUse(",
            "modelResidencyLedger.failLoad(",
            "modelResidencyLedger.beginUse(.semanticEmbedding)",
            "modelResidencyLedger.finishUse(",
            "modelResidencyLedger.beginRelease(.semanticEmbedding)",
            "modelResidencyLedger.finishRelease(",
            "modelResidencyLedger.cancelRelease(",
            "actor AppSemanticEmbeddingRuntime",
        ] {
            XCTAssertTrue(
                runtime.contains(transition),
                "Semantic residency adapter is missing \(transition)")
        }
        for borrower in [ask, library, indexingBench] {
            XCTAssertTrue(borrower.contains(
                "withPreparedEmbedding("))
        }
        XCTAssertTrue(askBench.contains(
            "semanticRuntime: services.semanticEmbeddingRuntime"))
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"SentenceEmbedder\s*\("#),
            ["AppSemanticEmbeddingRuntime.swift"],
            "Only the app semantic adapter may construct production embeddings")

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Semantic embedding is the fifth fully integrated residency family"))
        XCTAssertTrue(decisions.contains("## D165"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Governed semantic embedding runtime (D165)"))
        XCTAssertTrue(appSpec.contains(
            "### Semantic embedding residency adapter (D165)"))
    }

    func testSemanticMaintenanceHasOneSharedFlightOutsideAskRequests() throws {
        let coordinator = try Self.contents(
            of: "Sources/ApplicationKit/SemanticCorpusIndexingCoordinator.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let appAsk = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let ask = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let library = try Self.contents(
            of: "Sources/ApplicationKit/LocalLibrarySemanticSearch.swift")
        let readiness = try Self.contents(
            of: "Sources/ApplicationKit/SemanticCorpusReadiness.swift")
        let stressGate = try Self.contents(
            of: "scripts/run-recording-reliability-stress.sh")
        let releaseGate = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")

        XCTAssertTrue(coordinator.contains(
            "public actor SemanticCorpusIndexingCoordinator"))
        XCTAssertTrue(coordinator.contains("private var active: Flight?"))
        XCTAssertTrue(coordinator.contains("private var completeDemandCount = 0"))
        XCTAssertTrue(coordinator.contains(
            "guard active == nil, completeDemandCount == 0"))
        XCTAssertTrue(coordinator.contains("flight.task.cancel()"))
        XCTAssertFalse(coordinator.contains("[CheckedContinuation"))
        XCTAssertTrue(services.contains(
            "@ObservationIgnored let semanticIndexingCoordinator:"))
        XCTAssertTrue(services.contains(
            "semanticIndexingCoordinator = semanticSearch.coordinator"))
        XCTAssertTrue(appAsk.contains(
            "coordinator: SemanticCorpusIndexingCoordinator"))
        XCTAssertTrue(appAsk.contains(
            "let readiness = ResolveSemanticCorpusReadiness"))
        XCTAssertEqual(
            appAsk.components(separatedBy: "semanticReadiness: readiness").count - 1,
            2)
        XCTAssertFalse(ask.contains("indexingCoordinator"))
        XCTAssertFalse(ask.contains("IndexSemanticCorpus"))
        XCTAssertTrue(ask.contains("allowAssetDownload: false"))
        XCTAssertFalse(library.contains("indexingCoordinator"))
        XCTAssertFalse(library.contains("IndexSemanticCorpus"))
        XCTAssertTrue(library.contains("allowAssetDownload: false"))
        XCTAssertTrue(readiness.contains(
            "public enum SemanticCorpusReadiness"))
        for state in ["ready", "partial", "building", "unsupported", "failed"] {
            XCTAssertTrue(readiness.contains("case \(state)"))
        }
        for gate in [stressGate, releaseGate] {
            XCTAssertTrue(gate.contains(
                "SemanticCorpusIndexingCoordinatorTests"))
        }

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        XCTAssertTrue(architecture.contains(
            "process-shared semantic-indexing"))
        XCTAssertTrue(decisions.contains("## D176"))
        XCTAssertTrue(decisions.contains("## D196"))
        XCTAssertTrue(decisions.contains("## D197"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Shared semantic-indexing flight (D176)"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Corpus-read-only Ask retrieval (D196)"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Typed semantic readiness and background-only writes (D197)"))
    }

    func testSemanticBackgroundOwnerUsesSignalsAndDurableCursor() throws {
        let supervisor = try Self.contents(
            of: "Sources/portavoz-app/SemanticCorpusIndexingSupervisor.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessSemanticCorpusMaintenance.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DerivedMaintenance.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+DerivedMaintenance.swift")
        let job = try Self.contents(
            of: "Sources/PortavozCore/DerivedMaintenanceJob.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/PortavozApp.swift")
        let resourceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let appAsk = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let stressGate = try Self.contents(
            of: "scripts/run-recording-reliability-stress.sh")
        let releaseGate = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")

        XCTAssertTrue(supervisor.contains(
            "final class SemanticCorpusIndexingSupervisor"))
        XCTAssertTrue(supervisor.contains("private var drainTask:"))
        XCTAssertTrue(supervisor.contains("private var wakeTask:"))
        XCTAssertTrue(supervisor.contains("private var rerunRequested = false"))
        XCTAssertTrue(supervisor.contains(
            "maintenanceState.transition(to: .building)"))
        XCTAssertTrue(supervisor.contains(
            "run.terminalFailure ? .failed : .idle"))
        XCTAssertTrue(supervisor.contains("scheduleWake(at: retryAt)"))
        XCTAssertTrue(supervisor.contains("Task.sleep(for: .seconds(delay))"))
        XCTAssertFalse(supervisor.contains("while"))
        XCTAssertTrue(supervisor.contains(
            "struct AppSemanticCorpusBackgroundIndexer"))
        XCTAssertTrue(supervisor.contains(
            "ProcessSemanticCorpusMaintenance("))
        XCTAssertTrue(workflow.contains("allowAssetDownload: false"))
        XCTAssertTrue(workflow.contains("recoverExpiredSemanticCorpusMaintenance"))
        XCTAssertTrue(workflow.contains("suspendSemanticCorpusMaintenance"))
        XCTAssertTrue(workflow.contains("retryDelays: [TimeInterval] = [5, 30]"))
        XCTAssertTrue(store.contains("leaseExpiresAt AS wakeAt"))
        XCTAssertTrue(store.contains("state = 'cancelled'"))
        XCTAssertTrue(schema.contains("registerMigration(\"v18\")"))
        XCTAssertTrue(schema.contains("semanticCorpusGeneration_after_segment_update"))
        XCTAssertTrue(job.contains("semantic-corpus-maintenance-v1"))
        XCTAssertTrue(services.contains(
            "@ObservationIgnored let semanticIndexingSupervisor:"))
        XCTAssertTrue(services.contains(
            "func requestSearchReconciliation()"))
        XCTAssertTrue(app.contains(
            "services.requestSearchReconciliation()"))
        XCTAssertTrue(resourceAdapter.contains(
            "semanticIndexingSupervisor.kick()"))
        XCTAssertTrue(appAsk.contains(
            "isEnabled: !usesTemporaryStore"))
        for gate in [stressGate, releaseGate] {
            XCTAssertTrue(gate.contains(
                "SemanticCorpusIndexingSupervisorTests"))
        }

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "one signal-driven semantic-maintenance supervisor"))
        XCTAssertTrue(decisions.contains(
            "## D178 — Resume semantic maintenance"))
        XCTAssertTrue(decisions.contains(
            "## D200 — Own semantic maintenance independently"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Signal-driven background semantic owner (D178)"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Durable semantic maintenance ownership (D200)"))
        XCTAssertTrue(appSpec.contains(
            "### Signal-driven semantic maintenance (D178)"))
        XCTAssertTrue(appSpec.contains(
            "### Durable semantic maintenance scheduling (D200)"))
    }

    func testSemanticPublicationIsFencedByExactTranscriptSource() throws {
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Search.swift")
        let operation = try Self.contents(
            of: "Sources/ApplicationKit/IndexSemanticCorpus.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessPostCaptureJobs.swift")

        for identity in [
            "struct SemanticEmbeddingCandidate",
            "public let meetingID: MeetingID",
            "public let transcriptRevision: Int",
            "public let text: String",
            "AND meeting.transcriptRevision = ?",
            "AND text = ?",
            "AND deletedAt IS NULL",
            "AND embedding IS NULL",
        ] {
            XCTAssertTrue(
                store.contains(identity),
                "Semantic publication is missing source fence: \(identity)")
        }
        XCTAssertTrue(operation.contains("profile: profile"))
        XCTAssertTrue(operation.contains("skippedSegments:"))
        XCTAssertFalse(workflow.contains(".index"))

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let storageSpec = try Self.contents(of: "docs/specs/05-storage.md")
        XCTAssertTrue(architecture.contains(
            "live row remains on the `NULL` cursor"))
        XCTAssertTrue(decisions.contains("## D198"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Revision-fenced semantic publication (D198)"))
        XCTAssertTrue(storageSpec.contains("storeEmbeddings(_:for:profile:)"))
    }

    func testSemanticEmbeddingsAreCompatibilityFenced() throws {
        let profile = try Self.contents(
            of: "Sources/PortavozCore/SemanticEmbeddingProfile.swift")
        let embedder = try Self.contents(
            of: "Sources/IntelligenceKit/SentenceEmbedder.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let schemaMigration = try Self.contents(
            of: "Sources/StorageKit/Schema+SemanticEmbedding.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Search.swift")
        let operation = try Self.contents(
            of: "Sources/ApplicationKit/IndexSemanticCorpus.swift")
        let readiness = try Self.contents(
            of: "Sources/ApplicationKit/SemanticCorpusReadiness.swift")
        let maintenance = try Self.contents(
            of: "Sources/ApplicationKit/ProcessSemanticCorpusMaintenance.swift")
        let ask = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let library = try Self.contents(
            of: "Sources/ApplicationKit/LocalLibrarySemanticSearch.swift")

        for identity in [
            "public struct SemanticEmbeddingProfile",
            "public let modelIdentifier: String",
            "public let modelRevision: Int",
            "public let vectorDimension: Int",
            "public let pipelineIdentifier: String",
            "public let pipelineRevision: Int",
            "public let vectorSchemaVersion: Int",
            "version: \"semantic-embedding-profile-v1\"",
        ] {
            XCTAssertTrue(
                profile.contains(identity),
                "Semantic profile is missing compatibility identity: \(identity)")
        }
        XCTAssertTrue(embedder.contains("embedding.modelIdentifier"))
        XCTAssertTrue(embedder.contains("embedding.revision"))
        XCTAssertTrue(embedder.contains("embedding.dimension"))

        XCTAssertTrue(schema.contains("public static let version = 18"))
        XCTAssertTrue(schema.contains(
            "registerSemanticEmbeddingProfileMigration(in: &migrator)"))
        XCTAssertTrue(schemaMigration.contains("registerMigration(\"v17\")"))
        XCTAssertTrue(schemaMigration.contains("embeddingFingerprint"))
        XCTAssertTrue(schemaMigration.contains(
            "SET embedding = NULL, embeddingFingerprint = NULL"))

        for fence in [
            "semanticIndexRequiresMaintenance(",
            "invalidateSemanticEmbeddings(",
            "profile: SemanticEmbeddingProfile",
            "vector.count == profile.vectorDimension",
            "vector.allSatisfy(\\.isFinite)",
            "SET embedding = ?, embeddingFingerprint = ?",
            "segment.embeddingFingerprint = ?",
        ] {
            XCTAssertTrue(
                store.contains(fence),
                "Semantic storage is missing profile fence: \(fence)")
        }

        XCTAssertTrue(operation.contains("case invalidProfile"))
        XCTAssertTrue(operation.contains(
            "invalidateSemanticEmbeddings("))
        XCTAssertTrue(readiness.contains(
            "semanticEmbeddingProfile()"))
        XCTAssertTrue(readiness.contains(
            "semanticIndexRequiresMaintenance("))
        XCTAssertTrue(maintenance.contains("hasSemanticCorpusRows()"))
        XCTAssertTrue(maintenance.contains(
            "semanticIndexRequiresMaintenance("))
        XCTAssertTrue(maintenance.contains("for: profile)"))
        XCTAssertTrue(ask.contains("profile: profile"))
        XCTAssertTrue(library.contains("profile: profile"))

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let storageSpec = try Self.contents(of: "docs/specs/05-storage.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains("current schema version is 18"))
        XCTAssertTrue(architecture.contains(
            "Every persisted semantic vector also carries one SHA-256"))
        XCTAssertTrue(decisions.contains("## D199"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Compatibility-fenced semantic vectors (D199)"))
        XCTAssertTrue(storageSpec.contains("Schema v17 adds nullable"))
        XCTAssertTrue(appSpec.contains("D199 compatibility"))
    }

    func testPressureDrivenReleaseUsesGovernorAndAllConcreteOwners() throws {
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let monitor = try Self.contents(
            of: "Sources/portavoz-app/AppResourcePressureMonitor.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/PortavozApp.swift")
        let ledger = try Self.contents(
            of: "Sources/portavoz-app/AppModelResidencyLedger.swift")

        XCTAssertTrue(adapter.contains(
            "ResourceGovernorPolicy().evaluate("))
        XCTAssertTrue(adapter.contains(
            "residentModels: modelResidencyLedger.residentModels"))
        for release in [
            "releaseLiveSpeechRuntime()",
            "releaseWhisper()",
            "releaseDiarizationRuntime()",
            "await releaseMLXRuntime()",
            "await semanticEmbeddingRuntime.release()",
        ] {
            XCTAssertTrue(
                adapter.contains(release),
                "Pressure release adapter is missing \(release)")
        }
        XCTAssertTrue(monitor.contains(
            "DispatchSource.makeMemoryPressureSource("))
        XCTAssertTrue(monitor.contains(
            "ProcessInfo.thermalStateDidChangeNotification"))
        XCTAssertTrue(app.contains(
            "services.startResourcePressureMonitoring()"))
        XCTAssertTrue(ledger.contains(
            "observer?(lease.family)"))

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Pressure-driven residency release"))
        XCTAssertTrue(decisions.contains("## D166"))
        XCTAssertTrue(appSpec.contains(
            "### Pressure-driven residency release (D166)"))
    }

    func testCaptureHeavyModelExclusionRechecksEveryPublicationBoundary() throws {
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let whisper = try Self.contents(
            of: "Sources/portavoz-app/AppServices+WhisperModels.swift")
        let mlx = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MLXModels.swift")

        for required in [
            "final class AppResourceCaptureState",
            "func recordingPhaseDidChange(",
            "func admitModelRuntimeLoad(",
            "func beginAdmittedModelRuntimeLoad(",
            "reservesLoad: true",
            "memoryTier: .unknown",
            "await releaseIdleModels(decision.evictIdleModels)",
            "AppResourceGovernorAdmissionError"
        ] {
            XCTAssertTrue(
                adapter.contains(required),
                "Capture-heavy admission adapter is missing \(required)")
        }
        XCTAssertTrue(services.contains(
            "let resourceCaptureState = AppResourceCaptureState()"))
        XCTAssertTrue(recording.contains(
            "services?.recordingPhaseDidChange(phase)"))
        XCTAssertEqual(
            whisper.components(
                separatedBy: "admitModelRuntimeLoad(.qualitySpeech)"
            ).count - 1,
            2,
            "Whisper must check before preparation and publication")
        XCTAssertEqual(
            whisper.components(
                separatedBy: "beginAdmittedModelRuntimeLoad("
            ).count - 1,
            1,
            "Whisper load admission and ticket reservation must be atomic")
        XCTAssertEqual(
            mlx.components(
                separatedBy: "admitModelRuntimeLoad(.languageIntelligence)"
            ).count - 1,
            2,
            "MLX must check before preparation and publication")
        XCTAssertEqual(
            mlx.components(
                separatedBy: "beginAdmittedModelRuntimeLoad("
            ).count - 1,
            1,
            "MLX load admission and ticket reservation must be atomic")

        let forbiddenModelOperation =
            #"\b(?:VerifiedModelLifecycle|ModelStore|WhisperEngine|"#
            + #"MLXSummaryRuntime|releaseWhisper|releaseMLXRuntime)\b"#
        let audioCallbackModelOperations = try Self.sourceMatches(
            under: "Sources/AudioCaptureKit",
            pattern: forbiddenModelOperation)
        let callbackMessage =
            "Model operations must stay outside AudioCaptureKit: "
            + "\(audioCallbackModelOperations)"
        XCTAssertTrue(
            audioCallbackModelOperations.isEmpty,
            callbackMessage)

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Capture-exclusive heavy-model admission"))
        XCTAssertTrue(decisions.contains("## D167"))
        XCTAssertTrue(appSpec.contains(
            "### Capture-exclusive heavy-model admission (D167)"))
    }

    func testRecordingLevelsUseOneBoundedPersistedEvidencePipeline() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/AudioTypes.swift")
        let session = try Self.contents(
            of: "Sources/AudioCaptureKit/RecordingSession.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/StartRecording.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StartRecording.swift")
        let relay = try Self.contents(
            of: "Sources/portavoz-app/RecordingLevelRelay.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")

        XCTAssertTrue(core.contains(
            "public struct PersistedAudioLevel: Equatable, Sendable"))
        XCTAssertEqual(
            session.components(separatedBy: "for sample in samples").count - 1,
            1,
            "Persisted signal evidence must reuse the writer's only PCM scan")
        XCTAssertTrue(session.contains(
            "let signal = PersistedChunkSignal.measure(chunk.samples)"))
        XCTAssertTrue(session.contains(
            "onLevel?(PersistedAudioLevel("))
        XCTAssertTrue(session.contains(
            "duration: chunk.duration"))
        XCTAssertTrue(application.contains(
            "public let level: StartRecordingLevelHandler"))
        XCTAssertTrue(adapter.contains(
            "} onLevel: { sample in"))

        for required in [
            "private(set) var pendingValueCount = 0",
            "pendingValueCount = 1",
            "cadence: Duration = .milliseconds(50)",
            "snapshot.microphoneIsLow",
            "snapshot.systemAudioIsMissing",
            "snapshot.systemAudioIsClipping",
            "minimumObservedDuration",
            "generation &+= 1",
        ] {
            XCTAssertTrue(
                relay.contains(required),
                "Bounded recording-level relay is missing \(required)")
        }
        XCTAssertTrue(controller.contains(
            "level: { levelRelay.submit($0) }"))
        XCTAssertFalse(controller.contains(
            "for sample in chunk.samples"))
        XCTAssertFalse(controller.contains(
            "updateMicLevel("))
        XCTAssertFalse(controller.contains(
            "updateSystemLevel("))

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let captureSpec = try Self.contents(
            of: "docs/specs/01-audio-capture.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Bounded persisted-level presentation"))
        XCTAssertTrue(decisions.contains("## D168"))
        XCTAssertTrue(captureSpec.contains(
            "### Persisted level evidence (D168)"))
        XCTAssertTrue(appSpec.contains(
            "### Bounded recording-level relay (D168)"))
    }

    func testLiveTranslationUsesSignalDrivenBoundedWork() throws {
        let translation = try Self.contents(
            of: "Sources/portavoz-app/LiveTranslation.swift")
        let wakeHub = try Self.contents(
            of: "Sources/portavoz-app/LiveTranslationWakeHub.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let translationAdapter = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+LiveTranslation.swift")
        let stressGate = try Self.contents(
            of: "scripts/run-recording-reliability-stress.sh")
        let releaseGate = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")

        for required in [
            "static let recentRowLimit = 60",
            "static let maximumBatchSize = 8",
            "let subscription = wakeHub.subscribe()",
            "guard await wakes.next() != nil else { return }",
        ] {
            XCTAssertTrue(
                translation.contains(required),
                "Bounded live translation is missing \(required)")
        }
        XCTAssertFalse(
            translation.contains("sleep(milliseconds: 300)"),
            "Idle live translation must wait for state changes, not poll")
        XCTAssertTrue(wakeHub.contains(".bufferingNewest(1)"))
        XCTAssertTrue(wakeHub.contains("continuation.yield()"))
        XCTAssertTrue(controller.contains(
            "let liveTranslationWakeHub = LiveTranslationWakeHub()"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "liveTranslationWakeHub.signal()").count - 1,
            4,
            "Caption, speaker, target, and consent changes must wake the lane")
        XCTAssertGreaterThanOrEqual(
            translationAdapter.components(
                separatedBy: "liveTranslationWakeHub.signal()").count - 1,
            2,
            "Pair and unsupported-row changes must wake the lane")
        for gate in [stressGate, releaseGate] {
            XCTAssertTrue(gate.contains("LiveTranslationWakeHubTests"))
            XCTAssertTrue(gate.contains("LiveTranslationWakeIntegrationTests"))
        }

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let transcriptionSpec = try Self.contents(
            of: "docs/specs/02-transcription.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Signal-driven bounded live translation"))
        XCTAssertTrue(decisions.contains("## D169"))
        XCTAssertTrue(transcriptionSpec.contains(
            "### Signal-driven live translation (D169)"))
        XCTAssertTrue(appSpec.contains(
            "### Bounded translation wake relay (D169)"))
    }

    func testLiveCompanionGenerationIsRecordingScopedAndBounded() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/LiveCompanionWorkCoordinator.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let detection = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let stressGate = try Self.contents(
            of: "scripts/run-recording-reliability-stress.sh")
        let releaseGate = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")

        for required in [
            "private var worker: Task<Void, Never>?",
            "private var pending: CompanionGenerationRequest?",
            "while !Task.isCancelled, let request = pending",
            "guard !Task.isCancelled else { break }",
            "worker?.cancel()",
        ] {
            XCTAssertTrue(
                coordinator.contains(required),
                "Bounded live Apuntador work is missing \(required)")
        }
        XCTAssertFalse(
            coordinator.contains("[CompanionGenerationRequest]"),
            "Live Apuntador must retain one latest pending request, not a queue")
        XCTAssertTrue(detection.contains(
            "companionCoordinator(services: services).submit("))
        XCTAssertFalse(detection.contains(
            "Task { @MainActor [weak self] in\n            guard let self"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "cancelCompanionGeneration()").count - 1,
            4,
            "Opt-out, reset, next-session, and Stop must cancel live Apuntador work")
        for gate in [stressGate, releaseGate] {
            XCTAssertTrue(gate.contains("TurnEndpointPolicyTests"))
            XCTAssertTrue(gate.contains("LiveCompanionWorkCoordinatorTests"))
        }

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Bounded recording-scoped live Apuntador"))
        XCTAssertFalse(architecture.contains("D170"))
        XCTAssertTrue(decisions.contains("## D170"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Bounded live Apuntador work (D170)"))
        XCTAssertTrue(appSpec.contains(
            "### Recording-scoped Apuntador coordinator (D170)"))
    }

    func testLiveSummaryWorkIsSignalDrivenBoundedAndLifecycleFenced() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/LiveSummaryWorkCoordinator.swift")
        let windowPolicy = try Self.contents(
            of: "Sources/portavoz-app/LiveSummaryWindowPolicy.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let detection = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let objectives = try Self.contents(
            of: "Sources/portavoz-app/RecordingObjectivesModel.swift")
        let stressGate = try Self.contents(
            of: "scripts/run-recording-reliability-stress.sh")
        let releaseGate = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")

        for required in [
            "private var worker: Task<Void, Never>?",
            "private var pending = false",
            "try await sleep(interval)",
            "pending = pending || hasBacklog",
            "worker?.cancel()",
        ] {
            XCTAssertTrue(
                coordinator.contains(required),
                "Bounded live-summary work is missing \(required)")
        }
        XCTAssertFalse(
            coordinator.contains("[LiveSummary"),
            "Live summary must retain one invalidation bit, not a work queue")
        XCTAssertTrue(windowPolicy.contains(
            "static let maximumRowsPerCycle = 32"))
        XCTAssertTrue(windowPolicy.contains(
            "static let maximumCharactersPerCycle = 6_000"))
        XCTAssertTrue(windowPolicy.contains("for segment in captions.dropLast()"))

        XCTAssertFalse(
            controller.contains("rollingTask"),
            "Live summary must not restore the permanent timer loop")
        XCTAssertTrue(controller.contains(
            "liveSummaryCoordinator().request()"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "cancelLiveSummaryWork()").count - 1,
            4,
            "Reset, next-session, and Stop must cancel live-summary work")
        XCTAssertTrue(detection.contains("requestLiveSummaryRefresh()"))
        XCTAssertTrue(controller.contains("var candidateNotes = liveNotes + [note]"))
        XCTAssertTrue(controller.contains(
            "var candidateIDs = summarizedCaptionIDs"))
        XCTAssertTrue(controller.contains(
            "guard isCurrentLiveSummaryCycle(sourceMeetingID) else { return false }"))
        XCTAssertTrue(controller.contains("liveNotes = candidateNotes"))
        XCTAssertTrue(controller.contains("summarizedCaptionIDs = candidateIDs"))
        XCTAssertTrue(controller.contains(
            "A provider outage must not recreate a permanent poll"))
        XCTAssertTrue(objectives.contains(
            "guard !Task.isCancelled, !addressed.isEmpty else { return }"))

        for gate in [stressGate, releaseGate] {
            XCTAssertTrue(gate.contains("LiveSummaryWorkCoordinatorTests"))
            XCTAssertTrue(gate.contains("LiveSummaryWindowPolicyTests"))
        }

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Bounded signal-driven live summary"))
        XCTAssertFalse(architecture.contains("D171"))
        XCTAssertTrue(decisions.contains("## D171"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Bounded live-summary delivery (D171)"))
        XCTAssertTrue(appSpec.contains(
            "### Recording-scoped live-summary coordinator (D171)"))
    }

    func testLiveSpeechRuntimePinsEveryProductionBorrower() throws {
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LiveSpeechModels.swift")
        let start = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StartRecording.swift")
        let attacher = try Self.contents(
            of: "Sources/portavoz-app/LiveTranscriptionAttacher.swift")
        let dictation = try Self.contents(
            of: "Sources/portavoz-app/DictationController.swift")
        let recovery = try Self.contents(
            of: "Sources/portavoz-app/AppPostCaptureProcessingCapabilities.swift")
        let benchmark = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceBatch.swift")

        for transition in [
            "modelResidencyLedger.beginLoad(.liveSpeech)",
            "modelResidencyLedger.finishLoad(",
            "modelResidencyLedger.failLoad(",
            "modelResidencyLedger.beginUse(.liveSpeech)",
            "modelResidencyLedger.finishUse(",
            "modelResidencyLedger.beginRelease(.liveSpeech)",
            "modelResidencyLedger.finishRelease(",
            "modelResidencyLedger.cancelRelease(",
            "struct LiveSpeechRuntimeLoad",
            "struct LiveSpeechRuntimeLease",
        ] {
            XCTAssertTrue(
                adapter.contains(transition),
                "Live-speech residency adapter is missing \(transition)")
        }

        XCTAssertTrue(start.contains("services.acquireResidentLiveSpeechRuntime()"))
        XCTAssertTrue(start.contains("services.acquireLiveSpeechRuntime()"))
        XCTAssertTrue(start.contains("services.liveTranscriptionRuntime(runtime)"))
        XCTAssertTrue(attacher.contains("await runtime?.finish()"))
        XCTAssertTrue(attacher.contains("await runtime.finish()"))
        for borrower in [dictation, recovery, benchmark] {
            XCTAssertTrue(borrower.contains("services.acquireLiveSpeechRuntime("))
            XCTAssertTrue(borrower.contains("services.finishLiveSpeechRuntime("))
        }
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"loadTranscriberIfNeeded"#),
            [])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"services\.transcriber(?:\s|[,)}])"#),
            [])
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"(?m)^\s*(?:self\.)?transcriber\s*="#),
            ["AppServices+LiveSpeechModels.swift"],
            "Only the live-speech capability adapter may mutate the runtime")

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Parakeet is the third fully integrated residency family"))
        XCTAssertTrue(decisions.contains("## D162"))
        XCTAssertTrue(appSpec.contains("### Live-speech residency adapter (D162)"))
    }

    func testDiarizationRuntimePinsEveryProductionBorrower() throws {
        let capability = try Self.contents(
            of: "Sources/DiarizationKit/PyannoteDiarizer.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+DiarizationModels.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let postCapture = try Self.contents(
            of: "Sources/portavoz-app/AppPostCaptureProcessingCapabilities.swift")
        let refine = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RefineMeeting.swift")
        let importAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ImportMeeting.swift")
        let localVoice = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalVoiceIdentity.swift")
        let voiceMemory = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingVoiceMemory.swift")
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")

        XCTAssertTrue(capability.contains(
            "public struct PyannoteDiarizationRuntime: Sendable"))
        XCTAssertTrue(capability.contains(
            "public func makeDiarizer("))
        XCTAssertTrue(capability.contains(
            "let sessionModels = models"))

        for transition in [
            "modelResidencyLedger.beginLoad(.speakerDiarization)",
            "modelResidencyLedger.finishLoad(",
            "modelResidencyLedger.failLoad(",
            "modelResidencyLedger.beginUse(",
            ".speakerDiarization)",
            "modelResidencyLedger.finishUse(",
            "modelResidencyLedger.beginRelease(",
            "modelResidencyLedger.finishRelease(",
            "modelResidencyLedger.cancelRelease(",
            "struct DiarizationRuntimeLoad",
            "struct DiarizationRuntimeLease",
        ] {
            XCTAssertTrue(
                adapter.contains(transition),
                "Diarization residency adapter is missing \(transition)")
        }

        for borrower in [
            postCapture, refine, localVoice, voiceMemory, recording,
        ] {
            XCTAssertTrue(borrower.contains("services.acquireDiarizationRuntime("))
            XCTAssertTrue(borrower.contains("services.finishDiarizationRuntime("))
            XCTAssertTrue(borrower.contains("services.makeDiarizer("))
        }
        XCTAssertTrue(importAdapter.contains("private var diarizationRuntime:"))
        XCTAssertTrue(importAdapter.contains("services.acquireDiarizationRuntime()"))
        XCTAssertTrue(importAdapter.contains("services?.finishDiarizationRuntime("))
        XCTAssertTrue(importAdapter.contains("services.makeDiarizer("))
        XCTAssertFalse(services.contains("var diarizer: PyannoteDiarizer?"))
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"PyannoteDiarizer\.loadRecommended"#),
            [])

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let diarizationSpec = try Self.contents(
            of: "docs/specs/03-diarization-identity.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Diarization is the fourth fully integrated residency family"))
        XCTAssertTrue(decisions.contains("## D164"))
        XCTAssertTrue(diarizationSpec.contains(
            "### Process-owned model residency (D164)"))
        XCTAssertTrue(appSpec.contains(
            "### Diarization residency adapter (D164)"))
    }

    func testWhisperRuntimePinsOneCompleteResidencyLifecycle() throws {
        let whisper = try Self.contents(
            of: "Sources/portavoz-app/AppServices+WhisperModels.swift")
        let governor = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let refine = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RefineMeeting.swift")
        let importAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ImportMeeting.swift")

        for transition in [
            "modelResidencyLedger.finishLoad(",
            "modelResidencyLedger.failLoad(",
            "modelResidencyLedger.beginUse(.qualitySpeech)",
            "modelResidencyLedger.finishUse(",
            "modelResidencyLedger.beginRelease(.qualitySpeech)",
            "modelResidencyLedger.finishRelease(",
            "modelResidencyLedger.cancelRelease(",
            "struct WhisperRuntimeLoad",
            "struct WhisperRuntimeLease",
        ] {
            XCTAssertTrue(
                whisper.contains(transition),
                "Whisper residency adapter is missing \(transition)")
        }
        XCTAssertTrue(whisper.contains(
            "beginAdmittedModelRuntimeLoad("))
        XCTAssertTrue(governor.contains(
            "modelResidencyLedger.beginLoad(family)"))

        for adapter in [refine, importAdapter] {
            XCTAssertTrue(adapter.contains("private var whisperRuntime:"))
            XCTAssertTrue(adapter.contains("services.acquireWhisperRuntime("))
            XCTAssertTrue(adapter.contains("whisperRuntime?.engine"))
            XCTAssertTrue(adapter.contains("services?.finishWhisperRuntime("))
            XCTAssertFalse(
                adapter.contains("services.whisper"),
                "A workflow must use its pinned runtime rather than shared mutable state")
        }
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"services\.whisper(?:\s|[,)}])"#),
            [])

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Whisper is the first fully integrated residency family"))
        XCTAssertTrue(decisions.contains("## D160"))
        XCTAssertTrue(appSpec.contains("### Whisper residency adapter (D160)"))
    }

    func testMLXRuntimePinsOneCompleteResidencyLifecycle() throws {
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let governor = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let mlx = try Self.contents(
            of: "Sources/IntelligenceKit/MLXSummaryProvider.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MLXModels.swift")
        let application = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")
        let postCapture = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let importAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ImportMeeting.swift")

        XCTAssertTrue(mlx.contains("public protocol MLXSummaryRuntimeClient: Sendable"))
        XCTAssertTrue(mlx.contains(
            "public actor MLXSummaryRuntime: MLXSummaryRuntimeClient"))
        XCTAssertTrue(mlx.contains("private let runtime: any MLXSummaryRuntimeClient"))
        XCTAssertFalse(mlx.contains("MLXModelCache.shared"))
        XCTAssertTrue(services.contains(
            "@ObservationIgnored let mlxSummaryRuntime = MLXSummaryRuntime()"))

        for transition in [
            "modelResidencyLedger.finishLoad(",
            "modelResidencyLedger.failLoad(",
            "modelResidencyLedger.beginUse(",
            "modelResidencyLedger.finishUse(",
            "modelResidencyLedger.beginRelease(",
            "modelResidencyLedger.finishRelease(",
            "struct MLXRuntimeLoad",
            "struct MLXRuntimeLease",
            "mlxSummaryRuntime.respondPrepared(",
            "Task.sleep(for: .seconds(120))",
        ] {
            XCTAssertTrue(
                adapter.contains(transition),
                "MLX residency adapter is missing \(transition)")
        }
        XCTAssertTrue(adapter.contains(
            "beginAdmittedModelRuntimeLoad("))
        XCTAssertTrue(governor.contains(
            "modelResidencyLedger.beginLoad(family)"))

        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"\bMLXSummaryProvider\s*\("#),
            [
                "AppServices+MLXModels.swift",
                "BenchMode.swift",
            ],
            "Production MLX providers must cross the app-owned runtime client")
        XCTAssertTrue(application.contains("mlxProvider: { [weak self]"))
        XCTAssertTrue(importAdapter.contains("mlxProvider: { [weak self]"))
        XCTAssertTrue(postCapture.contains("provider: makeMLXSummaryProvider("))
        XCTAssertTrue(services.contains("await releaseMLXRuntime()"))

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "MLX is the second fully integrated residency family"))
        XCTAssertTrue(decisions.contains("## D161"))
        XCTAssertTrue(intelligenceSpec.contains(
            "`MLXSummaryRuntime` owns container mechanics"))
        XCTAssertTrue(appSpec.contains("### MLX residency adapter (D161)"))
    }

    func testResourceBaselineEvidenceIsCompleteFailClosedAndToolingOnly() throws {
        let contract = try Self.jsonObject(
            at: "docs/evidence/resource-baseline-matrix.json")
        let profiles = try XCTUnwrap(contract["profiles"] as? [[String: Any]])
        let scenarios = try XCTUnwrap(contract["scenarios"] as? [[String: Any]])
        XCTAssertEqual(
            Set(profiles.compactMap { $0["id"] as? String }),
            Set(["memory-8gb", "memory-16gb", "reference"]))
        XCTAssertEqual(
            Set(scenarios.compactMap { $0["id"] as? String }),
            Set([
                "idle", "recording", "stop", "refine", "summary", "ask",
                "indexing", "recording-indexing", "recording-batch",
            ]))
        XCTAssertEqual(contract["minimumStableSamples"] as? Int, 3)
        XCTAssertEqual(
            contract["maximumTimingP95ToP50Ratio"] as? Double,
            1.25)

        let evaluator = try Self.contents(of: "scripts/resource_baseline.py")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        XCTAssertTrue(evaluator.contains(
            #"if all(row["state"] == "pass" for row in measurements)"#))
        XCTAssertTrue(evaluator.contains("object_pairs_hook=reject_duplicate_keys"))
        XCTAssertTrue(evaluator.contains("os.chmod(temporary, 0o600)"))
        XCTAssertTrue(evaluator.contains(
            "contract.maximumTimingP95ToP50Ratio must be <= 1.25"))
        for forbidden in [
            "meetingTitle", "transcriptText", "sourcePath", "modelName",
            "errorMessage",
        ] {
            XCTAssertFalse(
                evaluator.contains(forbidden),
                "Resource evidence must not admit payload field \(forbidden)")
        }
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_resource_baseline"))
        XCTAssertTrue(decisions.contains("## D149"))
        XCTAssertTrue(decisions.contains("## D150"))

        let nativeProbe = try Self.contents(
            of: "Sources/portavoz-app/ResourceRunProbe.swift")
        let benchProbes = try Self.contents(
            of: "Sources/portavoz-app/BenchRecordResourceProbes.swift")
        let scenarioProbe = try Self.contents(
            of: "Sources/portavoz-app/BenchResourceScenarioProbe.swift")
        let benchMode = try Self.contents(
            of: "Sources/portavoz-app/BenchMode.swift")
        let recordingRunner = try Self.contents(
            of: "Sources/portavoz-app/BenchRecordingResourceRunner.swift")
        let indexingBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceIndexing.swift")
        let batchBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceBatch.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/PortavozApp.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let volatileSecrets = try Self.contents(
            of: "Sources/PlatformKit/VolatileSecretStore.swift")
        let scheduler = try Self.contents(
            of: "Sources/IntelligenceKit/IntelligenceScheduler.swift")
        let mlxProvider = try Self.contents(
            of: "Sources/IntelligenceKit/MLXSummaryProvider.swift")
        let postCapture = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let runner = try Self.contents(
            of: "scripts/run-resource-baseline.sh")
        let compatibilityRunner = try Self.contents(
            of: "scripts/run-resource-recording-baseline.sh")
        XCTAssertTrue(nativeProbe.contains("proc_pid_rusage"))
        XCTAssertTrue(nativeProbe.contains("ri_energy_nj"))
        XCTAssertTrue(nativeProbe.contains(
            "IOPSGetProvidingPowerSourceType"))
        XCTAssertTrue(nativeProbe.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(nativeProbe.contains(
            "enum ResourceProbeHostReadiness"))
        XCTAssertTrue(nativeProbe.contains(
            "consecutiveNominal == 2"))
        XCTAssertTrue(benchProbes.contains(
            "finishRecordingAndBeginStop"))
        XCTAssertTrue(benchProbes.contains(
            "func measureIdle()"))
        XCTAssertTrue(benchProbes.contains(
            "ResourceProbeHostReadiness.waitUntilNominal()"))
        XCTAssertTrue(benchProbes.contains(
            "replayingActive: true"))
        XCTAssertTrue(benchProbes.contains(
            "freezeBeforeStop"))
        XCTAssertTrue(benchProbes.contains(
            "finishAfterStopAndWrite"))
        XCTAssertTrue(recordingRunner.contains(
            #"arguments.contains("-use-temp-store")"#))
        let permissionPreflight = try XCTUnwrap(recordingRunner.range(
            of: "authorizeMicrophoneForRecording()"))
        let recordingProbeStart = try XCTUnwrap(recordingRunner.range(
            of: "baselineProbes?.beginRecording()"))
        XCTAssertLessThan(
            permissionPreflight.lowerBound,
            recordingProbeStart.lowerBound)
        XCTAssertTrue(recordingRunner.contains(
            "recording Stop exceeded 30 seconds"))
        XCTAssertTrue(recordingRunner.contains(
            "prepareIndexingResourceWorkload"))
        XCTAssertTrue(recordingRunner.contains(
            "concurrent semantic indexing complete"))
        XCTAssertTrue(recordingRunner.contains(
            "prepareBatchTranscriptionResourceWorkload"))
        XCTAssertTrue(recordingRunner.contains(
            "concurrent batch transcription complete"))
        XCTAssertTrue(batchBench.contains(
            "services.transcriptionScheduler.batch"))
        XCTAssertTrue(batchBench.contains(
            "workloadClass: .postCapture"))
        XCTAssertTrue(batchBench.contains(
            "BenchResourceTimedOperation.run"))
        XCTAssertTrue(services.contains(
            "usesTemporarySensitiveStore"))
        XCTAssertTrue(services.contains(
            "VolatileSecretStore()"))
        XCTAssertTrue(services.contains(
            "voiceprintStore = sensitiveStorage.voiceprintStore"))
        XCTAssertFalse(volatileSecrets.contains("Security"))
        XCTAssertFalse(volatileSecrets.contains("SecItem"))
        XCTAssertTrue(benchMode.contains(
            "runRefineResourceBenchIfRequested"))
        XCTAssertTrue(benchMode.contains(
            "services.refineMeeting.draft.execute"))
        XCTAssertTrue(benchMode.contains(
            "runSummaryResourceBenchIfRequested"))
        XCTAssertTrue(benchMode.contains(
            "services.regenerateSummary.execute"))
        XCTAssertTrue(benchMode.contains(
            "providerOverride: .mlx"))
        XCTAssertTrue(benchMode.contains(
            "runAskResourceBenchIfRequested"))
        XCTAssertTrue(benchMode.contains(
            "services.semanticIndexingCoordinator.all"))
        XCTAssertTrue(benchMode.contains(
            "allowAssetDownload: false"))
        XCTAssertTrue(benchMode.contains("pendingAtSeed"))
        XCTAssertTrue(benchMode.contains(
            "try await useCase.answer(question, limit: 6)"))
        XCTAssertTrue(indexingBench.contains(
            "runIndexingResourceBenchIfRequested"))
        XCTAssertTrue(indexingBench.contains(
            "IndexSemanticCorpus("))
        XCTAssertTrue(indexingBench.contains(
            "try await workload.run("))
        XCTAssertTrue(benchMode.contains(
            "runsIsolatedResourceBenchmark"))
        let benchmarkExit = try XCTUnwrap(app.range(
            of: "if runsIsolatedResourceBenchmark"))
        let normalStartup = try XCTUnwrap(app.range(
            of: "await appServices.meetingSync.start"))
        XCTAssertLessThan(benchmarkExit.lowerBound, normalStartup.lowerBound)
        XCTAssertTrue(app.contains(
            "if !runsIsolatedResourceBenchmark"))
        XCTAssertTrue(benchMode.contains(
            "forceVerification: true"))
        XCTAssertTrue(scenarioProbe.contains(
            "BenchResourceTimedOperation"))
        XCTAssertTrue(scenarioProbe.contains(
            "ResourceProbeHostReadiness.waitUntilNominal()"))
        XCTAssertTrue(scenarioProbe.contains(
            "replayingActive: true"))
        XCTAssertTrue(scenarioProbe.contains(
            "probe.writeSample"))
        XCTAssertTrue(services.contains(
            "usesTemporaryMeetingStore && !reusesVerifiedModels"))
        XCTAssertTrue(runner.contains(
            "app.portavoz.mac.resource-bench"))
        XCTAssertEqual(
            runner.components(separatedBy: "run_benchmark_app").count - 1,
            8)
        XCTAssertFalse(runner.contains(
            #""$APP/Contents/MacOS/portavoz-app""#))
        XCTAssertTrue(runner.contains(
            "resource_baseline.py assemble"))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "idle=$idle_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "refine=$refine_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "summary=$summary_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "ask=$ask_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "indexing=$indexing_sample")"#))
        XCTAssertTrue(runner.contains(
            "--bench-resource-recording-indexing"))
        XCTAssertTrue(runner.contains(
            #""recording-indexing=$recording_indexing_sample""#))
        XCTAssertTrue(runner.contains(
            "--bench-resource-recording-batch"))
        XCTAssertTrue(runner.contains(
            #""recording-batch=$recording_batch_sample""#))
        XCTAssertTrue(scheduler.contains(
            "static let mlx = IntelligenceScheduler"))
        XCTAssertTrue(mlxProvider.contains(
            "IntelligenceScheduler.mlx.run(priority)"))
        XCTAssertTrue(postCapture.contains(
            "priority: .background"))
        XCTAssertTrue(compatibilityRunner.contains(
            #"exec "$ROOT/scripts/run-resource-baseline.sh" "$@""#))
        XCTAssertFalse(runner.contains("/Applications/Portavoz.app"))
        for forbidden in [
            "meetingTitle", "transcriptText", "sourcePath", "modelName",
            "errorMessage",
        ] {
            XCTAssertFalse(
                nativeProbe.contains(forbidden),
                "Native resource samples must not admit \(forbidden)")
        }

        let appSources = try Self.sourceMatches(
            under: "Sources",
            pattern: #"resource-baseline(?:-matrix|-scorecard)?"#)
        XCTAssertTrue(
            appSources.isEmpty,
            "Production packages must not read resource evidence: \(appSources)")
    }

    func testLongCaptureEvidenceUsesProductionSessionAndBoundedHeap() throws {
        let writer = try Self.contents(
            of: "Sources/AudioCaptureKit/CaptureFileWriter.swift")
        let session = try Self.contents(
            of: "Sources/AudioCaptureKit/RecordingSession.swift")
        let publication = try Self.contents(
            of: "Sources/AudioCaptureKit/CaptureFilePublication.swift")
        let command = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchCapture.swift")
        let dispatch = try Self.contents(of: "Sources/portavoz-cli/CLI.swift")
        let runner = try Self.contents(
            of: "scripts/run-long-capture-baseline.sh")
        let validator = try Self.contents(
            of: "scripts/long_capture_evidence.py")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(writer.contains(
            "private var reusableBuffer: AVAudioPCMBuffer?"))
        XCTAssertTrue(writer.contains("func close()"))
        XCTAssertTrue(session.contains(
            "public let framesWritten: [AudioChannel: Int64]"))
        XCTAssertTrue(session.contains(
            "for writer in writers.values { writer.close() }"))
        XCTAssertTrue(publication.contains(
            "let reachedEnd = try autoreleasepool"))
        XCTAssertTrue(publication.contains(
            "handle.read(upToCount: 1 << 20)"))

        XCTAssertTrue(dispatch.contains(#"case "bench-capture":"#))
        XCTAssertTrue(command.contains(
            "let channels: [AudioChannel] = [.microphone, .system]"))
        XCTAssertTrue(command.contains(
            "barrier.wait("))
        XCTAssertFalse(command.contains("bufferingNewest"))
        XCTAssertTrue(command.contains(
            "maximumIncrementalHeapBytesInUse: UInt64 = 16 * 1_024 * 1_024"))
        XCTAssertTrue(runner.contains(
            "git status --porcelain --untracked-files=all"))
        XCTAssertTrue(runner.contains("output already exists"))
        XCTAssertTrue(runner.contains(
            "the source commit or worktree changed during collection"))
        XCTAssertTrue(runner.contains("swift build -c release --product portavoz-cli"))
        XCTAssertTrue(runner.contains("--duration-seconds 10800"))
        XCTAssertTrue(runner.contains("--source-commit \"$COMMIT\""))
        XCTAssertTrue(validator.contains("TOP_LEVEL_KEYS"))
        XCTAssertTrue(validator.contains("contentSource must be synthetic-only"))
        XCTAssertTrue(validator.contains("duration-invariant heap bound was exceeded"))
        XCTAssertTrue(decisions.contains("## D191"))
    }

    func testPlatformSecurityImplementationHasOneOuterOwner() throws {
        let securityImports = try Self.imports(under: "Sources")
            .filter { $0.module == "Security" }
            .map(\.file)
            .sorted()
        XCTAssertEqual(
            securityImports,
            [
                "IntegrationsKit/CloudKitMeetingSyncPlatform.swift",
                "PlatformKit/KeychainSecretStore.swift",
            ])

        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))
        XCTAssertEqual(
            try XCTUnwrap(targets["PlatformKit"]).dependencies,
            ["PortavozCore"])
        for target in ["portavoz-app", "portavoz-cli", "PortavozTests"] {
            XCTAssertTrue(try XCTUnwrap(targets[target]).dependencies.contains("PlatformKit"))
        }

        let directConsumers = try Self.sourceMatches(
            under: "Sources",
            pattern: #"\bKeychainSecretStore\s*\("#)
        XCTAssertEqual(
            directConsumers.sorted(),
            ["portavoz-app/AppServices.swift", "portavoz-cli/CLIComposition.swift"])
    }

    func testOnboardingPermissionsUsePlatformAdapters() throws {
        let onboarding = try Self.contents(
            of: "Sources/portavoz-app/OnboardingView.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Permissions.swift")
        let startRuntime = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StartRecording.swift")
        let platform = try Self.contents(
            of: "Sources/PlatformKit/MicrophonePermissionClient.swift")

        XCTAssertFalse(onboarding.contains("AVCaptureDevice"))
        XCTAssertFalse(onboarding.contains("CalendarAttendeeSource"))
        XCTAssertTrue(onboarding.contains("services.requestMicrophonePermission()"))
        XCTAssertTrue(onboarding.contains("services.requestOnboardingCalendarAccess()"))
        XCTAssertTrue(services.contains("microphonePermissions.request()"))
        XCTAssertTrue(services.contains("microphonePermissions.authorizeIfNeeded()"))
        let recordingAuthorization = try XCTUnwrap(startRuntime.range(
            of: "services.authorizeMicrophoneForRecording()"))
        let microphoneConstruction = try XCTUnwrap(startRuntime.range(
            of: "let microphone = MicrophoneSource("))
        XCTAssertLessThan(
            recordingAuthorization.lowerBound,
            microphoneConstruction.lowerBound)
        XCTAssertTrue(platform.contains("AVCaptureDevice.authorizationStatus"))
        XCTAssertTrue(platform.contains("AVCaptureDevice.requestAccess"))
    }

    func testMicrophoneTapDoesNotCoerceAStaleHardwareFormat() throws {
        let microphone = try Self.contents(
            of: "Sources/AudioCaptureKit/MicrophoneSource.swift")

        XCTAssertTrue(microphone.contains(
            "format: AudioInputTapPolicy.requestedFormat"))
        XCTAssertTrue(microphone.contains(
            "AudioInputTapPolicy.sourceSampleRate("))
        XCTAssertTrue(microphone.contains("for: buffer.format"))
        XCTAssertFalse(microphone.contains(
            "installTap(onBus: 0, bufferSize: 4096, format: format)"))
    }

    func testAudioRouteChangesCannotReuseOrRaceMutableGraphs() throws {
        let microphone = try Self.contents(
            of: "Sources/AudioCaptureKit/MicrophoneSource.swift")
        let processTap = try Self.contents(
            of: "Sources/AudioCaptureKit/ProcessTapSource.swift")

        XCTAssertTrue(microphone.contains(
            "private var routeTransitions = AudioRouteTransitionGate()"))
        XCTAssertTrue(microphone.contains("self.engine = AVAudioEngine()"))
        XCTAssertTrue(microphone.contains(
            "self.routeTransitions.admits(ticket)"))
        XCTAssertTrue(processTap.contains(
            "private var routeTransitions = AudioRouteTransitionGate()"))
        XCTAssertTrue(processTap.contains(
            "private func startOnRebuildQueue() throws"))
        XCTAssertTrue(processTap.contains(
            "private func stopOnRebuildQueue()"))
        XCTAssertTrue(processTap.contains(
            "self.routeTransitions.admits(ticket)"))
    }

    func testCommandLibraryReadsEnterThroughApplicationKitComposition() throws {
        for file in ["CLIAsk.swift", "CLIMcp.swift", "CLIMeetings.swift"] {
            let source = try Self.contents(of: "Sources/portavoz-cli/\(file)")
            XCTAssertFalse(source.contains("import StorageKit"), file)
            XCTAssertFalse(source.contains("MeetingStore("), file)
            XCTAssertTrue(source.contains("CLIComposition"), file)
        }
        let composition = try Self.contents(of: "Sources/portavoz-cli/CLIComposition.swift")
        XCTAssertTrue(composition.contains("let library: QueryMeetingLibrary"))
        XCTAssertTrue(composition.contains("let ask: AskMeetings"))
    }

    func testProductCLIWorkflowsEnterThroughApplicationKitComposition() throws {
        let files = [
            "CLITranscribe.swift", "CLIDiarize.swift", "CLISummarize.swift",
            "CLIRefine.swift", "CLIExport.swift", "CLIIssues.swift",
            "CLIVoice.swift", "CLIModels.swift",
        ]
        let forbiddenImports = [
            "ModelStoreKit", "TranscriptionKit", "DiarizationKit",
            "IntelligenceKit", "IntegrationsKit", "StorageKit",
        ]
        let forbiddenConcreteSymbols = [
            "ModelStore(", "WhisperEngine", "PyannoteDiarizer(",
            "MeetingStore(", "MeetingExporter.", "URLSessionDataEgressGateway(",
            "VoiceprintStore(",
        ]

        for file in files {
            let source = try Self.contents(of: "Sources/portavoz-cli/\(file)")
            XCTAssertTrue(source.contains("import ApplicationKit"), file)
            for module in forbiddenImports {
                XCTAssertFalse(source.contains("import \(module)"), "\(file): \(module)")
            }
            for symbol in forbiddenConcreteSymbols {
                XCTAssertFalse(source.contains(symbol), "\(file): \(symbol)")
            }
            XCTAssertFalse(source.contains("FileManager.default"), file)
        }

        let composition = try Self.contents(of: "Sources/portavoz-cli/CLIComposition.swift")
        let adapters = try Self.contents(of: "Sources/portavoz-cli/CLIProductAdapters.swift")
        for workflow in [
            "TranscribeAudioFile", "DiarizeAudioFile", "SummarizeAudioFile",
            "RefineMeetingUseCases", "ExportMeetingDocument",
            "PublishMeetingActionItems", "ManageLocalVoiceIdentity", "ManageLocalModels",
        ] {
            XCTAssertTrue(
                composition.contains(workflow) || adapters.contains(workflow),
                workflow)
        }
    }

    func testCompanionBYOKEgressCannotBypassTheGateway() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let byok = try Self.contents(of: "Sources/IntelligenceKit/BYOK.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let provenance = try Self.contents(
            of: "Sources/IntelligenceKit/CompanionGenerationProvenance.swift")
        // Live detection split into its own extension file (D138); the BYOK
        // wiring pins apply to the pair.
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
            + Self.contents(
                of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let refresh = try Self.contents(of: "Sources/portavoz-app/CompanionRefresh.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let appApplication = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")

        XCTAssertTrue(core.contains("public protocol DataEgressGateway"))
        XCTAssertFalse(core.contains("URLSession.shared"))
        XCTAssertTrue(adapter.contains("try Self.validate(networkRequest"))
        XCTAssertTrue(adapter.contains("delegate: DataEgressRedirectBlocker()"))
        XCTAssertTrue(byok.contains("private let gateway: any DataEgressGateway"))
        XCTAssertTrue(byok.contains("gateway.perform(networkRequest, metadata: metadata)"))
        let clientStart = try XCTUnwrap(
            byok.range(of: "public struct CompanionBYOKClient"))
        let settingsStart = try XCTUnwrap(byok.range(
            of: "public enum BYOKSettings",
            range: clientStart.upperBound..<byok.endIndex))
        let companionClient = byok[clientStart.lowerBound..<settingsStart.lowerBound]
        XCTAssertFalse(companionClient.contains("URLSession"))
        XCTAssertFalse(companionClient.contains("data(for:"))
        XCTAssertTrue(companion.contains("completeCompanionQuestion"))
        XCTAssertFalse(companion.contains("byok.complete("))
        XCTAssertFalse(companion.contains("OpenAICompatibleSummaryClient("))
        XCTAssertFalse(companion.contains("session.data(for:"))
        XCTAssertFalse(provenance.contains("session.data(for:"))
        XCTAssertTrue(provenance.contains(
            "egressConsentSource: DataEgressConsentSource = .explicitCompanionClient"))
        XCTAssertTrue(services.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(recording.contains("await services.companionBYOKClient()"))
        XCTAssertTrue(refresh.contains("byok: CompanionBYOKClient?"))
        XCTAssertTrue(appApplication.contains("BYOKSettings.companionClient("))
        XCTAssertTrue(appApplication.contains("apiKey: try? await secrets.value"))
        XCTAssertFalse(byok.contains("SecretStore"))
        for source in [recording, refresh] {
            XCTAssertTrue(source.contains(
                "egressConsentSource: .companionBYOKSettings"))
            XCTAssertFalse(source.contains("URLSession.shared"))
            XCTAssertFalse(source.contains("data(for:"))
        }
    }

    func testOpenAICompatibleSummaryEgressCannotBypassTheGateway() throws {
        let byok = try Self.contents(of: "Sources/IntelligenceKit/BYOK.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let ollama = try Self.contents(of: "Sources/IntelligenceKit/OllamaService.swift")
        let regeneration = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")
        let processing = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let cli = try Self.contents(of: "Sources/portavoz-cli/CLISummarize.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-cli/CLIComposition.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/AnalyzeAudioFile.swift")

        XCTAssertTrue(byok.contains("public struct OpenAICompatibleSummaryClient"))
        XCTAssertTrue(byok.contains("private let gateway: any DataEgressGateway"))
        let summaryStart = try XCTUnwrap(
            byok.range(of: "public struct OpenAICompatibleSummaryClient"))
        let companionStart = try XCTUnwrap(byok.range(
            of: "struct CompanionDataEgressContext",
            range: summaryStart.upperBound..<byok.endIndex))
        let summaryClient = byok[summaryStart.lowerBound..<companionStart.lowerBound]
        XCTAssertTrue(summaryClient.contains("gateway.perform(networkRequest, metadata: metadata)"))
        XCTAssertFalse(summaryClient.contains("URLSession"))
        XCTAssertFalse(summaryClient.contains("data(for:"))
        XCTAssertTrue(provider.contains("client.completeSummary("))
        XCTAssertFalse(provider.contains("URLSession"))
        XCTAssertFalse(provider.contains("data(for:"))
        XCTAssertTrue(ollama.contains("gateway: any DataEgressGateway"))

        XCTAssertTrue(regeneration.contains("gateway: gateway"))
        XCTAssertTrue(regeneration.contains("consentSource: .summaryEngineSettings"))
        XCTAssertTrue(processing.contains("gateway: dataEgressGateway"))
        XCTAssertTrue(processing.contains("consentSource: .summaryEngineSettings"))
        XCTAssertTrue(cli.contains("platform.summarizeAudio("))
        XCTAssertFalse(cli.contains("application?.store"))
        XCTAssertFalse(cli.contains("OpenAICompatibleSummaryProvider("))
        XCTAssertTrue(composition.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        let admittedMeeting = try XCTUnwrap(workflow.range(
            of: "try await store.saveAnalyzedMeeting("))
        let remoteSummary = try XCTUnwrap(workflow.range(
            of: "let draft = try await processor.summarize(summaryRequest)"))
        XCTAssertLessThan(admittedMeeting.lowerBound, remoteSummary.lowerBound)
        XCTAssertFalse(cli.contains("URLSession.shared"))
        XCTAssertFalse(cli.contains("data(for:"))
    }

    func testExplicitPublishingEgressCannotBypassTheGateway() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let gist = try Self.contents(of: "Sources/IntegrationsKit/GistPublisher.swift")
        let issues = try Self.contents(of: "Sources/IntegrationsKit/IssueExporters.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let appDocuments = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDocuments.swift")
        let applicationDocuments = try Self.contents(
            of: "Sources/ApplicationKit/PublishMeetingContent.swift")
        let cliExport = try Self.contents(of: "Sources/portavoz-cli/CLIExport.swift")
        let cliIssues = try Self.contents(of: "Sources/portavoz-cli/CLIIssues.swift")
        let cliComposition = try Self.contents(
            of: "Sources/portavoz-cli/CLIComposition.swift")
        let cliAdapters = try Self.contents(
            of: "Sources/portavoz-cli/CLIProductAdapters.swift")

        for operation in ["publishGitHubGist", "createGitHubIssue", "createLinearIssue"] {
            XCTAssertTrue(core.contains(operation))
            XCTAssertTrue(adapter.contains("case .\(operation):"))
        }
        for publisher in [gist, issues] {
            XCTAssertTrue(publisher.contains("private let gateway: any DataEgressGateway"))
            XCTAssertTrue(publisher.contains("gateway.perform("))
            XCTAssertFalse(publisher.contains("URLSession"))
            XCTAssertFalse(publisher.contains("data(for:"))
        }
        XCTAssertTrue(detail.contains("model.send(.publishGist)"))
        XCTAssertTrue(detail.contains("model.send(.prepareDocument("))
        XCTAssertFalse(detail.contains("services.publishMeetingDetailGist("))
        XCTAssertFalse(detail.contains("services.prepareMeetingDetailDocument("))
        XCTAssertFalse(detail.contains("GistPublisher("))
        XCTAssertFalse(detail.contains("MeetingExporter.markdown("))
        XCTAssertFalse(detail.contains("gateway: services.dataEgressGateway"))
        XCTAssertTrue(appDocuments.contains("PrepareMeetingDocument("))
        XCTAssertTrue(appDocuments.contains("ExportMeetingDocument("))
        XCTAssertTrue(appDocuments.contains("GistPublisher(token: token, gateway: gateway)"))
        XCTAssertTrue(applicationDocuments.contains("struct PrepareMeetingDocument"))
        XCTAssertTrue(cliExport.contains("application.exportMeetingDocument("))
        XCTAssertTrue(cliExport.contains("meetingID: meetingID"))
        XCTAssertTrue(cliExport.contains("md|pdf|srt|vtt"))
        XCTAssertTrue(cliExport.contains("MeetingDocumentFormat("))
        XCTAssertTrue(cliExport.contains("fileExtension: gist ? \"md\" : format"))
        XCTAssertTrue(cliIssues.contains("application.publishMeetingActionItems("))
        XCTAssertTrue(cliIssues.contains("meetingID: meetingID"))
        XCTAssertTrue(cliComposition.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(cliAdapters.contains("meetingID: meetingID"))
        for source in [cliExport, cliIssues] {
            XCTAssertFalse(source.contains("GistPublisher("))
            XCTAssertFalse(source.contains("GitHubIssuesExporter("))
            XCTAssertFalse(source.contains("LinearExporter("))
        }
    }

    func testMeetingContentEgressPersistsReceiptBeforeTransport() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+PrivacyReceipt.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")

        XCTAssertTrue(core.contains("public protocol DataEgressEventRecorder"))
        XCTAssertTrue(core.contains("public struct PrivacyReceipt"))
        let validation = try XCTUnwrap(adapter.range(of: "try Self.validate(networkRequest"))
        let receipt = try XCTUnwrap(adapter.range(of: "recordDataEgressEvent"))
        let transport = try XCTUnwrap(adapter.range(of: "let (data, response) = try await session.data("))
        XCTAssertLessThan(validation.lowerBound, receipt.lowerBound)
        XCTAssertLessThan(receipt.lowerBound, transport.lowerBound)
        XCTAssertTrue(storage.contains("extension MeetingStore: DataEgressEventRecorder"))
        XCTAssertTrue(storage.contains("guard let meetingID = event.meetingID"))
        XCTAssertTrue(services.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))

        let forbiddenReceiptFields = [
            "transcript", "prompt", "markdown", "question", "answer", "actionItemText",
        ]
        let eventStart = try XCTUnwrap(core.range(of: "public struct DataEgressEvent"))
        let recorderStart = try XCTUnwrap(core.range(
            of: "public protocol DataEgressEventRecorder",
            range: eventStart.upperBound..<core.endIndex))
        let eventSource = core[eventStart.lowerBound..<recorderStart.lowerBound]
        for field in forbiddenReceiptFields {
            XCTAssertFalse(eventSource.contains("public let \(field)"), field)
        }
    }

    func testApplicationKitImportsStayInsideTheApprovedLayer() throws {
        let allowed = Set([
            "AudioPlaybackKit", "Foundation", "Observation", "PortavozCore",
            "TranscriptionKit", "DiarizationKit", "IntelligenceKit", "StorageKit",
        ])
        let violations = try Self.imports(under: "Sources/ApplicationKit")
            .filter { !allowed.contains($0.module) }
            .map { "\($0.file): \($0.module)" }
            .sorted()
        let platformSymbols = try Self.sourceMatches(
            under: "Sources/ApplicationKit",
            pattern: #"\b(?:FileManager|UserDefaults|URLSession)\b"#)

        XCTAssertTrue(
            violations.isEmpty,
            "ApplicationKit imported presentation/platform/database APIs: \(violations)")
        XCTAssertTrue(
            platformSymbols.isEmpty,
            "ApplicationKit used a platform adapter directly: \(platformSymbols)")
    }

    func testAppMeetingLifecycleWritesEnterThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\b(?:services\.)?store\.(?:delete|restore|purge)\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App MeetingStore lifecycle writes must enter through ApplicationKit: \(violations)")
    }

    func testAppSummaryRegenerationEntersThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"services\.store\.latestSummary\s*\(|services\.configuredSummaryProvider\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App summary regeneration must enter through ApplicationKit: \(violations)")
    }

    func testAppAudioImportEntersThroughApplicationKit() throws {
        let definitions = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\bfunc\s+importMeeting\s*\("#)

        XCTAssertEqual(
            definitions,
            ["AppServices+ImportMeeting.swift"],
            "Audio import orchestration must not return to AppServices or a view")
    }

    func testAppMeetingRefineEntersThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"services\.store\.(?:applyRefinedCast|replaceCast|replaceCompanionCards)\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App refine mutations must enter through ApplicationKit: \(violations)")
    }

    func testAppRecordingStopEntersThroughApplicationKit() throws {
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")

        XCTAssertTrue(controller.contains("services.stopRecording.execute"))
        XCTAssertFalse(controller.contains("services.store.installCapturedSnapshot"))
        XCTAssertFalse(controller.contains(
            "PostCaptureProcessingCoordinator.initialDiarizationRequest"))
    }

    func testAppRecordingStartEntersThroughApplicationKit() throws {
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StartRecording.swift")

        XCTAssertTrue(controller.contains("services.startRecording.execute"))
        XCTAssertTrue(adapter.contains("var startRecording: StartRecording"))
        XCTAssertFalse(
            adapter.contains("try await services.loadEnginesIfNeeded()"),
            "Recording start must never wait for model preparation")
        XCTAssertTrue(adapter.contains("LiveTranscriptionAttacher("))
        XCTAssertTrue(adapter.contains("services.acquireResidentLiveSpeechRuntime()"))
        XCTAssertTrue(adapter.contains("services.acquireLiveSpeechRuntime()"))
        XCTAssertTrue(adapter.contains("voiceProcessing: false"))
        XCTAssertFalse(adapter.contains("aecEnabled"))
        XCTAssertTrue(controller.contains("receiveLiveTranscription("))
        XCTAssertFalse(controller.contains("services.store.beginRecording"))
        XCTAssertFalse(controller.contains("MicrophoneSource("))
        XCTAssertFalse(controller.contains("RecordingSession("))
        XCTAssertFalse(controller.contains("makeSystemTapSource"))

        let microphone = try Self.contents(
            of: "Sources/AudioCaptureKit/MicrophoneSource.swift")
        XCTAssertTrue(microphone.contains(
            "voiceProcessing: Bool = false"))
    }

    func testLiveCaptionPresentationOwnsItsWorkBounds() throws {
        let projector = try Self.contents(
            of: "Sources/portavoz-app/LiveCaptionParagraphProjector.swift")
        let recordingView = try Self.contents(
            of: "Sources/portavoz-app/RecordingView.swift")
        let talkBalance = try Self.contents(
            of: "Sources/IntelligenceKit/LiveTalkTimePolicy.swift")

        XCTAssertTrue(projector.contains("static let maximumSourceRows = 150"))
        XCTAssertTrue(projector.contains(
            "captions.suffix(Self.maximumSourceRows)"))
        XCTAssertFalse(recordingView.contains(
            "controller.captions.suffix(150)"),
            "the pure projector, not one presentation caller, owns the bound")
        XCTAssertTrue(talkBalance.contains(
            "public static let maximumCandidateRows = 1_024"))
        XCTAssertTrue(talkBalance.contains(
            "captions.suffix(maximumCandidateRows + 1).dropLast()"))
    }

    func testMeetingWaveformDeliveryOwnsItsBoundAndCancellation() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/MeetingAudioWorkflows.swift")
        let waveform = try Self.contents(
            of: "Sources/AudioPlaybackKit/Waveform.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains(
            "public static let defaultBucketCount = 600"))
        XCTAssertTrue(workflow.contains(
            "public static let maximumBucketCount = 2_000"))
        XCTAssertTrue(workflow.contains(
            "MeetingWaveformDeliveryPolicy.admittedBucketCount"))
        XCTAssertTrue(workflow.contains(
            "try await Waveform.generateCancellable("))
        XCTAssertFalse(workflow.contains(
            "await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(waveform.contains("withTaskCancellationHandler"))
        XCTAssertTrue(waveform.contains("worker.cancel()"))
        XCTAssertTrue(waveform.contains("cancellationCheck:"))
        XCTAssertTrue(decisions.contains(
            "## D175 — Cancel obsolete waveform derivation by route"))
    }

    func testTurnEndpointStaysDeterministicPolicyDrivenAndCoalescerFree() throws {
        let policy = try Self.contents(
            of: "Sources/IntelligenceKit/TurnEndpointPolicy.swift")
        // Detection lives in its own extension file; card-state mutation
        // stays in the main file behind recordCompanionOutcome.
        let mainController = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let detectionController = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let controller = mainController + detectionController
        let coalescer = try Self.contents(
            of: "Sources/TranscriptionKit/CaptionCoalescer.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // The endpointer never touches the caption model: rows still close
        // only when the next delta appends, so presentation and dictation
        // (which share the coalescer) are untouched.
        XCTAssertFalse(coalescer.contains("TurnEndpoint"))
        XCTAssertFalse(coalescer.contains("Task.sleep"))
        // The controller consumes the policy rather than embedding thresholds,
        // and speculation reuses the SAME dispatch as the real close — no
        // second detection path that could drift.
        XCTAssertTrue(controller.contains("TurnEndpointPolicy.silenceSeconds"))
        XCTAssertTrue(controller.contains("TurnEndpointPolicy.isTurnEndCandidate("))
        XCTAssertTrue(controller.contains("TurnEndpointPolicy.shouldDetect("))
        XCTAssertEqual(
            controller.components(
                separatedBy: "TurnEndpointPolicy.isTurnEndCandidate("
            ).count - 1,
            1,
            "real-close and silence paths must share one candidate gate")
        XCTAssertTrue(controller.contains("turnEndpointTask?.cancel()"))
        XCTAssertTrue(controller.contains("dispatchCompanionDetection(for:"))
        let enabledStart = try XCTUnwrap(mainController.range(
            of: "var companionEnabled"))
        let translationStart = try XCTUnwrap(mainController.range(
            of: "/// Live caption translations",
            range: enabledStart.upperBound..<mainController.endIndex))
        let enabledProperty = mainController[
            enabledStart.lowerBound..<translationStart.lowerBound]
        XCTAssertTrue(enabledProperty.contains("armTurnEndpointDeadline()"))

        let applyStart = try XCTUnwrap(mainController.range(
            of: "private func applyStartRecordingResult"))
        let failureStart = try XCTUnwrap(mainController.range(
            of: "private func presentStartFailure",
            range: applyStart.upperBound..<mainController.endIndex))
        let startResult = mainController[
            applyStart.lowerBound..<failureStart.lowerBound]
        let recordingPhase = try XCTUnwrap(startResult.range(
            of: "phase = .recording"))
        let lifecycleActivation = try XCTUnwrap(startResult.range(
            of: "activateCompanionDetectionAfterRecordingStart()",
            range: recordingPhase.upperBound..<startResult.endIndex))
        XCTAssertLessThan(recordingPhase.lowerBound, lifecycleActivation.lowerBound)
        XCTAssertTrue(detectionController.contains(
            "for closed in captions.dropLast()"))
        XCTAssertTrue(detectionController.contains(
            "lastOpenRowID = captions.last?.id"))
        // The policy is deterministic: no model, no scheduler, no clock.
        XCTAssertFalse(policy.contains("LanguageModelSession"))
        XCTAssertFalse(policy.contains("IntelligenceScheduler"))
        XCTAssertFalse(policy.contains("Date("))
        XCTAssertTrue(decisions.contains("## D138"))
    }

    func testAppIntentsStaySDKOnlySoMetadataExtractionCannotBreak() throws {
        let intents = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppIntents.swift")
        let appDelegate = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppDelegate.swift")
        let extractor = try Self.contents(
            of: "scripts/build-appintents-metadata.sh")
        let packager = try Self.contents(of: "scripts/make-app.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // The release pipeline compiles this ONE file standalone to extract
        // App Intents metadata (D139). An import of any project module would
        // break that compile — at release time, not at test time — so the
        // SDK-only diet is enforced here.
        let allowedImports: Set<String> = ["AppIntents", "AppKit", "Foundation"]
        // Tokenize rather than prefix-match: an indented `import` (inside
        // #if) must not slip through, and a trailing comment or a kind
        // import (`import struct Foundation.URL`) must not mis-parse.
        let importKinds: Set<String> = [
            "typealias", "struct", "class", "enum", "protocol", "let", "var", "func"
        ]
        let imports: [String] = intents.split(separator: "\n").compactMap { rawLine in
            var tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            while let first = tokens.first, first.hasPrefix("@") {
                tokens.removeFirst()
            }
            guard tokens.first == "import" else { return nil }
            tokens.removeFirst()
            if let kind = tokens.first, importKinds.contains(kind) {
                tokens.removeFirst()
            }
            guard let spec = tokens.first else { return nil }
            return spec.split(separator: ".").first.map(String.init)
        }
        XCTAssertFalse(
            imports.isEmpty,
            "the import scan must see the intents file's imports; an empty parse means the parser rotted, not that the diet holds")
        for module in imports {
            XCTAssertTrue(
                allowedImports.contains(module),
                "PortavozAppIntents.swift must stay SDK-only; found: \(module)")
        }
        // The extractor uses the SHIPPING module name, and the packager
        // fails the build rather than shipping silently without intents.
        XCTAssertTrue(extractor.contains("-module-name portavoz_app"))
        XCTAssertTrue(extractor.contains("declares no actions"))
        XCTAssertTrue(packager.contains("scripts/build-appintents-metadata.sh"))
        XCTAssertFalse(
            intents.contains("NSWorkspace.shared.open"),
            "the intent must route inside its owning process, not ask LaunchServices to choose a URL handler")
        XCTAssertTrue(intents.contains(
            "PortavozAppIntentBridge.requestStartRecording()"))
        XCTAssertTrue(appDelegate.contains(
            "PortavozAppIntentBridge.consumeStartRecordingRequest()"))
        XCTAssertFalse(
            intents.contains("AppShortcutsProvider"),
            "macOS publishes the action only; an App Shortcut duplicates it in the picker")
        XCTAssertFalse(
            appDelegate.contains("updateAppShortcutParameters()"),
            "macOS has no App Shortcut representation to refresh")
        XCTAssertTrue(extractor.contains("must not publish unsupported App Shortcuts"))
        XCTAssertTrue(decisions.contains("## D139"))
        XCTAssertTrue(decisions.contains("## D141"))
    }

    func testRecordingLifecycleFailuresStayTypedUntilPresentation() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/FailureCategory.swift")
        let start = try Self.contents(of: "Sources/ApplicationKit/StartRecording.swift")
        let stop = try Self.contents(of: "Sources/ApplicationKit/StopRecording.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")

        for category in [
            "critical", "recoverable", "degradable", "external", "destructive",
        ] {
            XCTAssertTrue(core.contains("case \(category)"))
        }
        XCTAssertTrue(core.contains("public protocol CodedFailure"))
        XCTAssertTrue(start.contains("public enum StartRecordingFailure"))
        XCTAssertTrue(stop.contains("public enum StopRecordingFailure"))
        XCTAssertFalse(start.contains("error.localizedDescription"))
        XCTAssertFalse(stop.contains("error.localizedDescription"))
        XCTAssertFalse(start.contains("message: String"))
        XCTAssertFalse(stop.contains("processingFailed(message:"))
        XCTAssertTrue(controller.contains("presentStartFailure(failure)"))
        XCTAssertTrue(controller.contains("presentStopFailure(failure"))
        XCTAssertTrue(controller.contains("L10n.text("))
    }

    func testSpeechModelReadinessIsScopedToTheWorkflowCapability() throws {
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let liveSpeech = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LiveSpeechModels.swift")
        let refine = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RefineMeeting.swift")
        let importAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ImportMeeting.swift")
        let recovery = try Self.contents(
            of: "Sources/portavoz-app/AppPostCaptureProcessingCapabilities.swift")

        let refinePrepareStart = try XCTUnwrap(refine.range(of: "func prepare("))
        let refineTranscribeStart = try XCTUnwrap(refine.range(
            of: "func transcribe(", range: refinePrepareStart.upperBound..<refine.endIndex))
        let refinePreparation = refine[
            refinePrepareStart.lowerBound..<refineTranscribeStart.lowerBound]
        XCTAssertTrue(refinePreparation.contains("acquireWhisperRuntime"))
        XCTAssertFalse(
            refinePreparation.contains("loadEnginesIfNeeded"),
            "Refine readiness requires Whisper only; diarization remains degradable")
        XCTAssertTrue(refine.contains("services.acquireDiarizationRuntime()"))

        let diarization = try Self.contents(
            of: "Sources/portavoz-app/AppServices+DiarizationModels.swift")
        XCTAssertTrue(liveSpeech.contains("ParakeetEngine.loadRecommended"))
        XCTAssertFalse(liveSpeech.contains("PyannoteDiarizer"))
        XCTAssertTrue(diarization.contains(
            "PyannoteDiarizationRuntime.loadRecommended"))
        XCTAssertFalse(diarization.contains("ParakeetEngine"))
        XCTAssertTrue(services.contains("liveSpeechRuntimeLoad"))
        XCTAssertTrue(services.contains("diarizationRuntimeLoad"))

        XCTAssertTrue(importAdapter.contains("services.acquireDiarizationRuntime()"))
        XCTAssertFalse(importAdapter.contains("services.loadEnginesIfNeeded()"))
        XCTAssertTrue(recovery.contains("services.acquireLiveSpeechRuntime("))
        XCTAssertTrue(recovery.contains("services.finishLiveSpeechRuntime("))
        XCTAssertFalse(recovery.contains("services.loadEnginesIfNeeded()"))
    }

    func testSettingsWhisperDownloadUsesAppScopedVerifiedPreparation() throws {
        let settings = try Self.contents(of: "Sources/portavoz-app/SettingsView.swift")
        let models = try Self.contents(
            of: "Sources/portavoz-app/AppServices+WhisperModels.swift")
        let engine = try Self.contents(of: "Sources/TranscriptionKit/WhisperEngine.swift")

        XCTAssertTrue(settings.contains("services.prepareWhisperVariant(variant.id)"))
        XCTAssertFalse(settings.contains("ModelStore()"))
        XCTAssertTrue(models.contains("whisperBackgroundPreparation"))
        XCTAssertTrue(models.contains("whisperPreparedModel = prepared"))
        XCTAssertTrue(models.contains("finishWhisperPreparation(active)"))
        XCTAssertTrue(engine.contains("public struct PreparedModel"))
        XCTAssertTrue(engine.contains("return try await loadPrepared(prepared)"))
    }

    func testAppModelReadinessComesOnlyFromVerifiedCatalogInstallations() throws {
        let store = try Self.contents(of: "Sources/ModelStoreKit/ModelStore.swift")
        let lifecycle = try Self.contents(
            of: "Sources/ModelStoreKit/VerifiedModelLifecycle.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let whisper = try Self.contents(
            of: "Sources/portavoz-app/AppServices+WhisperModels.swift")
        let summary = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")

        XCTAssertTrue(store.contains("func verifiedInstallation("))
        XCTAssertTrue(store.contains("guard verify(descriptor).isComplete"))
        XCTAssertTrue(lifecycle.contains("store.verifiedInstallation(descriptor)"))
        XCTAssertFalse(lifecycle.contains("FileManager"))
        XCTAssertTrue(services.contains("let modelStore: ModelStore"))
        XCTAssertTrue(services.contains("let modelLifecycle: VerifiedModelLifecycle"))
        XCTAssertFalse(services.contains("model.safetensors"))
        XCTAssertFalse(whisper.contains("modelArtifactsAreComplete"))
        XCTAssertFalse(whisper.contains("attributesOfItem"))
        XCTAssertTrue(summary.contains("await mlxModelDirectory()"))

        let directStores = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\bModelStore\s*\(\s*\)"#)
        XCTAssertEqual(
            directStores.sorted(),
            ["AppServices.swift", "BenchMode.swift"],
            "production model consumers must share app-scoped verified readiness")
    }

    func testLocalVoiceEnrollmentEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ManageLocalVoiceAndModels.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalVoiceIdentity.swift")
        let settings = try Self.contents(of: "Sources/portavoz-app/SettingsView.swift")
        let onboarding = try Self.contents(of: "Sources/portavoz-app/OnboardingView.swift")

        XCTAssertTrue(workflow.contains("case recordAndEnroll("))
        XCTAssertTrue(workflow.contains("case enrollSample("))
        XCTAssertTrue(workflow.contains("LocalVoiceSampleCapturing"))
        XCTAssertTrue(workflow.contains("LocalVoiceSampleIdentityExtracting"))
        XCTAssertTrue(adapter.contains("ManageLocalVoiceIdentity("))
        XCTAssertTrue(adapter.contains("MicrophoneSource("))
        XCTAssertTrue(adapter.contains("voiceProcessing: mode == .echoCancelled"))
        XCTAssertTrue(adapter.contains("ContinuousClock()"))
        XCTAssertEqual(
            adapter.components(separatedBy: "await microphone.stop()").count - 1,
            2)
        XCTAssertTrue(adapter.contains("services.acquireDiarizationRuntime()"))
        XCTAssertTrue(adapter.contains("services.finishDiarizationRuntime("))
        XCTAssertTrue(adapter.contains("services.makeDiarizer("))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(adapter.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(settings.contains("services.recordAndEnrollLocalVoice("))
        XCTAssertTrue(settings.contains("services.deleteLocalVoiceIdentity()"))
        XCTAssertFalse(settings.contains("try? await services.deleteLocalVoiceIdentity()"))
        XCTAssertTrue(settings.contains("settings-voice-enroll"))
        XCTAssertTrue(onboarding.contains("services.enrollLocalVoice(from:"))
        XCTAssertTrue(onboarding.contains("services.recordAndEnrollLocalVoice("))
        XCTAssertTrue(onboarding.contains("LocalVoiceSample.minimumEnrollmentDuration"))
        XCTAssertTrue(onboarding.contains("onboarding-voice-enroll"))
        for presentation in [settings, onboarding] {
            XCTAssertFalse(presentation.contains("MicrophoneSource("))
            XCTAssertFalse(presentation.contains("extractVoiceprint("))
            XCTAssertFalse(presentation.contains("services.voiceprintStore"))
            XCTAssertFalse(presentation.contains(
                "services.acquireDiarizationRuntime()"))
            XCTAssertFalse(presentation.contains("import AudioCaptureKit"))
            XCTAssertFalse(presentation.contains("import DiarizationKit"))
        }
    }

    func testAppLaunchRecoveryEntersThroughApplicationKitBeforeWorkerResume() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/RecordingRecoveryCoordinator.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RecoverInterruptedMeetings.swift")
        let launch = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")

        XCTAssertTrue(coordinator.contains("services.recoverInterruptedMeetings.execute"))
        XCTAssertTrue(adapter.contains("CaptureFileRecovery"))
        XCTAssertFalse(coordinator.contains("recoverExpiredProcessingJobs"))
        XCTAssertFalse(coordinator.contains("installRecoveredCaptureAssets"))
        XCTAssertFalse(coordinator.contains("installCapturedSnapshot"))
        XCTAssertFalse(coordinator.contains("markMeetingNeedsAttention"))
        XCTAssertFalse(coordinator.contains("CaptureFileRecovery"))
        let recovery = try XCTUnwrap(launch.range(of:
            "RecordingRecoveryCoordinator.runIfNeeded"))
        let worker = try XCTUnwrap(launch.range(of:
            "PostCaptureProcessingCoordinator.resumeAfterRecovery"))
        let recommendation = try XCTUnwrap(launch.range(of:
            "appServices.configureInitialSummaryProviderIfNeeded"))
        XCTAssertLessThan(recovery.lowerBound, worker.lowerBound)
        XCTAssertLessThan(worker.lowerBound, recommendation.lowerBound)
    }

    func testLocalSummaryProviderDiscoveryEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/LocalSummaryProviders.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalSummaryProviders.swift")
        let settings = try Self.contents(of: "Sources/portavoz-app/SettingsView.swift")
        let onboarding = try Self.contents(of: "Sources/portavoz-app/OnboardingView.swift")

        XCTAssertTrue(workflow.contains("struct DiscoverLocalSummaryProviders"))
        XCTAssertTrue(workflow.contains("struct ConfigureInitialSummaryProvider"))
        XCTAssertTrue(workflow.contains("enum LocalSummaryProviderPolicy"))
        XCTAssertTrue(workflow.contains("enum LocalSummaryRecommendationReason"))
        XCTAssertTrue(workflow.contains("func saveInitialSummaryProviderSelection"))
        for concrete in [
            "OllamaService", "UserDefaults", "ProcessInfo", "NSHomeDirectory",
        ] {
            XCTAssertFalse(workflow.contains(concrete), concrete)
            XCTAssertTrue(adapter.contains(concrete), concrete)
        }
        XCTAssertFalse(workflow.contains("FoundationModelsCapability"))
        XCTAssertTrue(adapter.contains("foundationModelsCapability.isAvailable"))
        XCTAssertTrue(adapter.contains("contains(\"-use-temp-store\")"))
        XCTAssertTrue(adapter.contains("ollama: .unavailable"))
        XCTAssertTrue(adapter.contains("@MainActor"))
        XCTAssertTrue(adapter.contains("struct AppSummaryProviderSelectionStore"))
        for presentation in [settings, onboarding] {
            XCTAssertTrue(presentation.contains("discoverLocalSummaryProviders"))
            XCTAssertFalse(presentation.contains("HardwareRecommender"))
            XCTAssertFalse(presentation.contains("currentHardwareProfile"))
            XCTAssertFalse(presentation.contains("InitialSummaryEnginePolicy"))
            XCTAssertFalse(presentation.contains("OllamaService"))
        }
    }

    func testSettingsResourcesEnterThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SettingsResources.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SettingsResources.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsView.swift")
        let audio = try Self.contents(
            of: "Sources/portavoz-app/AudioSection.swift")
        let voices = try Self.contents(
            of: "Sources/portavoz-app/RememberedVoicesSection.swift")

        for useCase in [
            "struct LoadAudioInputOptions",
            "struct ManageRecordingStorage",
            "struct ManageRememberedVoices",
        ] {
            XCTAssertTrue(workflow.contains(useCase), useCase)
        }
        for concreteImport in [
            "import AudioCaptureKit", "import DiarizationKit", "import StorageKit",
        ] {
            XCTAssertFalse(workflow.contains(concreteImport), concreteImport)
        }
        for concrete in [
            "AudioDeviceCatalog", "RecordingsLocation", "VoiceGallery",
        ] {
            XCTAssertTrue(adapter.contains(concrete), concrete)
        }
        XCTAssertTrue(adapter.contains("AsyncStream<RecordingStorageProgress>"))
        XCTAssertTrue(settings.contains("services.updateRecordingStorage"))
        XCTAssertFalse(settings.contains("RecordingsLocation"))
        XCTAssertFalse(settings.contains("Task.detached"))
        XCTAssertFalse(settings.contains("import StorageKit"))
        XCTAssertTrue(audio.contains("services.audioInputOptions()"))
        XCTAssertFalse(audio.contains("AudioDeviceCatalog"))
        XCTAssertFalse(audio.contains("import AudioCaptureKit"))
        XCTAssertTrue(voices.contains("services.rememberedVoiceSummaries()"))
        XCTAssertTrue(voices.contains("services.removeRememberedVoice"))
        XCTAssertTrue(voices.contains("services.removeAllRememberedVoices"))
        XCTAssertFalse(voices.contains("services.voiceGallery"))
        XCTAssertFalse(voices.contains("import DiarizationKit"))
        XCTAssertFalse(voices.contains("try?"))
    }

    func testAppPostCaptureExecutionEntersThroughApplicationKit() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppPostCaptureProcessingCapabilities.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessPostCaptureJobs.swift")

        XCTAssertTrue(coordinator.contains("services.processPostCaptureJobs.execute"))
        XCTAssertTrue(coordinator.contains("processPostCaptureJobs.nextScheduledDate"))
        for bypass in [
            "claimNextProcessingJob", "heartbeatProcessingJob",
            "suspendProcessingJob",
            "completeTranscriptionJob", "completeDiarizationJob",
            "completeSummaryJob", "failProcessingJob",
            "cancelProcessingJob", "nextScheduledProcessingDate"
        ] {
            XCTAssertFalse(
                coordinator.contains(bypass),
                "Post-capture product policy bypasses ApplicationKit through \(bypass)")
        }

        for ownedPolicy in [
            "claimPostCaptureJob", "heartbeatPostCaptureJob",
            "suspendPostCaptureJob",
            "processTranscription", "processDiarization", "processSummary",
            "SummaryOperationFingerprint.compute", "retryDate",
            "cancelPostCaptureJob", "failPostCaptureJob"
        ] {
            XCTAssertTrue(
                workflow.contains(ownedPolicy),
                "Application workflow is missing \(ownedPolicy)")
        }
        for concreteDependency in [
            "RecordingsLocation", "FileManager", "UserDefaults",
            "PostMeetingShortcut", "OSSignposter", "AppServices"
        ] {
            XCTAssertFalse(
                workflow.contains(concreteDependency),
                "Application workflow contains concrete app dependency \(concreteDependency)")
        }
        for adapterDependency in [
            "RecordingsLocation", "FileManager", "acquireLiveSpeechRuntime",
            "acquireDiarizationRuntime", "PostMeetingShortcut.runIfConfigured"
        ] {
            XCTAssertTrue(adapter.contains(adapterDependency))
        }
    }

    func testDurableWorkOwnershipMatchesItsRecoveryGranularity() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessPostCaptureJobs.swift")
        let jobs = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+ProcessingJobs.swift")
        let semantic = try Self.contents(
            of: "Sources/portavoz-app/SemanticCorpusIndexingSupervisor.swift")
        let semanticWorkflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessSemanticCorpusMaintenance.swift")
        let semanticStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DerivedMaintenance.swift")
        let sync = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncCoordinator.swift")
        let backup = try Self.contents(
            of: "Sources/ApplicationKit/ExportLibraryMarkdownBackup.swift")
        let backupStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryMarkdownBackup.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let storageSpec = try Self.contents(of: "docs/specs/05-storage.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")

        XCTAssertTrue(workflow.contains("suspendPostCaptureJob"))
        XCTAssertTrue(workflow.contains("return (.suspended, true, nil)"))
        XCTAssertTrue(workflow.contains("if execution.shouldStop { break }"))
        XCTAssertTrue(jobs.contains("suspendProcessingJob"))
        XCTAssertTrue(jobs.contains("record.attempt -= 1"))
        XCTAssertTrue(jobs.contains("processing.lease.expired"))
        XCTAssertTrue(semanticWorkflow.contains("return .paused"))
        XCTAssertTrue(semanticWorkflow.contains("heartbeatTask"))
        XCTAssertTrue(semanticStore.contains("suspendSemanticCorpusMaintenance"))
        XCTAssertTrue(semantic.contains("Task.sleep"))
        XCTAssertTrue(sync.contains(".paused(processedCount:"))
        XCTAssertTrue(backup.contains("return .suspended"))
        XCTAssertTrue(backupStore.contains(".owner.lock"))
        XCTAssertTrue(backupStore.contains("portavoBSDFileLock"))
        for replaySafeOwner in [sync, backup, backupStore] {
            XCTAssertFalse(replaySafeOwner.contains("heartbeat"))
            XCTAssertFalse(replaySafeOwner.contains("Timer"))
            XCTAssertFalse(replaySafeOwner.contains("Task.sleep"))
        }
        XCTAssertTrue(architecture.contains(
            "Intentional suspension explicitly returns"))
        XCTAssertTrue(decisions.contains("## D190"))
        XCTAssertTrue(storageSpec.contains("Intentional suspension"))
        XCTAssertTrue(appSpec.contains("Intentional workflow cancellation"))
    }

    func testAppMeetingBundleImportEntersThroughApplicationKit() throws {
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Bundle.swift")

        XCTAssertTrue(adapter.contains("importMeetingBundleUseCase.execute"))
        XCTAssertTrue(adapter.contains("MeetingBundle.decode"))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(adapter.contains("store.save(bundle.meeting)"))
        XCTAssertFalse(adapter.contains("store.saveSummary"))
        XCTAssertFalse(adapter.contains("store.save(bundle.contextItems)"))
        XCTAssertFalse(adapter.contains("store.save(bundle.companionCards"))
    }

    func testAppMeetingBundleExportEntersThroughApplicationKit() throws {
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Bundle.swift")

        XCTAssertTrue(view.contains("services.exportMeetingBundle"))
        XCTAssertFalse(view.contains("let bundle = MeetingBundle("))
        XCTAssertFalse(view.contains("MeetingBundle.AudioAttachment"))
        XCTAssertFalse(view.contains("Data(contentsOf:"))
        XCTAssertTrue(adapter.contains("exportMeetingBundleUseCase.execute"))
        XCTAssertTrue(adapter.contains("MeetingBundle("))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(adapter.contains("store.contextItems(for:"))
        XCTAssertFalse(adapter.contains("store.companionCards(for:"))
    }

    func testMeetingVoiceMemoryEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ManageMeetingVoiceMemory.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingVoiceMemory.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")

        XCTAssertTrue(workflow.contains("struct ManageMeetingVoiceMemory"))
        XCTAssertTrue(workflow.contains("VoiceMatcher.matches("))
        XCTAssertTrue(workflow.contains("case remember(meetingID: MeetingID"))
        XCTAssertTrue(adapter.contains("ManageMeetingVoiceMemory("))
        XCTAssertTrue(adapter.contains("services.acquireDiarizationRuntime()"))
        XCTAssertTrue(adapter.contains("services.finishDiarizationRuntime("))
        XCTAssertTrue(adapter.contains("services.makeDiarizer("))
        XCTAssertTrue(adapter.contains("RecordingsLocation.shared.resolve"))
        XCTAssertTrue(adapter.contains("gallery.remember(voice)"))
        XCTAssertTrue(view.contains("model.send(.loadVoiceSuggestions)"))
        XCTAssertTrue(view.contains("model.send(.rememberVoice("))
        XCTAssertFalse(view.contains("suggestFromVoicesIfUseful"))
        XCTAssertFalse(view.contains("services.meetingDetailVoiceSuggestions("))
        XCTAssertFalse(view.contains("services.rememberMeetingDetailVoice("))
        for bypass in [
            "VoiceMatcher.matches(", "PyannoteDiarizer.loadRecommended",
            "acquireDiarizationRuntime", "ModelStore()",
            "services.voiceGallery", "extractVoiceprints(",
        ] {
            XCTAssertFalse(view.contains(bypass), bypass)
        }
        XCTAssertFalse(view.contains("import DiarizationKit"))
        XCTAssertFalse(view.contains("import ModelStoreKit"))
    }

    func testMeetingNameSuggestionsEnterThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SuggestMeetingSpeakerNames.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingNames.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")

        XCTAssertTrue(workflow.contains("struct SuggestMeetingSpeakerNames"))
        XCTAssertTrue(workflow.contains("func proposeNames("))
        XCTAssertTrue(workflow.contains("static func verified("))
        XCTAssertTrue(workflow.contains("enum MeetingNameSuggestionEvidence"))
        XCTAssertTrue(workflow.contains("struct MeetingNameProposal"))
        XCTAssertTrue(workflow.contains("PersonNameEvidenceMatcher.contains"))
        XCTAssertFalse(workflow.contains("proposal.evidence"))
        XCTAssertTrue(adapter.contains("CalendarAttendeeSource().attendees("))
        XCTAssertTrue(adapter.contains("SpeakerNamer().suggestNames("))
        XCTAssertTrue(adapter.contains("MeetingNameProposal(label:"))
        XCTAssertTrue(model.contains("case loadNameSuggestions"))
        XCTAssertTrue(model.contains("state.nameSuggestions"))
        XCTAssertTrue(view.contains("model.send(.loadNameSuggestions)"))
        XCTAssertTrue(view.contains("model.state.nameSuggestions"))
        for bypass in [
            "CalendarAttendeeSource", "SpeakerNamer", "NameSuggestionFilter",
            "@State private var nameSuggestions", "@State private var suggestingNames",
        ] {
            XCTAssertFalse(view.contains(bypass), bypass)
        }
    }

    func testMeetingReviewMetadataSuggestionsEnterThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SuggestMeetingReviewMetadata.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingReviewMetadata.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")

        XCTAssertTrue(workflow.contains("struct SuggestMeetingReviewMetadata"))
        XCTAssertTrue(workflow.contains("MeetingReviewMetadataGenerating"))
        XCTAssertTrue(workflow.contains("func suggestedRecipe("))
        XCTAssertTrue(workflow.contains("func suggestedMeetingTitle("))
        XCTAssertTrue(workflow.contains("func suggestedChapterTitles("))
        XCTAssertTrue(workflow.contains("try Task.checkCancellation()"))
        XCTAssertFalse(workflow.contains("import FoundationModels"))
        XCTAssertFalse(workflow.contains("FoundationModelSummaryProvider"))
        XCTAssertTrue(adapter.contains("foundationModelsCapability.isAvailable"))
        XCTAssertTrue(adapter.contains(#"arguments.contains("-seed-scale")"#))
        for concreteGenerator in [
            "ChapterTitler", "TitleSuggester", "MeetingTypeDetector",
        ] {
            XCTAssertTrue(adapter.contains(concreteGenerator), concreteGenerator)
            XCTAssertFalse(view.contains(concreteGenerator), concreteGenerator)
        }
        XCTAssertTrue(model.contains("case loadMetadataSuggestions"))
        XCTAssertTrue(model.contains("metadataRequestID"))
        XCTAssertTrue(model.contains("didCompleteTitleSuggestion"))
        XCTAssertTrue(model.contains("didCompleteRecipeSuggestion"))
        XCTAssertTrue(view.contains("model.send(.loadMetadataSuggestions)"))
        XCTAssertTrue(view.contains("model.state.chapterTitles"))
        XCTAssertTrue(view.contains("model.state.suggestedTitle"))
        XCTAssertTrue(view.contains("model.state.suggestedRecipe"))
        XCTAssertFalse(view.contains("ProcessInfo.processInfo"))
        XCTAssertFalse(view.contains("FoundationModelSummaryProvider"))
        XCTAssertFalse(view.contains("suggestTitleIfUseful"))
        XCTAssertFalse(view.contains("suggestRecipeIfUseful"))
        XCTAssertFalse(view.contains("titleChaptersIfNeeded"))
    }

    func testMeetingDetailAudioCoordinationEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/MeetingAudioWorkflows.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingAudio.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let playerBar = try Self.contents(
            of: "Sources/portavoz-app/MeetingPlayerBar.swift")
        let transcript = try Self.contents(
            of: "Sources/portavoz-app/TranscriptSegmentsView.swift")

        for useCase in [
            "PrepareMeetingPlayback", "CompressMeetingAudio", "ExportMeetingAudioClip",
        ] {
            XCTAssertTrue(workflow.contains("struct \(useCase)"), useCase)
            XCTAssertTrue(adapter.contains("\(useCase)("), useCase)
        }
        XCTAssertTrue(workflow.contains("MeetingAudioChannelResolving"))
        XCTAssertTrue(workflow.contains("Waveform.generateCancellable"))
        XCTAssertFalse(workflow.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(workflow.contains("PlaybackRanges.complement"))
        XCTAssertTrue(adapter.contains("RecordingsLocation.shared"))
        XCTAssertTrue(adapter.contains("MeetingAudioLayout.channelFile"))
        XCTAssertTrue(model.contains("case loadPlayback"))
        XCTAssertTrue(model.contains("case compressAudio"))
        XCTAssertTrue(model.contains("case exportAudioClip"))
        XCTAssertTrue(view.contains(".task(id: playbackTaskID)"))
        XCTAssertTrue(view.contains("model.send(.loadPlayback)"))
        XCTAssertTrue(view.contains("model.send(.compressAudio)"))
        XCTAssertTrue(playerBar.contains("await exportClip(range, url)"))

        let presentationSources = [view, playerBar, transcript]
        for source in presentationSources {
            XCTAssertFalse(source.contains("import AudioPlaybackKit"))
        }
        for bypass in [
            "RecordingsLocation", "MeetingAudioLayout", "MeetingPlayer.make",
            "Waveform.generate", "AudioTranscoder", "AudioClipExporter",
            "PlaybackRanges.complement",
        ] {
            XCTAssertFalse(view.contains(bypass), bypass)
            XCTAssertFalse(playerBar.contains(bypass), bypass)
        }
    }

    func testLibraryFeatureOwnsStateAndActionsOutsideSwiftUI() throws {
        let model = try Self.contents(
            of: "Sources/portavoz-app/LibraryModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/LibraryView.swift")
        let trash = try Self.contents(
            of: "Sources/portavoz-app/TrashSection.swift")
        let content = try Self.contents(
            of: "Sources/portavoz-app/ContentView.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Library.swift")
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/LibraryReadModels.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryObservation.swift")

        XCTAssertTrue(model.contains("@MainActor\n@Observable\nfinal class LibraryModel"))
        XCTAssertTrue(model.contains("struct State"))
        XCTAssertTrue(model.contains("enum Action"))
        XCTAssertTrue(model.contains("enum Effect"))
        XCTAssertTrue(model.contains("private(set) var state = State()"))
        XCTAssertTrue(view.contains("model.send(.observeLibrary)"))
        XCTAssertTrue(view.contains("model.send(.observeSearch)"))
        XCTAssertTrue(content.contains("@State private var libraryModel: LibraryModel"))
        XCTAssertTrue(adapter.contains("defer { requestSearchReconciliation() }"))
        XCTAssertTrue(adapter.contains("makeApplicationLibraryStream("))
        XCTAssertTrue(readModels.contains("public enum LibraryUpdate"))
        XCTAssertTrue(observation.contains("func observeLibraryMeetings()"))
        XCTAssertTrue(observation.contains("func observeLibraryOpenItems("))
        XCTAssertTrue(observation.contains("func observeLibraryTrash()"))
        XCTAssertTrue(observation.contains(
            "regions: [Table(\"meeting\"), Table(\"speaker\"), Table(\"segment\")]"))
        XCTAssertTrue(observation.contains(
            "regions: [Table(\"meeting\"), Table(\"summary\"), Table(\"actionItem\")]"))
        XCTAssertTrue(observation.contains("region: Table(\"meeting\")"))
        XCTAssertTrue(observation.contains("regions: [Table(\"meeting\"), Table(\"segment\")]"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("services.meetingLifecycle"))
        XCTAssertFalse(view.contains("services.libraryVersion +="))
        XCTAssertFalse(view.contains("invalidationVersion"))
        XCTAssertFalse(view.contains("@State private var meetings"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(view.contains("import StorageKit"))
        XCTAssertFalse(trash.contains("import StorageKit"))
        XCTAssertFalse(model.contains("reloadVersion"))
        XCTAssertFalse(model.contains("newestReloadVersion"))
        XCTAssertFalse(content.contains("invalidationVersion: services.libraryVersion"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertFalse(trash.contains("@Environment(AppServices.self)"))
        XCTAssertFalse(trash.contains("services."))
    }

    func testResidentMenuBarUsesOneScopedReadOwner() throws {
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/MenuBarReadModels.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MenuBarModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+MenuBar.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MenuBarView.swift")
        let app = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MenuBarObservation.swift")

        XCTAssertTrue(readModels.contains("public enum MenuBarUpdate"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("private(set) var state = State()"))
        XCTAssertTrue(model.contains("failedSections"))
        XCTAssertTrue(adapter.contains("store.observeMenuBarMeetings(limit: 3)"))
        XCTAssertTrue(adapter.contains("store.observeLibraryOpenItems(limit: 200)"))
        XCTAssertTrue(view.contains("@State private var model: MenuBarModel"))
        XCTAssertTrue(view.contains(".task { await model.observe() }"))
        XCTAssertTrue(app.contains("MenuBarContent(model: services.makeMenuBarModel())"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("CalendarAttendeeSource"))
        XCTAssertFalse(view.contains("import StorageKit"))
        XCTAssertFalse(view.contains("import IntegrationsKit"))
        XCTAssertTrue(storage.contains("region: Table(\"meeting\")"))
        XCTAssertTrue(storage.contains(".limit(max(0, limit))"))
        XCTAssertFalse(storage.contains("Table(\"segment\")"))
        XCTAssertFalse(storage.contains("Table(\"speaker\")"))
    }

    func testWholeLibraryMarkdownBackupUsesOneApplicationWorkflow() throws {
        let useCase = try Self.contents(
            of: "Sources/ApplicationKit/ExportLibraryMarkdownBackup.swift")
        let execution = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupExecution.swift")
        let recoveryUseCase = try Self.contents(
            of: "Sources/ApplicationKit/RecoverLibraryMarkdownBackup.swift")
        let recoveryValidation = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupRecoveryValidation.swift")
        let filesContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupFiles.swift")
        let sourceContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupSource.swift")
        let recoveryContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupRecovery.swift")
        let reconciliation = try Self.contents(
            of: "Sources/ApplicationKit/ReconcileBackupPublication.swift")
        let destinationContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupDestination.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryMarkdownBackup.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LibraryMarkdownBackup.swift")
        let recoveryAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppLibraryMarkdownBackupRecoveryStore.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/LibraryMarkdownBackupModel.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/BackupSection.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let app = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")
        let resourceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let bookmark = try Self.contents(
            of: "Sources/PlatformKit/PersistentFileBookmark.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")

        XCTAssertTrue(useCase.contains("actor ExportLibraryMarkdownBackup"))
        XCTAssertTrue(filesContract.contains(
            "protocol LibraryMarkdownBackupDocuments"))
        XCTAssertTrue(filesContract.contains(
            "protocol LibraryMarkdownBackupFiles"))
        XCTAssertTrue(filesContract.contains("func evidence("))
        XCTAssertTrue(sourceContract.contains(
            "protocol LibraryMarkdownBackupSourceSession"))
        XCTAssertTrue(sourceContract.contains(
            "extension MeetingStore: LibraryMarkdownBackupStore"))
        XCTAssertTrue(execution.contains("LibraryMarkdownBackupFailureStage"))
        XCTAssertTrue(recoveryUseCase.contains(
            "actor RecoverLibraryMarkdownBackup"))
        XCTAssertTrue(recoveryUseCase.contains(
            "struct RecoverLibraryMarkdownBackupRequest"))
        XCTAssertTrue(recoveryValidation.contains(
            "enum LibraryMarkdownBackupRecoveryValidation"))
        XCTAssertTrue(destinationContract.contains(
            "protocol LibraryMarkdownBackupDestinationAccess"))
        XCTAssertTrue(recoveryContract.contains(
            "protocol LibraryMarkdownBackupRecoveryStore"))
        XCTAssertTrue(recoveryContract.contains("func operationIDs()"))
        XCTAssertTrue(recoveryContract.contains("pendingPublication"))
        XCTAssertTrue(recoveryContract.contains("completedPublications"))
        XCTAssertTrue(recoveryContract.contains(
            "LibraryMarkdownBackupRecoveryFailure"))
        XCTAssertTrue(recoveryContract.contains(
            "case recordFailure(LibraryMarkdownBackupRecoveryFailure)"))
        XCTAssertTrue(recoveryContract.contains(
            "LibraryMarkdownBackupSourceCursor"))
        XCTAssertTrue(recoveryContract.contains(
            "case checkpointSource(LibraryMarkdownBackupSourceCursor)"))
        XCTAssertTrue(recoveryContract.contains(
            "sourceCursor: LibraryMarkdownBackupSourceCursor?"))
        XCTAssertTrue(reconciliation.contains(
            "struct ReconcileBackupPublication: ApplicationUseCase"))
        XCTAssertTrue(reconciliation.contains("files.evidence("))
        XCTAssertTrue(reconciliation.contains(".clearReservation"))
        XCTAssertTrue(reconciliation.contains(".complete(pending)"))
        XCTAssertTrue(reconciliation.contains("repairCheckpointIfNeeded"))
        XCTAssertTrue(sourceContract.contains(
            "func checkpoint() async throws"))
        XCTAssertTrue(sourceContract.contains(
            "protocol LibraryMarkdownBackupRecoverySourceStore"))
        XCTAssertTrue(sourceContract.contains(
            "func adoptLibraryMarkdownBackupSource("))
        XCTAssertTrue(sourceContract.contains(
            "preserving operationIDs: Set<UUID>"))
        XCTAssertTrue(sourceContract.contains("func abandon() async"))
        XCTAssertTrue(useCase.contains(
            "pendingRecoveryCheckpoint"))
        XCTAssertTrue(useCase.contains(
            ".checkpointSource(cursor)"))
        XCTAssertTrue(useCase.contains(".recordFailure(recoveryFailure)"))
        XCTAssertTrue(useCase.contains("try await recoveryStore.apply("))
        XCTAssertTrue(useCase.contains("destinationLease.close()"))
        XCTAssertTrue(useCase.contains("maintenanceGate.disposition"))
        XCTAssertTrue(useCase.contains("workloadClass: .maintenance"))
        XCTAssertTrue(useCase.contains("kind: .mediaExport"))
        XCTAssertTrue(useCase.contains("shouldProceed(at: .admission)"))
        XCTAssertTrue(useCase.contains("shouldProceed(at: .checkpoint)"))
        XCTAssertTrue(useCase.contains("private var activeRun"))
        XCTAssertTrue(useCase.contains("restoreRecoveredRun("))
        XCTAssertTrue(useCase.contains("await source.abandon()"))
        XCTAssertTrue(useCase.contains("existingMarkdownFileNames"))
        XCTAssertTrue(useCase.contains("case .nameCollision:"))
        XCTAssertTrue(storage.contains("database.backup("))
        XCTAssertTrue(storage.contains("pagesPerStep: pagesPerStep"))
        XCTAssertTrue(storage.contains("database.read"))
        XCTAssertTrue(storage.contains(
            "private var cursor: MeetingMarkdownBackupStageCursor?"))
        XCTAssertTrue(storage.contains(
            "Column(\"startedAt\") < currentCursor.startedAt"))
        XCTAssertTrue(storage.contains(
            "Column(\"id\") > currentCursor.recordID"))
        XCTAssertTrue(storage.contains(
            "adoptLibraryMarkdownBackupStage("))
        XCTAssertTrue(storage.contains("configuration.readonly = true"))
        XCTAssertTrue(storage.contains(
            "try validateLibraryMarkdownBackupRegularFile("))
        XCTAssertTrue(storage.contains(
            "MeetingMarkdownBackupStageError.invalidCursor"))
        XCTAssertTrue(storage.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(storage.contains("values.isExcludedFromBackup = true"))
        XCTAssertTrue(storage.contains(".workspace-coordinator.lock"))
        XCTAssertTrue(storage.contains(".owner.lock"))
        XCTAssertTrue(storage.contains("portavoBSDFileLock"))
        XCTAssertTrue(storage.contains("O_NOFOLLOW"))
        XCTAssertTrue(storage.contains(
            "UUID(uuidString: workspace.lastPathComponent)"))
        XCTAssertTrue(storage.contains(
            "stageID.uuidString.lowercased() == workspace.lastPathComponent"))
        XCTAssertTrue(storage.contains(
            "cleanupAbandonedLibraryMarkdownBackupStages"))
        XCTAssertTrue(storage.contains("removesWorkspaceOnDeinit"))
        XCTAssertTrue(storage.contains("public func abandon()"))
        XCTAssertTrue(storage.contains(
            "preserving operationIDs: Set<UUID> = []"))
        XCTAssertTrue(storage.contains("generalSummarySnapshot"))
        XCTAssertTrue(adapter.contains("MeetingExporter.markdown"))
        XCTAssertTrue(adapter.contains("AppBackupDestinationAccess"))
        XCTAssertTrue(adapter.contains("PersistentFileBookmark().resolve"))
        XCTAssertTrue(adapter.contains(
            "AppLibraryMarkdownBackupRecoveryStore"))
        XCTAssertTrue(adapter.contains("RecoverLibraryMarkdownBackup("))
        XCTAssertTrue(adapter.contains("ReconcileBackupPublication("))
        XCTAssertTrue(adapter.contains("moveItem(at: temporary, to: destination)"))
        XCTAssertTrue(adapter.contains("Darwin.openat("))
        XCTAssertTrue(adapter.contains("O_NOFOLLOW"))
        XCTAssertTrue(adapter.contains("O_NONBLOCK"))
        XCTAssertTrue(adapter.contains("Darwin.fstat("))
        XCTAssertTrue(adapter.contains("var hasher = SHA256()"))
        XCTAssertFalse(adapter.contains("[.atomic, .withoutOverwriting]"))
        XCTAssertTrue(bookmark.contains(".withoutImplicitSecurityScope"))
        XCTAssertFalse(bookmark.contains("startAccessingSecurityScopedResource"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("private var pendingDirectory: URL?"))
        XCTAssertTrue(model.contains("func recoverAtLaunch()"))
        XCTAssertTrue(model.contains("recoverLibraryMarkdownBackup"))
        XCTAssertTrue(model.contains("hasPendingLaunchRecovery"))
        XCTAssertTrue(model.contains("func maintenanceMayResume()"))
        XCTAssertTrue(services.contains("let libraryMarkdownBackup: LibraryMarkdownBackupModel"))
        XCTAssertTrue(adapter.contains("cleanupOnLaunch: !usesTemporaryStore"))
        XCTAssertTrue(app.contains(
            "libraryMarkdownBackup.recoverAtLaunch()"))
        XCTAssertTrue(resourceAdapter.contains(
            "libraryMarkdownBackup.maintenanceMayResume()"))
        XCTAssertTrue(recoveryAdapter.contains(
            "private static let metadataFormatVersion = 2"))
        XCTAssertTrue(recoveryAdapter.contains(
            "private static let recordFormatVersion = 1"))
        XCTAssertTrue(recoveryAdapter.contains("options: .atomic"))
        XCTAssertTrue(recoveryAdapter.contains(
            "fileManager.moveItem("))
        XCTAssertTrue(recoveryAdapter.contains(
            "nextSequenceByOperation"))
        XCTAssertTrue(recoveryAdapter.contains(
            "nextFailureSequenceByOperation"))
        XCTAssertTrue(recoveryAdapter.contains(
            "guard cursor == current || Self.isAfter(cursor, current)"))
        XCTAssertTrue(recoveryAdapter.contains(
            "guard try !itemExists(pendingURL(operationID: operationID))"))
        XCTAssertTrue(recoveryAdapter.contains("func operationIDs()"))
        XCTAssertTrue(recoveryAdapter.contains(
            "operationID.uuidString.lowercased() == name"))
        XCTAssertTrue(recoveryAdapter.contains(
            "== publication.meetingID.rawValue.uuidString"))
        XCTAssertTrue(recoveryAdapter.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(recoveryAdapter.contains(
            "values.isExcludedFromBackup = true"))
        XCTAssertTrue(view.contains("services.libraryMarkdownBackup"))
        XCTAssertTrue(view.contains("NSOpenPanel"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("MeetingExporter"))
        XCTAssertFalse(view.contains("Data(markdown"))
        XCTAssertFalse(view.contains("import IntegrationsKit"))
        XCTAssertFalse(view.contains("import StorageKit"))
        XCTAssertTrue(architecture.contains(
            "bounded pending-publication reconciliation operation"))
        XCTAssertTrue(decisions.contains("## D187"))
        XCTAssertTrue(decisions.contains("## D188"))
        XCTAssertTrue(decisions.contains("## D189"))
        XCTAssertTrue(appSpec.contains(
            "### Capture-safe staged whole-library backup (D180–D189)"))
    }

    func testAskSurfacesUseOneStorageIndependentApplicationWorkflow() throws {
        let workflow = try Self.contents(of: "Sources/ApplicationKit/AskMeetings.swift")
        let retrieval = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let indexer = try Self.contents(
            of: "Sources/ApplicationKit/IndexSemanticCorpus.swift")
        let maintenanceGate = try Self.contents(
            of: "Sources/PortavozCore/DurableMaintenanceGate.swift")
        let librarySearch = try Self.contents(
            of: "Sources/ApplicationKit/LocalLibrarySemanticSearch.swift")
        let appAdapter = try Self.contents(of: "Sources/portavoz-app/AppServices+Ask.swift")
        let resourceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let askModel = try Self.contents(of: "Sources/portavoz-app/AskModel.swift")
        let paletteModel = try Self.contents(
            of: "Sources/portavoz-app/CommandPaletteModel.swift")
        let askView = try Self.contents(of: "Sources/portavoz-app/AskView.swift")
        let palette = try Self.contents(of: "Sources/portavoz-app/CommandPalette.swift")
        let cli = try Self.contents(of: "Sources/portavoz-cli/CLIAsk.swift")
        let mcp = try Self.contents(of: "Sources/portavoz-cli/CLIMcp.swift")
        let brief = try Self.contents(of: "Sources/ApplicationKit/PrepareMeetingBrief.swift")
        let briefView = try Self.contents(
            of: "Sources/portavoz-app/MeetingBriefView.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")

        XCTAssertTrue(workflow.contains("struct AskMeetings: ApplicationUseCase"))
        XCTAssertTrue(workflow.contains("struct AskSearchResult"))
        XCTAssertTrue(workflow.contains("struct AskCitation"))
        XCTAssertTrue(workflow.contains("struct AskMeetingAnswer"))
        XCTAssertTrue(retrieval.contains("struct LocalAskMeetingRetrieval"))
        XCTAssertTrue(indexer.contains("struct IndexSemanticCorpus"))
        XCTAssertTrue(indexer.contains("workloadClass: .maintenance"))
        XCTAssertTrue(indexer.contains("kind: .searchIndex"))
        XCTAssertTrue(indexer.contains("guard shouldProceed(at: .admission)"))
        XCTAssertTrue(indexer.contains("shouldProceed(at: .checkpoint)"))
        XCTAssertTrue(indexer.contains("pausedByPolicy"))
        XCTAssertTrue(maintenanceGate.contains(
            "public struct DurableMaintenanceGate: Sendable"))
        XCTAssertTrue(maintenanceGate.contains(
            "ResourceGovernorEvaluationPhase"))
        XCTAssertTrue(resourceAdapter.contains(
            "enum AppResourceGovernorMaintenanceGate"))
        XCTAssertTrue(resourceAdapter.contains(
            "ResourceGovernorPolicy().evaluate("))
        XCTAssertTrue(appAdapter.contains(
            "captureState: AppResourceCaptureState"))
        XCTAssertTrue(appAdapter.contains(
            "maintenanceGate: maintenanceGate"))
        XCTAssertFalse(retrieval.contains("indexingCoordinator"))
        XCTAssertFalse(retrieval.contains("IndexSemanticCorpus"))
        XCTAssertTrue(retrieval.contains("allowAssetDownload: false"))
        XCTAssertFalse(librarySearch.contains("indexingCoordinator"))
        XCTAssertFalse(librarySearch.contains("IndexSemanticCorpus"))
        XCTAssertTrue(librarySearch.contains("allowAssetDownload: false"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/IntegrationsKit/AskPipeline.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/IntegrationsKit/AskMarkdown.swift").path))
        XCTAssertTrue(appAdapter.contains("AskMeetings"))
        XCTAssertTrue(askModel.contains("@Observable"))
        XCTAssertTrue(paletteModel.contains("@Observable"))
        XCTAssertTrue(paletteModel.contains("searchTask?.cancel()"))
        XCTAssertTrue(paletteModel.contains("answerTask?.cancel()"))
        XCTAssertTrue(paletteModel.contains("generation == requestGeneration"))
        for source in [askView, palette] {
            XCTAssertFalse(source.contains("services.store"))
            XCTAssertFalse(source.contains("AskPipeline"))
            XCTAssertFalse(source.contains("RAGAnswerer"))
            XCTAssertFalse(source.contains("import IntegrationsKit"))
            XCTAssertFalse(source.contains("import IntelligenceKit"))
            XCTAssertFalse(source.contains("import StorageKit"))
        }
        XCTAssertTrue(cli.contains("application.ask.answer"))
        XCTAssertTrue(mcp.contains("ask.answer"))
        XCTAssertTrue(cli.contains("CLIComposition.open"))
        XCTAssertTrue(mcp.contains("library: application.library"))
        XCTAssertTrue(brief.contains("ask.evidence(query, limit: 12)"))
        XCTAssertFalse(briefView.contains("AskMeetings.local"))
        XCTAssertTrue(askView.contains("onOpenCitation(citation)"))
        XCTAssertTrue(palette.contains("onOpenCitation?(citation)"))
        XCTAssertTrue(architecture.contains(
            "PortavozCore owns one reusable `DurableMaintenanceGate`"))
        XCTAssertTrue(decisions.contains(
            "## D177 — Pause semantic maintenance"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Capture-prioritized semantic checkpoints (D177)"))
        XCTAssertTrue(appSpec.contains(
            "### Capture-prioritized semantic maintenance (D177)"))
    }

    func testFirstRunLedgerAndBriefStayBehindApplicationOwners() throws {
        let firstRun = try Self.contents(
            of: "Sources/ApplicationKit/FirstRunExperience.swift")
        let firstRunPolicy = try Self.contents(
            of: "Sources/ApplicationKit/FirstRunOnboarding.swift")
        let ledger = try Self.contents(
            of: "Sources/ApplicationKit/LocalDataLedger.swift")
        let brief = try Self.contents(
            of: "Sources/ApplicationKit/PrepareMeetingBrief.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let onboarding = try Self.contents(of: "Sources/portavoz-app/OnboardingView.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsCategories.swift")
        let briefView = try Self.contents(
            of: "Sources/portavoz-app/MeetingBriefView.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let firstRunAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+FirstRun.swift")
        let ledgerAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalDataLedger.swift")
        let briefAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingBrief.swift")

        XCTAssertTrue(firstRun.contains("struct ResolveFirstRunExperience: ApplicationUseCase"))
        XCTAssertTrue(firstRunPolicy.contains("enum FirstRunOnboardingPolicy"))
        XCTAssertTrue(ledger.contains("struct LoadLocalDataLedger: ApplicationUseCase"))
        XCTAssertTrue(brief.contains("struct PrepareMeetingBrief: ApplicationUseCase"))
        for contract in [firstRun, firstRunPolicy, ledger, brief] {
            XCTAssertFalse(contract.contains("import StorageKit"))
            XCTAssertFalse(contract.contains("import GRDB"))
        }
        XCTAssertTrue(services.contains("let firstRun: FirstRunModel"))
        XCTAssertTrue(services.contains("let localDataLedger: LocalDataLedgerModel"))
        XCTAssertTrue(services.contains("let meetingBriefUseCase: PrepareMeetingBrief"))
        XCTAssertTrue(firstRunAdapter.contains("store.liveMeetingCount()"))
        XCTAssertTrue(ledgerAdapter.contains("store.liveMeetingCount()"))
        XCTAssertTrue(briefAdapter.contains("AppMeetingBriefLibraryReader"))
        XCTAssertTrue(briefAdapter.contains("AppOnDeviceMeetingBriefSynthesizer"))
        XCTAssertFalse(content.contains("services.store"))
        XCTAssertFalse(content.contains("UserDefaults"))
        XCTAssertFalse(content.contains("decideOnboarding"))
        XCTAssertFalse(onboarding.contains("UserDefaults"))
        XCTAssertFalse(settings.contains("services.store"))
        XCTAssertFalse(settings.contains("directorySize"))
        XCTAssertFalse(settings.contains("VoiceGallery"))
        XCTAssertFalse(settings.contains("RecordingsLocation"))
        XCTAssertFalse(settings.contains("import AudioCaptureKit"))
        XCTAssertFalse(settings.contains("import DiarizationKit"))
        XCTAssertFalse(settings.contains("import StorageKit"))
        XCTAssertFalse(briefView.contains("MeetingStore"))
        XCTAssertFalse(briefView.contains("AskMeetings"))
        XCTAssertFalse(briefView.contains("BriefSynthesizer"))
        XCTAssertFalse(briefView.contains("import IntelligenceKit"))
        XCTAssertFalse(briefView.contains("import StorageKit"))
    }

    func testArchitectureDocumentUsesOnlyDurableTechnicalVocabulary() throws {
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let forbidden = try NSRegularExpression(
            pattern: #"(?i)\b(band|slice|ticket|phase)\b|\b[DM][0-9]+\b|target architecture|next program|\bplanned\b"#)
        let range = NSRange(architecture.startIndex..., in: architecture)
        XCTAssertNil(
            forbidden.firstMatch(in: architecture, range: range),
            "ARCHITECTURE.md must describe only durable as-built technical facts")
    }

    func testArchitectureDecisionIdentifiersAreUnique() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let identifiers = decisions.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("## D") else { return nil }
            let digits = line.dropFirst(4).prefix(while: \.isNumber)
            return digits.isEmpty ? nil : "D\(digits)"
        }
        let duplicates = Dictionary(grouping: identifiers, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()

        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertTrue(
            duplicates.isEmpty,
            "Architecture decision identifiers must be unique: \(duplicates)")
    }

    func testMeetingReviewPoliciesStayInsideApplicationKit() throws {
        let policies = [
            "ChapterExtractor", "PlaybackRanges", "SummarySections", "VoiceHue",
        ]
        for policy in policies {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/ApplicationKit/\(policy).swift").path),
                "\(policy) must remain an inward ApplicationKit policy")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/IntegrationsKit/\(policy).swift").path),
                "\(policy) must not return to the outbound integration layer")
        }

        for consumer in [
            "InsightsView.swift", "MeetingDetailView.swift", "PVDesign.swift", "RecordingView.swift",
        ] {
            XCTAssertTrue(
                try Self.contents(of: "Sources/portavoz-app/\(consumer)")
                    .contains("import ApplicationKit"),
                "\(consumer) must consume meeting-review policy through ApplicationKit")
        }
    }

    func testInsightsReadPoliciesStayInsideApplicationKit() throws {
        let policies = [
            "InsightsScope", "LibraryStats", "InsightsFindings",
        ]
        for policy in policies {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/ApplicationKit/\(policy).swift").path),
                "\(policy) must remain an inward ApplicationKit policy")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/IntegrationsKit/\(policy).swift").path),
                "\(policy) must not return to the outbound integration layer")
        }

        let insights = try Self.contents(of: "Sources/portavoz-app/InsightsView.swift")
        XCTAssertTrue(insights.contains("import ApplicationKit"))
        XCTAssertFalse(
            insights.contains("import IntegrationsKit"),
            "InsightsView must not regain a broad outbound dependency for local read policy")
    }

    func testInsightsUsesOneScopedReadModelWithoutGlobalInvalidation() throws {
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/InsightsReadModels.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/InsightsModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+Insights.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/InsightsView.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+InsightsObservation.swift")

        XCTAssertTrue(readModels.contains("struct InsightsReadModel"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("InsightsReadModel.compute"))
        XCTAssertTrue(adapter.contains("store.observeInsightsMeetings()"))
        XCTAssertTrue(adapter.contains("store.observeInsightsFacts()"))
        XCTAssertTrue(adapter.contains("store.observeInsightsVoiceBalance()"))
        XCTAssertTrue(adapter.contains("store.observeInsightsFindingInputs"))
        XCTAssertTrue(content.contains("@State private var insightsModel: InsightsModel"))
        XCTAssertTrue(view.contains("let model: InsightsModel"))
        XCTAssertFalse(view.contains("libraryVersion"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("import StorageKit"))
        for table in ["meeting", "speaker", "segment", "summary", "actionItem"] {
            XCTAssertTrue(storage.contains("Table(\"\(table)\")"))
        }
    }

    func testMeetingPreparationPoliciesStayInsideInwardLayers() throws {
        for policy in ["BriefRelevance", "ReminderPolicy", "MirrorStats"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/ApplicationKit/\(policy).swift").path),
                "\(policy) must remain an inward ApplicationKit policy")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/IntegrationsKit/\(policy).swift").path),
                "\(policy) must not return to the outbound integration layer")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/PortavozCore/UpcomingEvent.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/ApplicationKit/UpcomingEvent.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/IntegrationsKit/UpcomingEvent.swift").path))

        let calendar = try Self.contents(
            of: "Sources/IntegrationsKit/CalendarAttendeeSource.swift")
        XCTAssertTrue(calendar.contains("import EventKit"))
        XCTAssertTrue(calendar.contains("import PortavozCore"))
        XCTAssertFalse(calendar.contains("struct UpcomingEvent"))

        for consumer in ["MeetingBriefView.swift", "MeetingReminder.swift", "MirrorCard.swift"] {
            XCTAssertTrue(
                try Self.contents(of: "Sources/portavoz-app/\(consumer)")
                    .contains("import ApplicationKit"),
                "\(consumer) must consume product policy through ApplicationKit")
        }

        for eventOnlyConsumer in [
            "ContentView.swift", "LibraryModel.swift", "LibraryView.swift", "RecordingView.swift",
        ] {
            XCTAssertFalse(
                try Self.contents(of: "Sources/portavoz-app/\(eventOnlyConsumer)")
                    .contains("import IntegrationsKit"),
                "\(eventOnlyConsumer) must not depend on the EventKit adapter for a Core value")
        }
    }

    func testMeetingReminderEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/MeetingReminderWorkflow.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingReminder.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/MeetingReminder.swift")

        XCTAssertTrue(workflow.contains("protocol UpcomingMeetingListing"))
        XCTAssertTrue(workflow.contains("struct ResolveMeetingReminder"))
        XCTAssertFalse(workflow.contains("import EventKit"))
        XCTAssertFalse(workflow.contains("CalendarAttendeeSource"))
        XCTAssertTrue(adapter.contains("CalendarAttendeeSource().upcomingEvents()"))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(controller.contains("services?.nextMeetingReminder"))
        for bypass in [
            "import IntegrationsKit",
            "CalendarAttendeeSource",
            "ReminderPolicy.dueEvent",
            "UserDefaults.standard",
            "Date()",
            "timeIntervalSinceNow",
        ] {
            XCTAssertFalse(controller.contains(bypass), bypass)
        }
    }

    func testMeetingDetailUsesScopedReadModelWithoutGlobalReload() throws {
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/MeetingDetailReadModels.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let voiceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingVoiceMemory.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingDetailObservation.swift")

        XCTAssertTrue(readModels.contains("struct MeetingReviewReadModel"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("MeetingReviewReadModel("))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewCore"))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewSummary"))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewCompanionCards"))
        XCTAssertTrue(view.contains("@State private var model: MeetingDetailModel"))
        XCTAssertTrue(view.contains(".task { await model.observe() }"))
        XCTAssertFalse(view.contains("ReloadID"))
        XCTAssertFalse(view.contains("services.store.detail"))
        XCTAssertFalse(view.contains("services.store.mostRecentSummary"))
        XCTAssertFalse(view.contains("services.store.companionCards(for:"))
        XCTAssertFalse(view.contains("libraryVersion: services.libraryVersion"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("services.libraryVersion"))
        XCTAssertFalse(view.contains("services.meetingLifecycle"))
        XCTAssertTrue(voiceAdapter.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(voiceAdapter.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(model.contains("enum Action"))
        XCTAssertTrue(model.contains("case renameMeeting"))
        XCTAssertTrue(model.contains("case renameSpeaker"))
        XCTAssertTrue(model.contains("case findCanonicalPeople"))
        XCTAssertTrue(model.contains("case linkCanonicalPerson"))
        XCTAssertTrue(model.contains("case setActionItem"))
        XCTAssertTrue(model.contains("case removeCompanionCard"))
        XCTAssertTrue(model.contains("case deleteMeeting"))
        XCTAssertTrue(model.contains("case prepareDocument"))
        XCTAssertTrue(model.contains("case publishGist"))
        XCTAssertTrue(model.contains("case loadVoiceSuggestions"))
        XCTAssertTrue(model.contains("case rememberVoice"))
        XCTAssertFalse(model.contains("Unexpected Meeting Detail"))
        XCTAssertTrue(adapter.contains("renameMeetingDetailMeeting"))
        XCTAssertTrue(adapter.contains("renameMeetingDetailSpeaker"))
        XCTAssertTrue(adapter.contains("FindCanonicalPeople(store: store)"))
        XCTAssertTrue(adapter.contains("LinkObservedSpeaker(store: store)"))
        XCTAssertTrue(adapter.contains("setMeetingDetailActionItem"))
        XCTAssertTrue(adapter.contains("deleteMeetingDetailCompanionCard"))
        XCTAssertTrue(adapter.contains("deleteMeetingDetail"))
        XCTAssertTrue(adapter.contains("requestMeetingDetailSearchReindex"))
        XCTAssertTrue(storage.contains(
            "regions: [Table(\"meeting\"), Table(\"speaker\"), Table(\"segment\")]"))
        XCTAssertTrue(storage.contains("Table(\"summaryClaim\")"))
        XCTAssertTrue(storage.contains("Table(\"summaryClaimSegment\")"))
        XCTAssertTrue(storage.contains("Table(\"companionCard\")"))
        XCTAssertTrue(storage.contains("Table(\"companionCardEvidence\")"))
        XCTAssertTrue(storage.contains("Table(\"companionCardEvidenceSegment\")"))
    }

    func testCanonicalPeopleRequireConfirmationAndStayOutOfAutomaticEvidencePaths() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/PersonIdentity.swift")
        let application = try Self.contents(of: "Sources/ApplicationKit/CanonicalPeople.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+People.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let calendar = try Self.contents(
            of: "Sources/IntegrationsKit/CalendarAttendeeSource.swift")
        let gallery = try Self.contents(of: "Sources/DiarizationKit/VoiceGallery.swift")

        XCTAssertTrue(core.contains("enum PersonAliasNormalizer"))
        XCTAssertTrue(core.contains("never authority to merge people"))
        XCTAssertTrue(application.contains("func people(matchingAlias"))
        XCTAssertTrue(application.contains("case createDistinct"))
        XCTAssertTrue(application.contains("case existing(PersonID)"))
        XCTAssertTrue(storage.contains("Duplicate aliases across people are deliberate"))
        XCTAssertTrue(storage.contains("guard !speaker.isMe"))
        XCTAssertTrue(schema.contains("registerMigration(\"v8\")"))
        XCTAssertTrue(schema.contains("registerMigration(\"v9\")"))
        XCTAssertTrue(schema.contains("t.add(column: \"personID\", .text)"))
        XCTAssertTrue(bundle.contains("personID: nil"))
        XCTAssertFalse(calendar.contains("linkSpeaker("))
        XCTAssertFalse(calendar.contains("createPersonAndLink("))
        XCTAssertFalse(gallery.contains("linkSpeaker("))
        XCTAssertFalse(gallery.contains("createPersonAndLink("))
    }

    func testSummaryEvidenceStaysTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
            + Self.contents(of: "Sources/StorageKit/Schema+SummaryClaim.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+Summaries.swift")
            + Self.contents(of: "Sources/StorageKit/MeetingStore+SummaryDecisionEvidence.swift")
        let formatter = try Self.contents(of: "Sources/IntelligenceKit/TranscriptFormatter.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")

        XCTAssertTrue(core.contains("enum SummaryClaimKind"))
        XCTAssertTrue(core.contains("currentTranscriptRevision"))
        XCTAssertTrue(core.contains("case stale"))
        XCTAssertTrue(core.contains("case unavailable"))
        XCTAssertTrue(schema.contains("registerMigration(\"v9\")"))
        XCTAssertTrue(schema.contains("table: \"summaryClaim\""))
        XCTAssertTrue(schema.contains("table: \"summaryClaimSegment\""))
        XCTAssertTrue(storage.contains("evidence must reference a live segment"))
        XCTAssertTrue(storage.contains("meeting.transcriptRevision"))
        XCTAssertTrue(formatter.contains("formatWithEvidence"))
        XCTAssertTrue(formatter.contains("resolveEvidenceTags"))
        XCTAssertTrue(provider.contains("overviewEvidence"))
        XCTAssertTrue(bundle.contains("segmentMap"))
        XCTAssertTrue(bundle.contains("sourceTranscriptRevision: nil"))
        XCTAssertTrue(detail.contains("summary-evidence-stale"))
        XCTAssertTrue(detail.contains("focusEvidence(segment)"))
    }

    func testClaimFeedbackStaysSeparatePrivateAndExplicitlyPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SummaryClaimFeedback.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SummaryClaimFeedback.swift")
        let summaries = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Summaries.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("enum SummaryClaimFeedbackKind"))
        XCTAssertTrue(core.contains("maximumCorrectionLength = 2_000"))
        XCTAssertTrue(schema.contains("table: \"summaryClaimFeedback\""))
        XCTAssertTrue(schema.contains("deletedAt IS NOT NULL AND correctionText IS NULL"))
        XCTAssertTrue(storage.contains("ORDER BY createdAt DESC, rowid DESC"))
        XCTAssertTrue(storage.contains("current.correctionText = nil"))
        XCTAssertTrue(summaries.contains("generated summaries cannot write user feedback"))
        XCTAssertTrue(bundle.contains("feedback: claim.feedback"))
        XCTAssertTrue(model.contains("case setSummaryClaimFeedback"))
        XCTAssertFalse(diagnostics.contains("SummaryClaimFeedback"))
        XCTAssertTrue(try Self.sourceMatches(
            under: "Sources/IntelligenceKit",
            pattern: #"SummaryClaimFeedback"#).isEmpty)
    }

    func testDecisionEvidenceStaysPositionTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let outline = try Self.contents(
            of: "Sources/PortavozCore/SummaryMarkdownOutline.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SummaryDecisionEvidence.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SummaryDecisionEvidence.swift")
        let structured = try Self.contents(
            of: "Sources/IntelligenceKit/StructuredSummary.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let translation = try Self.contents(
            of: "Sources/IntelligenceKit/FoundationModelSummaryProvider.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("struct SummaryDecisionEvidence"))
        XCTAssertTrue(core.contains("decisionSectionIndexes"))
        XCTAssertTrue(outline.contains("bulletLines"))
        XCTAssertTrue(schema.contains("table: \"summaryDecisionEvidence\""))
        XCTAssertTrue(schema.contains("table: \"summaryDecisionEvidenceSegment\""))
        XCTAssertTrue(storage.contains("must address a rendered summary bullet"))
        XCTAssertTrue(storage.contains("validatedSummaryEvidence"))
        XCTAssertTrue(structured.contains("sections.count == request.recipe.sections.count"))
        XCTAssertTrue(structured.contains("resolveEvidenceTags"))
        XCTAssertTrue(provider.contains("bulletEvidence"))
        XCTAssertTrue(translation.contains("translatedDecisionEvidence"))
        XCTAssertTrue(translation.contains("Exactly one entry per instructed section heading"))
        XCTAssertFalse(translation.contains("Do NOT add a section for action items"))
        XCTAssertTrue(bundle.contains("decisionEvidence: summary.decisionEvidence.compactMap"))
        XCTAssertTrue(detail.contains("summary-decision-"))
        XCTAssertTrue(detail.contains("focusEvidence(segment)"))
        XCTAssertFalse(diagnostics.contains("SummaryDecisionEvidence"))
    }

    func testActionItemEvidenceStaysIdentityTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SummaryActionItemEvidence.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SummaryActionItemEvidence.swift")
        let structured = try Self.contents(
            of: "Sources/IntelligenceKit/StructuredSummary.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("struct SummaryActionItemEvidence"))
        XCTAssertTrue(core.contains("actionItemID: UUID"))
        XCTAssertTrue(schema.contains("table: \"summaryActionItemEvidence\""))
        XCTAssertTrue(schema.contains("table: \"summaryActionItemEvidenceSegment\""))
        XCTAssertTrue(storage.contains("action-item evidence identities and targets"))
        XCTAssertTrue(storage.contains("validatedSummaryEvidence"))
        XCTAssertTrue(structured.contains("typedActionItemEvidence"))
        XCTAssertTrue(structured.contains("translatedActionItemEvidence"))
        XCTAssertTrue(provider.contains("\"evidence\": [\"E3\"]"))
        XCTAssertTrue(bundle.contains("actionItemMap[evidence.actionItemID]"))
        XCTAssertTrue(detail.contains("summary-action-item-"))
        XCTAssertFalse(companion.contains("SummaryActionItemEvidence"))
        XCTAssertFalse(diagnostics.contains("SummaryActionItemEvidence"))
    }

    func testCompanionEvidenceStaysRoleTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/CompanionCard.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+CompanionCardEvidence.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CompanionCardEvidence.swift")
        let provenance = try Self.contents(
            of: "Sources/IntelligenceKit/CompanionGenerationProvenance.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("struct CompanionCardEvidence"))
        XCTAssertTrue(core.contains("questionSegmentIDs"))
        XCTAssertTrue(core.contains("answerSegmentIDs"))
        XCTAssertTrue(schema.contains("table: \"companionCardEvidence\""))
        XCTAssertTrue(schema.contains("role IN ('question', 'answer')"))
        XCTAssertTrue(storage.contains("Companion evidence is stale"))
        XCTAssertTrue(schema.contains("onDelete: .setNull"))
        XCTAssertTrue(provenance.contains("CompanionEvidenceFactory"))
        XCTAssertTrue(provenance.contains("questionSegmentIDs"))
        XCTAssertTrue(companion.contains("citedPassageIndexes"))
        XCTAssertTrue(bundle.contains("remappedCompanionCard"))
        XCTAssertTrue(detail.contains("Question source"))
        XCTAssertTrue(detail.contains("Answer sources"))
        XCTAssertFalse(diagnostics.contains("CompanionCardEvidence"))
    }

    func testShareableRecapStaysSummaryDerivedReviewedAndUnsent() throws {
        let composer = try Self.contents(of: "Sources/ApplicationKit/MeetingRecap.swift")
        let sheet = try Self.contents(of: "Sources/portavoz-app/MeetingRecapSheet.swift")
        let exporter = try Self.contents(of: "Sources/IntegrationsKit/MeetingExporter.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // The transcript cannot reach a recap: the composer never receives
        // one, which is a stronger guarantee than filtering it out later.
        XCTAssertFalse(composer.contains("TranscriptSegment"))
        XCTAssertFalse(sheet.contains("TranscriptSegment"))
        XCTAssertFalse(sheet.contains("detail.segments"))
        // Nothing is sent from the review sheet: no transport, no gateway,
        // no credential. The destinations are the clipboard and the system
        // share sheet, both chosen by the user.
        for transport in ["URLSession", "DataEgress", "gateway", "secrets", "publish"] {
            XCTAssertFalse(
                sheet.contains(transport),
                "the recap sheet must not reach \(transport)")
        }
        XCTAssertTrue(sheet.contains("ShareLink("))
        // One channel renderer for every shared surface.
        XCTAssertTrue(exporter.contains("public static func render("))
        XCTAssertTrue(composer.contains("isActionItemsHeading"))
        XCTAssertTrue(detail.contains("MeetingRecapSheet("))
        XCTAssertTrue(decisions.contains("## D136"))
    }

    func testMeetingSyncJournalStaysContentFreeGenerationFencedAndAdapterFree() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let journal = try Self.contents(of: "Sources/StorageKit/Schema+MeetingSync.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+Sync.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(schema.contains("registerMigration(\"v14\")"))
        XCTAssertTrue(schema.contains("createMeetingSyncState(in: db)"))
        XCTAssertTrue(journal.contains("createEvidenceTriggers(in: db)"))
        XCTAssertTrue(journal.contains("localGeneration"))
        XCTAssertTrue(journal.contains("acknowledgedGeneration"))
        XCTAssertTrue(journal.contains("meetingSyncState.localGeneration + 1"))
        XCTAssertTrue(journal.contains(#"OLD.\($0) IS NOT NEW.\($0)"#))
        XCTAssertFalse(journal.contains(".references(\"meeting\""))
        for deviceLocalField in [
            "audioDirectory", "embedding", "generationRunID", "personID",
        ] {
            XCTAssertFalse(
                journal.contains(deviceLocalField),
                "sync triggers must not react to \(deviceLocalField)")
        }
        let tableStart = try XCTUnwrap(journal.range(
            of: "db.create(table: \"meetingSyncState\")"))
        let indexStart = try XCTUnwrap(journal.range(
            of: "try db.create(\n            index: \"meetingSyncState_on_pending\"",
            range: tableStart.upperBound..<journal.endIndex))
        let tableDefinition = journal[tableStart.lowerBound..<indexStart.lowerBound]
        for contentField in [
            "payload", "transcript", "markdown", "question", "answer", "voiceprint",
        ] {
            XCTAssertFalse(
                tableDefinition.contains(contentField),
                "sync journal must not persist \(contentField)")
        }
        XCTAssertTrue(storage.contains("markMeetingsForInitialSync"))
        XCTAssertTrue(storage.contains("initial seed limit must be positive"))
        XCTAssertTrue(storage.contains("change.generation <= record.localGeneration"))
        XCTAssertTrue(storage.contains("max("))
        XCTAssertFalse(manifest.contains("CloudKit"))
        let cloudKitImports = try Self.imports(under: "Sources")
            .filter { $0.module == "CloudKit" }
        XCTAssertEqual(
            cloudKitImports.map(\.file),
            [
                "IntegrationsKit/CloudKitMeetingSyncPlatform.swift",
                "IntegrationsKit/CloudMeetingRecordCodec.swift",
                "IntegrationsKit/CloudMeetingSyncCoordinator.swift",
                "IntegrationsKit/CloudMeetingSyncEngineDelegate.swift",
                "IntegrationsKit/CloudMeetingSyncRuntime.swift",
                "IntegrationsKit/CloudMeetingSyncStateStore+Persistence.swift",
                "IntegrationsKit/CloudMeetingSyncStateStore.swift",
                "IntegrationsKit/CloudRecordSystemFieldsCodec.swift",
                "IntegrationsKit/CloudSyncFailureClassifier.swift",
                "portavoz-app/MeetingSyncModel.swift",
            ])
        XCTAssertTrue(decisions.contains("## D92"))
    }

    func testEnhancedNotesStayAtomicPortableAndProvenanceFenced() throws {
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let notesSchema = try Self.contents(of: "Sources/StorageKit/Schema+EnhancedNotes.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+EnhancedNotes.swift")
        let useCase = try Self.contents(of: "Sources/ApplicationKit/EnhanceMeetingNotes.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingDetailObservation.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")

        // v15 owns its own triggers — the registered v14 list is never edited.
        XCTAssertTrue(schema.contains("registerMigration(\"v15\")"))
        XCTAssertTrue(schema.contains("createEnhancedNotes(in: db)"))
        XCTAssertTrue(schema.contains("createEnhancedNoteSyncTriggers(in: db)"))
        // One regenerable document per meeting, replaced in place.
        XCTAssertTrue(notesSchema.contains(
            "t.column(\"meetingID\", .text).notNull().unique().indexed()"))
        // Provenance stays device-local: severed on run pruning, never synced.
        XCTAssertTrue(notesSchema.contains(
            ".references(\"generationRun\", onDelete: .setNull)"))
        XCTAssertTrue(notesSchema.contains(
            "let portableColumns = [\"markdown\", \"language\", \"inputFingerprint\", \"deletedAt\"]"))
        // The succeeded run commits atomically WITH its artifact (D62-D78),
        // and replacement is an explicit update — never ON CONFLICT REPLACE.
        XCTAssertTrue(storage.contains("requires a succeeded run"))
        XCTAssertFalse(storage.contains("onConflict: .replace"))
        // Exact fingerprint + language reuse performs no model operation, so
        // it creates no GenerationRun (D62).
        XCTAssertTrue(useCase.contains("existing.inputFingerprint == fingerprint"))
        // Notes refresh independently: a notes failure degrades only its own
        // section, never the transcript root.
        XCTAssertTrue(observation.contains("func observeMeetingReviewNotes("))
        XCTAssertTrue(observation.contains(
            "regions: [\n                Table(\"meeting\"), Table(\"contextItem\"), Table(\"enhancedNote\")\n            ]"))
        // The view reaches enhancement through the use case, never the store.
        XCTAssertTrue(detail.contains("services.enhanceMeetingNotes.execute"))
        XCTAssertFalse(detail.contains("saveEnhancedNote"))
    }

    func testMeetingSyncEnvelopeKeepsPortableReplayOutsideCloudKitCallbacks() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let aggregate = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let replay = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncReplay.swift")
        let codec = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingSyncEnvelopeCodec.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let storageBoundary = aggregate + replay

        XCTAssertTrue(storageBoundary.contains("state.localGeneration == change.generation"))
        XCTAssertTrue(storageBoundary.contains("meeting.audioDirectory = nil"))
        XCTAssertTrue(storageBoundary.contains("speaker.personID = nil"))
        XCTAssertTrue(storageBoundary.contains("localChangePending"))
        XCTAssertTrue(storageBoundary.contains("deletionWon"))
        XCTAssertTrue(storageBoundary.contains("validateImmutableRemoteSummaries"))
        XCTAssertTrue(storageBoundary.contains(
            "state.acknowledgedGeneration = state.localGeneration"))
        for forbiddenType in [
            "AudioAsset", "GenerationRun", "DataEgressEvent", "ProcessingJob", "Voiceprint",
        ] {
            XCTAssertFalse(
                aggregate.contains("[MeetingSyncTimed<\(forbiddenType)"),
                "portable aggregate must not carry \(forbiddenType)")
        }
        XCTAssertTrue(codec.contains(".millisecondsSince1970"))
        XCTAssertTrue(codec.contains(".sortedKeys"))
        XCTAssertFalse(codec.contains("import CloudKit"))
        XCTAssertFalse(manifest.contains("SyncKit"))
        XCTAssertTrue(decisions.contains("## D93"))
    }

    func testCloudMeetingRecordCodecEncryptsContentWithoutOwningRuntime() throws {
        let codec = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingRecordCodec.swift")
        let protectedFile = try Self.contents(
            of: "Sources/IntegrationsKit/CloudSyncProtectedFile.swift")
        let storage = try Self.imports(under: "Sources/StorageKit")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(codec.contains("record.encryptedValues[Field.inlinePayload]"))
        XCTAssertTrue(codec.contains("CKAsset(fileURL: assetURL)"))
        XCTAssertTrue(codec.contains("CloudSyncProtectedFile.write"))
        XCTAssertTrue(protectedFile.contains("struct PublicationCapabilities"))
        XCTAssertTrue(protectedFile.contains("publicationCapabilities(in: directory)"))
        XCTAssertTrue(protectedFile.contains("FileProtectionType.complete"))
        XCTAssertTrue(protectedFile.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(protectedFile.contains("Darwin.write"))
        XCTAssertTrue(protectedFile.contains("Darwin.fsync"))
        XCTAssertFalse(protectedFile.contains("FileHandle"))
        XCTAssertTrue(protectedFile.contains("Darwin.rename"))
        XCTAssertTrue(protectedFile.contains("catch where isUnsupportedMetadataError(error)"))
        XCTAssertTrue(protectedFile.contains("NSUnderlyingErrorKey"))
        XCTAssertTrue(protectedFile.contains("Int(EINVAL)"))
        XCTAssertTrue(protectedFile.contains("Int(ENOTSUP)"))
        XCTAssertTrue(protectedFile.contains("!capabilities.completeProtection"))
        XCTAssertTrue(protectedFile.contains("!capabilities.backupExclusion"))
        let protection = try XCTUnwrap(protectedFile.range(of: ".protectionKey"))
        let contentWrite = try XCTUnwrap(protectedFile.range(of: "try write(data"))
        XCTAssertLessThan(protection.lowerBound, contentWrite.lowerBound)
        XCTAssertTrue(codec.contains("payloadSHA256"))
        XCTAssertTrue(codec.contains("existingRecord.recordID == recordID"))
        XCTAssertFalse(codec.contains("recordIDsToDelete"))
        XCTAssertFalse(storage.contains(where: { $0.module == "CloudKit" }))
        XCTAssertTrue(decisions.contains("## D94"))
        XCTAssertTrue(decisions.contains("## D116"))
    }

    func testCloudMeetingTransportStateStaysDurableAccountScopedAndDomainFree() throws {
        let state = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncState.swift")
        let store = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncStateStore.swift")
        let persistence = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncStateStore+Persistence.swift")
        let protectedFile = try Self.contents(
            of: "Sources/IntegrationsKit/CloudSyncProtectedFile.swift")
        let coordinator = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncCoordinator.swift")
        let delegate = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncEngineDelegate.swift")
        let runtime = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncRuntime.swift")
        let cloudTransport = state + store + persistence + protectedFile
            + coordinator + delegate + runtime
        let storageImports = try Self.imports(under: "Sources/StorageKit")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(state.contains("accountScopeFingerprint"))
        XCTAssertTrue(state.contains("initialSeedCursorMeetingID"))
        XCTAssertTrue(state.contains("initialSeedPreparedAt"))
        XCTAssertTrue(state.contains("deferredReplays"))
        XCTAssertTrue(store.contains("persistEngineState"))
        XCTAssertTrue(store.contains("stageDeferredReplay"))
        XCTAssertTrue(store.contains("CloudSyncProtectedFile.write"))
        XCTAssertTrue(protectedFile.contains("FileProtectionType.complete"))
        XCTAssertTrue(protectedFile.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(protectedFile.contains("Darwin.write"))
        XCTAssertTrue(protectedFile.contains("Darwin.fsync"))
        XCTAssertFalse(protectedFile.contains("FileHandle"))
        XCTAssertTrue(protectedFile.contains("Darwin.rename"))
        XCTAssertTrue(coordinator.contains("applyRemoteMeetingSyncEnvelope"))
        XCTAssertTrue(coordinator.contains("markMeetingsForInitialSync"))
        XCTAssertTrue(coordinator.contains("maintenanceGate.disposition("))
        XCTAssertTrue(coordinator.contains("shouldProceed(at: .checkpoint)"))
        XCTAssertTrue(coordinator.contains("recordInitialSeedProgress"))
        XCTAssertTrue(coordinator.contains("stageDeferredReplay"))
        XCTAssertTrue(coordinator.contains("shouldRetry: false"))
        XCTAssertTrue(delegate.contains("CKSyncEngineDelegate"))
        XCTAssertTrue(delegate.contains("preparePendingChanges"))
        XCTAssertFalse(delegate.contains("applyRemoteMeetingSyncEnvelope"))
        XCTAssertTrue(runtime.contains("configuration.automaticallySync = false"))
        XCTAssertTrue(runtime.contains("stateSerialization: try await"))
        XCTAssertFalse(cloudTransport.contains("CKContainer("))
        XCTAssertFalse(storageImports.contains(where: { $0.module == "CloudKit" }))
        XCTAssertTrue(decisions.contains("## D95"))
        XCTAssertTrue(decisions.contains("## D116"))
    }

    func testCloudSyncLifecycleKeepsConsentStatusAndUserActionsOutsideViews() throws {
        let lifecycle = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncLifecycle.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncObservation.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(lifecycle.contains("resumeIfConsented"))
        XCTAssertTrue(lifecycle.contains("guard snapshot.consentedAccountFingerprint != nil"))
        XCTAssertTrue(lifecycle.contains("protocol CloudMeetingSyncPlatform"))
        XCTAssertTrue(lifecycle.contains("includeExistingLibrary"))
        XCTAssertTrue(lifecycle.contains("coordinator.prepareInitialSeed()"))
        XCTAssertTrue(lifecycle.contains("retryPendingAttempts"))
        XCTAssertTrue(lifecycle.contains("removeThisDeviceState"))
        XCTAssertTrue(observation.contains("observeMeetingSyncJournalStatus"))
        XCTAssertFalse(lifecycle.contains("import CloudKit"))
        XCTAssertTrue(decisions.contains("## D96"))
    }

    func testCloudKitCompositionIsProvisionedLazyAndExplicitlyControlled() throws {
        let platform = try Self.contents(
            of: "Sources/IntegrationsKit/CloudKitMeetingSyncPlatform.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingSyncModel.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingSync.swift")
        let resourceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/MeetingSyncSettingsSection.swift")
        let entitlements = try Self.contents(of: "packaging/portavoz.entitlements")
        let localEntitlements = try Self.contents(
            of: "packaging/portavoz-local.entitlements")
        let builder = try Self.contents(of: "scripts/make-app.sh")
        let verifier = try Self.contents(
            of: "scripts/verify-cloudkit-capabilities.sh")
        let release = try Self.contents(of: "scripts/make-release.sh")
        let diskImage = try Self.contents(of: "scripts/make-dmg.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        let capabilityCheck = try XCTUnwrap(platform.range(
            of: "CloudKitMeetingSyncCapabilityProbe.current()"))
        XCTAssertNotNil(platform.range(
            of: "CKContainer(\n            identifier:",
            range: capabilityCheck.upperBound..<platform.endIndex))
        let accountStatus = try XCTUnwrap(platform.range(of: "container.accountStatus()"))
        XCTAssertNotNil(platform.range(
            of: "container.userRecordID()",
            range: accountStatus.upperBound..<platform.endIndex))
        XCTAssertFalse(platform.contains("automaticallySync = true"))
        XCTAssertTrue(platform.contains("engine.sendChanges()"))
        XCTAssertTrue(platform.contains("engine.fetchChanges()"))

        XCTAssertTrue(model.contains("guard !didStart"))
        XCTAssertTrue(model.contains("guard status.isEnabled"))
        XCTAssertTrue(model.contains("func maintenanceMayResume()"))
        XCTAssertTrue(model.contains("status.initialSeedState == .requested"))
        XCTAssertTrue(model.contains("UITestMeetingSyncClient"))
        XCTAssertTrue(composition.contains("usesTemporaryStore"))
        XCTAssertTrue(composition.contains("CloudKitMeetingSyncPlatform()"))
        XCTAssertTrue(composition.contains(
            "AppResourceGovernorMaintenanceGate.make("))
        XCTAssertTrue(composition.contains("maintenanceGate: maintenanceGate"))
        XCTAssertFalse(composition.contains("CKContainer("))
        XCTAssertTrue(resourceAdapter.contains(
            "meetingSync.maintenanceMayResume()"))

        for identifier in [
            "settings-sync-status", "settings-sync-enable", "settings-sync-now",
            "settings-sync-seed", "settings-sync-retry", "settings-sync-pause",
            "settings-sync-remove",
        ] {
            XCTAssertTrue(settings.contains(identifier))
        }
        XCTAssertTrue(settings.contains("Audio, local file paths, voiceprints"))

        for capability in [
            "com.apple.developer.icloud-container-identifiers",
            "iCloud.app.portavoz.mac",
            "com.apple.developer.icloud-services",
            "CloudKit",
            "com.apple.developer.icloud-container-environment",
            "com.apple.developer.aps-environment",
        ] {
            XCTAssertTrue(entitlements.contains(capability))
            if capability.hasPrefix("com.apple.developer") {
                XCTAssertFalse(localEntitlements.contains(capability))
            }
        }
        XCTAssertTrue(builder.contains("PORTAVOZ_PROVISIONING_PROFILE"))
        XCTAssertTrue(builder.contains("packaging/portavoz-local.entitlements"))
        XCTAssertTrue(verifier.contains("embedded.provisionprofile"))
        XCTAssertTrue(verifier.contains("security cms -D"))
        XCTAssertTrue(verifier.contains("profile.get(\"ExpirationDate\")"))
        XCTAssertTrue(verifier.contains("allow_icloud_services_wildcard=True"))
        XCTAssertTrue(verifier.contains("actual.get(key) in (\"*\", [\"*\"])"))
        XCTAssertTrue(release.contains("PORTAVOZ_SIGN_IDENTITY:?"))
        XCTAssertTrue(release.contains("PORTAVOZ_NOTARY_PROFILE:?"))
        let preflight = try XCTUnwrap(diskImage.range(
            of: "scripts/verify-cloudkit-capabilities.sh dist/Portavoz.app"))
        XCTAssertNotNil(diskImage.range(
            of: "notarytool submit \"$APP_ARCHIVE\"",
            range: preflight.upperBound..<diskImage.endIndex))
        XCTAssertTrue(decisions.contains("## D97"))
        XCTAssertTrue(decisions.contains(
            "## D179 — Checkpoint existing-library sync"))
    }

    func testDistributionNotarizesTheExtractedAppBeforeTheDMG() throws {
        let builder = try Self.contents(of: "scripts/make-dmg.sh")
        let verifier = try Self.contents(of: "scripts/verify-distribution.sh")

        let archive = try XCTUnwrap(builder.range(of: "ditto -c -k --sequesterRsrc"))
        let appSubmission = try XCTUnwrap(builder.range(
            of: "notarytool submit \"$APP_ARCHIVE\"", range: archive.upperBound..<builder.endIndex))
        let appStaple = try XCTUnwrap(builder.range(
            of: "stapler staple dist/Portavoz.app",
            range: appSubmission.upperBound..<builder.endIndex))
        let package = try XCTUnwrap(builder.range(
            of: "cp -a dist/Portavoz.app \"$STAGE/\"",
            range: appStaple.upperBound..<builder.endIndex))
        let imageSubmission = try XCTUnwrap(builder.range(
            of: "notarytool submit \"$DMG\"", range: package.upperBound..<builder.endIndex))
        let imageStaple = try XCTUnwrap(builder.range(
            of: "stapler staple \"$DMG\"",
            range: imageSubmission.upperBound..<builder.endIndex))
        XCTAssertNotNil(builder.range(
            of: "scripts/verify-distribution.sh \"$DMG\"",
            range: imageStaple.upperBound..<builder.endIndex))

        XCTAssertTrue(verifier.contains("cp -a \"$MOUNT/Portavoz.app\" \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(verifier.contains("stapler validate \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains("spctl -a -vvv -t exec \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains(
            "scripts/verify-cloudkit-capabilities.sh \"$APP_COPY\""))
    }

    func testReleaseReliabilityLedgerIsFailClosedAndContentFree() throws {
        let contract = try Self.jsonObject(
            at: "docs/evidence/reliability-gates.json")
        let proofs = try XCTUnwrap(contract["proofs"] as? [[String: Any]])
        XCTAssertEqual(proofs.count, 14)
        XCTAssertEqual(
            Set(proofs.compactMap { $0["class"] as? String }),
            Set([
                "deterministic-automated",
                "signed-build",
                "real-hardware",
                "user-field",
            ]))

        let evaluator = try Self.contents(of: "scripts/release_reliability.py")
        let runner = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")
        let verifier = try Self.contents(of: "scripts/verify-distribution.sh")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(evaluator.contains(
            #"outcome = "pass" if all(row["state"] == "pass""#))
        XCTAssertTrue(evaluator.contains(
            #""not-observed" if root["outcome"] == "incomplete""#))
        XCTAssertTrue(evaluator.contains(
            #""The scorecard contains no meeting content.""#))
        XCTAssertTrue(runner.contains("PORTAVOZ_RELEASE_VERSION"))
        XCTAssertTrue(runner.contains("make test-recording-stress"))
        XCTAssertTrue(runner.contains("make test-ui-scoped"))
        XCTAssertTrue(verifier.contains("record-distribution"))
        XCTAssertTrue(verifier.contains("--receipt"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_release_reliability"))
        XCTAssertTrue(decisions.contains("## D147"))
    }

    func testDevInstallVerifiesTheSignedBundleBeforeLaunchingIt() throws {
        let packager = try Self.contents(of: "scripts/make-app.sh")
        let makefile = try Self.contents(of: "Makefile")

        let packageSign = try XCTUnwrap(packager.range(
            of: "--entitlements \"$SIGN_ENTITLEMENTS\" \"$APP\""))
        let packageVerify = try XCTUnwrap(packager.range(
            of: "codesign --verify --deep --strict --verbose=2 \"$APP\"",
            range: packageSign.upperBound..<packager.endIndex))
        XCTAssertNotNil(packager.range(
            of: "echo \"OK → $APP",
            range: packageVerify.upperBound..<packager.endIndex))

        let resign = try XCTUnwrap(makefile.range(
            of: "codesign --force --options runtime --timestamp"))
        let devIdentity = try XCTUnwrap(makefile.range(
            of: "CFBundleIdentifier -string \"app.portavoz.mac.dev\"",
            range: makefile.startIndex..<resign.lowerBound))
        XCTAssertNotNil(makefile.range(
            of: "CFBundleDisplayName -string \"Portavoz Dev\"",
            range: makefile.startIndex..<devIdentity.lowerBound))
        XCTAssertNotNil(makefile.range(
            of: #"s/^"CFBundleDisplayName" = ".*""#,
            range: devIdentity.upperBound..<resign.lowerBound))
        XCTAssertNotNil(makefile.range(
            of: "plutil -lint \"$$plist\"",
            range: devIdentity.upperBound..<resign.lowerBound))
        let verifyDist = try XCTUnwrap(makefile.range(
            of: "codesign --verify --deep --strict --verbose=2 dist/Portavoz.app",
            range: resign.upperBound..<makefile.endIndex))
        let copy = try XCTUnwrap(makefile.range(
            of: "cp -R dist/Portavoz.app \"/Applications/Portavoz Dev.app\"",
            range: verifyDist.upperBound..<makefile.endIndex))
        let verifyInstalled = try XCTUnwrap(makefile.range(
            of: "codesign --verify --deep --strict --verbose=2 "
                + "\"/Applications/Portavoz Dev.app\"",
            range: copy.upperBound..<makefile.endIndex))
        let register = try XCTUnwrap(makefile.range(
            of: "-f \"/Applications/Portavoz Dev.app\"",
            range: verifyInstalled.upperBound..<makefile.endIndex))
        XCTAssertNotNil(makefile.range(
            of: "open \"/Applications/Portavoz Dev.app\"",
            range: register.upperBound..<makefile.endIndex))
    }

    func testDevelopmentAndUITestAppsCannotClaimTheReleaseIdentity() throws {
        let makefile = try Self.contents(of: "Makefile")
        let project = try Self.contents(of: "project.yml")
        let collector = try Self.contents(of: "scripts/collect-field-evidence.py")

        XCTAssertTrue(makefile.contains("app.portavoz.mac.dev"))
        XCTAssertTrue(project.contains(
            "PRODUCT_BUNDLE_IDENTIFIER: app.portavoz.mac.uitest-host"))
        XCTAssertTrue(collector.contains(
            #"CFBundleIdentifier") != "app.portavoz.mac.dev""#))
        XCTAssertFalse(project.contains(
            "PRODUCT_BUNDLE_IDENTIFIER: app.portavoz.mac\n"))
    }

    func testProductionSandboxDecisionStaysExplicitAndReproducible() throws {
        let productionEntitlements = try Self.contents(of: "packaging/portavoz.entitlements")
        let probeEntitlements = try Self.contents(
            of: "scripts/sandbox-spike/probe.entitlements")
        let runner = try Self.contents(of: "scripts/run-sandbox-capability-spike.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let evidence = try Self.contents(
            of: "docs/evidence/app-sandbox-capability-spike-20260716.json")

        XCTAssertFalse(productionEntitlements.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(probeEntitlements.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(runner.contains("SandboxCapabilityProbe.swift"))
        XCTAssertTrue(runner.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(runner.contains("sandboxEnforcementObserved"))
        XCTAssertTrue(evidence.contains(#""signingMode": "developer-id""#))
        XCTAssertTrue(evidence.contains(#""sandboxed""#))
        XCTAssertTrue(evidence.contains(#""nonSandboxedControl""#))
        XCTAssertEqual(
            evidence.components(separatedBy: "graph-started-and-stopped").count - 1,
            4,
            "Sandbox and control must each prove microphone and process-tap graph setup")
        XCTAssertTrue(decisions.contains("## D78"))
    }

    func testSupportDiagnosticsRemainRedactedLocalEvidence() throws {
        let exporter = try Self.contents(
            of: "Sources/ApplicationKit/ExportSupportDiagnostics.swift")
        for forbidden in [
            "title:", "segments:", "transcriptText", "summaryMarkdown", "actionItem",
            "companionCard", "configJSON", "metricsJSON", "errorMessage",
            "audioDirectory", "relativePath", "sha256", "sourceAssetID",
            "destinationURL", "apiKey"
        ] {
            XCTAssertFalse(exporter.contains(forbidden), "Exporter contains \(forbidden)")
        }
        XCTAssertTrue(exporter.contains("meeting.referenceDigest.prefix(12)"))
        XCTAssertTrue(exporter.contains("job.inputFingerprintDigest"))
        XCTAssertTrue(exporter.contains("run.inputFingerprintDigest"))
        XCTAssertTrue(exporter.contains("durationSeconds"))
        XCTAssertTrue(exporter.contains("systemSegmentCount"))

        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")
        XCTAssertTrue(storage.contains("supportDigest(meetingID.rawValue.uuidString)"))
        XCTAssertTrue(storage.contains("supportDigest(job.inputFingerprint)"))
        XCTAssertTrue(storage.contains("supportDigest(run.inputFingerprint)"))
        XCTAssertFalse(storage.contains("errorMessage:"))
        XCTAssertFalse(storage.contains("configJSON:"))
        XCTAssertFalse(storage.contains("metricsJSON:"))
        XCTAssertTrue(storage.contains("FROM audioAsset"))
        XCTAssertTrue(storage.contains("FROM segment"))
        XCTAssertFalse(storage.contains("SELECT *"))

        let settings = try Self.contents(
            of: "Sources/portavoz-app/SupportDiagnosticsSection.swift")
        XCTAssertTrue(settings.contains("NSSavePanel"))
        XCTAssertFalse(settings.contains("URLSession"))
        XCTAssertFalse(settings.contains("DataEgressGateway"))

        let worker = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        guard let telemetryStart = worker.range(
            of: "private final class PostCaptureProcessingTelemetry"),
            let compositionStart = worker.range(
                of: "extension AppServices",
                range: telemetryStart.upperBound..<worker.endIndex)
        else {
            return XCTFail("Durable-processing signpost boundary is missing")
        }
        let signpostedExecution = worker[
            telemetryStart.lowerBound..<compositionStart.lowerBound]
        XCTAssertTrue(signpostedExecution.contains("kind.rawValue"))
        XCTAssertTrue(signpostedExecution.contains("attempt"))
        XCTAssertTrue(signpostedExecution.contains("outcome.rawValue"))
        XCTAssertFalse(signpostedExecution.contains("job.id"))
        XCTAssertFalse(signpostedExecution.contains("job.meetingID"))
        XCTAssertFalse(signpostedExecution.contains("localizedDescription"))
    }

    func testBandFourScaleBaselineStaysMeasuredAndDisposable() throws {
        let cli = try Self.contents(of: "Sources/portavoz-cli/CLIBenchScale.swift")
        let semanticCLI = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchSemantic.swift")
        let waveformCLI = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchWaveform.swift")
        let spotlightCLI = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchSpotlight.swift")
        let dispatch = try Self.contents(of: "Sources/portavoz-cli/CLI.swift")
        let package = try Self.contents(of: "Package.swift")
        let scaleRunner = try Self.contents(of: "scripts/run-scale-baseline.sh")
        let semanticRunner = try Self.contents(
            of: "scripts/run-semantic-scale-baseline.sh")
        let spotlightRunner = try Self.contents(
            of: "scripts/run-spotlight-scale-baseline.sh")
        let detailRunner = try Self.contents(of: "scripts/run-detail-ui-baseline.sh")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ScaleBenchmark.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let health = try Self.contents(of: "Sources/IntelligenceKit/MeetingHealth.swift")
        let search = try Self.contents(of: "Sources/StorageKit/MeetingStore+Search.swift")
        let ask = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let waveform = try Self.contents(of: "Sources/AudioPlaybackKit/Waveform.swift")
        let spotlightProjection = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Spotlight.swift")
        let spotlightIndexer = try Self.contents(
            of: "Sources/portavoz-app/SpotlightIndexer.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(dispatch.contains(#"case "bench-scale":"#))
        XCTAssertTrue(dispatch.contains(#"case "bench-semantic":"#))
        XCTAssertTrue(dispatch.contains(#"case "bench-waveform":"#))
        XCTAssertTrue(dispatch.contains(#"case "bench-spotlight":"#))
        XCTAssertTrue(dispatch.contains("[--mode legacy|snapshot]"))
        XCTAssertTrue(dispatch.contains("[--delivery-items 1000]"))
        XCTAssertTrue(package.contains(#""StorageKit", "IntegrationsKit", "AudioPlaybackKit""#))
        XCTAssertTrue(cli.contains("withTemporaryDirectory(prefix:"))
        XCTAssertTrue(cli.contains("omittingEmptySubsequences: false"))
        XCTAssertTrue(scaleRunner.contains("swift build -c release --product portavoz-cli"))
        XCTAssertTrue(scaleRunner.contains(#""buildConfiguration") != "release""#))
        XCTAssertTrue(semanticCLI.contains("let dimension = await embedder.dimension"))
        XCTAssertTrue(semanticCLI.contains("profile: profile"))
        XCTAssertTrue(semanticCLI.contains("mach_timebase_info(&timebase)"))
        XCTAssertTrue(semanticCLI.contains("usage.ri_phys_footprint"))
        XCTAssertTrue(semanticRunner.contains("swift build -c release --product portavoz-cli"))
        XCTAssertTrue(semanticRunner.contains(#"for raw_size in "${checkpoints[@]}""#))
        XCTAssertTrue(semanticRunner.contains(#"report.get("buildConfiguration") != "release""#))
        XCTAssertTrue(waveformCLI.contains("withWaveformTemporaryDirectory"))
        XCTAssertTrue(waveformCLI.contains("FileManager.default.copyItem"))
        XCTAssertTrue(waveformCLI.contains("usage.ri_phys_footprint"))
        XCTAssertTrue(waveformCLI.contains("replacementFingerprint != first.fingerprint"))
        XCTAssertTrue(spotlightCLI.contains("legacyDocuments(store:"))
        XCTAssertTrue(spotlightCLI.contains(#"case "--delivery-items":"#))
        XCTAssertTrue(spotlightCLI.contains("contentSource: \"synthetic-only\""))
        XCTAssertTrue(spotlightCLI.contains("protectionClass: .complete"))
        XCTAssertTrue(spotlightRunner.contains("swift build -c release --product portavoz-cli"))
        XCTAssertTrue(spotlightRunner.contains("for mode in legacy snapshot"))
        XCTAssertTrue(spotlightRunner.contains("resultFingerprintEquivalent"))
        XCTAssertTrue(fixture.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(fixture.contains(#"arguments.contains("-seed-scale")"#))
        XCTAssertTrue(model.contains(#""Meeting Detail First Content""#))
        XCTAssertTrue(detailRunner.contains(#"--template "$template""#))
        XCTAssertTrue(detailRunner.contains(#""$APP" == "/Applications/Portavoz.app""#))
        XCTAssertTrue(detailRunner.contains("Trace file had no SwiftUI data"))
        XCTAssertTrue(decisions.contains("## D79 — Scale changes follow measured bottlenecks"))
        XCTAssertTrue(decisions.contains("## D80 — Bound interruption scans with prefix evidence"))
        XCTAssertTrue(decisions.contains("## D81 — Bound broad retrieval before vector storage"))
        XCTAssertTrue(decisions.contains("## D82 — Measure semantic cost before changing storage"))
        XCTAssertTrue(decisions.contains("## D83 — Keep exact vectors after the adapter passes"))
        XCTAssertTrue(decisions.contains("## D84 — Vectorize waveform envelopes before caching"))
        XCTAssertTrue(decisions.contains(
            "## D85 — Reconcile Spotlight through a protected measured snapshot"))
        XCTAssertTrue(health.contains("prefixMaximumEnd"))
        XCTAssertTrue(health.contains(
            "guard prefixMaximumEnd[previousIndex] > segment.startTime else { break }"))
        XCTAssertTrue(search.contains("ORDER BY rank"))
        XCTAssertFalse(search.contains("ORDER BY bm25(segmentSearch)"))
        XCTAssertTrue(search.contains("Row.fetchCursor"))
        XCTAssertTrue(search.contains("withUnsafeData(atIndex: 0)"))
        XCTAssertTrue(search.contains("vDSP_dotpr"))
        XCTAssertTrue(search.contains("segment.meetingID NOT IN"))
        XCTAssertTrue(search.contains("ORDER BY segment.rowid ASC"))
        XCTAssertTrue(search.contains("candidates.count == limit"))
        XCTAssertTrue(search.contains("semanticHits(in: db, candidates:"))
        XCTAssertTrue(search.contains("stride(from: 0, to: rowIDs.count, by: 500)"))
        XCTAssertTrue(ask.contains("public static func retrieveLexical"))
        XCTAssertTrue(ask.contains("guard terms.count <= 8"))
        XCTAssertTrue(ask.contains("1.0 / Double(60 + rank)"))
        XCTAssertTrue(cli.contains("LocalAskMeetingRetrieval.retrieveLexical"))
        XCTAssertTrue(waveform.contains("vDSP_maxmgv"))
        XCTAssertFalse(waveform.contains("WaveformCache"))
        XCTAssertTrue(spotlightProjection.contains("func spotlightDocuments()"))
        XCTAssertTrue(spotlightProjection.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(spotlightProjection.contains("segmentRank <= 40"))
        XCTAssertTrue(spotlightIndexer.contains("actor SpotlightIndexer"))
        XCTAssertTrue(spotlightIndexer.contains(#"indexName = "app.portavoz.meetings.v2""#))
        XCTAssertTrue(spotlightIndexer.contains("protectionClass: .complete"))
        XCTAssertTrue(spotlightIndexer.contains("index.beginBatch()"))
        XCTAssertTrue(spotlightIndexer.contains("endBatch(withClientState:"))
        XCTAssertTrue(spotlightIndexer.contains("retryDelays"))
        XCTAssertFalse(spotlightIndexer.contains("outboxEvent"))
        XCTAssertTrue(services.contains("@ObservationIgnored let spotlightIndexer"))
        XCTAssertTrue(services.contains("func requestSearchReconciliation()"))
        XCTAssertFalse(services.contains("libraryVersion"))
        XCTAssertFalse(content.contains("libraryVersion"))

        let scale = try Self.jsonObject(
            at: "docs/evidence/scale-baseline-20260716.json")
        XCTAssertEqual(scale["buildConfiguration"] as? String, "release")
        let library = try XCTUnwrap(scale["library"] as? [[String: Any]])
        XCTAssertEqual(library.compactMap { $0["totalSegments"] as? Int }, [
            1_000, 10_000, 50_000, 100_000,
        ])
        let meetings = try XCTUnwrap(scale["longMeetings"] as? [[String: Any]])
        XCTAssertEqual(meetings.compactMap { $0["durationMinutes"] as? Int }, [30, 120, 480])

        let detail = try Self.jsonObject(
            at: "docs/evidence/detail-ui-baseline-20260716.json")
        let reproduction = try XCTUnwrap(detail["reproduction"] as? [String: Any])
        XCTAssertEqual(reproduction["releaseApplicationProtected"] as? Bool, true)
        let firstContent = try XCTUnwrap(detail["firstContent"] as? [String: Any])
        XCTAssertGreaterThan(firstContent["durationMilliseconds"] as? Double ?? 0, 0)
        let swiftUI = try XCTUnwrap(detail["swiftUI"] as? [String: Any])
        let status = try XCTUnwrap(swiftUI["status"] as? String)
        XCTAssertTrue(["captured", "unavailable-toolchain"].contains(status))
        if status == "unavailable-toolchain" {
            XCTAssertFalse((detail["limitations"] as? [String] ?? []).isEmpty)
        }

        let afterScale = try Self.jsonObject(
            at: "docs/evidence/scale-baseline-20260716-after-health.json")
        let afterMeetings = try XCTUnwrap(afterScale["longMeetings"] as? [[String: Any]])
        let beforeFiveThousand = try XCTUnwrap(meetings.first {
            $0["segmentCount"] as? Int == 5_000
        })
        let afterFiveThousand = try XCTUnwrap(afterMeetings.first {
            $0["segmentCount"] as? Int == 5_000
        })
        XCTAssertLessThan(
            try Self.p95(in: afterFiveThousand, key: "meetingHealth"),
            try Self.p95(in: beforeFiveThousand, key: "meetingHealth") / 10)

        let afterDetail = try Self.jsonObject(
            at: "docs/evidence/detail-ui-baseline-20260716-after-health.json")
        let afterFirstContent = try XCTUnwrap(afterDetail["firstContent"] as? [String: Any])
        XCTAssertLessThan(afterFirstContent["durationMilliseconds"] as? Double ?? .infinity, 300)
        let afterResponsiveness = try XCTUnwrap(
            afterDetail["responsiveness"] as? [String: Any])
        XCTAssertEqual(afterResponsiveness["potentialHangCount"] as? Int, 0)

        let afterSearch = try Self.jsonObject(
            at: "docs/evidence/scale-baseline-20260716-after-search.json")
        let searchLibrary = try XCTUnwrap(afterSearch["library"] as? [[String: Any]])
        let beforeHundredThousand = try XCTUnwrap(
            try XCTUnwrap(afterScale["library"] as? [[String: Any]]).first {
                $0["totalSegments"] as? Int == 100_000
            })
        let afterHundredThousand = try XCTUnwrap(searchLibrary.first {
            $0["totalSegments"] as? Int == 100_000
        })
        let beforeBroad = try Self.p95(
            in: beforeHundredThousand, key: "questionRetrieval")
        let afterBroad = try Self.p95(
            in: afterHundredThousand, key: "questionRetrieval")
        XCTAssertLessThan(afterBroad, 100)
        XCTAssertLessThan(afterBroad, beforeBroad * 0.75)
        XCTAssertLessThan(
            try Self.p95(in: afterHundredThousand, key: "exactSearch"),
            50)

        let semantic = try Self.jsonObject(
            at: "docs/evidence/semantic-scale-baseline-20260716.json")
        XCTAssertEqual(semantic["buildConfiguration"] as? String, "release")
        let semanticConfiguration = try XCTUnwrap(
            semantic["configuration"] as? [String: Any])
        XCTAssertEqual(semanticConfiguration["embeddingDimension"] as? Int, 512)
        XCTAssertEqual(semanticConfiguration["measurementRuns"] as? Int, 20)
        let semanticCheckpoints = try XCTUnwrap(
            semantic["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(semanticCheckpoints.compactMap { $0["totalSegments"] as? Int }, [
            1_000, 10_000, 50_000, 100_000,
        ])
        let semanticHundredThousand = try XCTUnwrap(semanticCheckpoints.last)
        XCTAssertGreaterThan(
            try Self.p95(in: semanticHundredThousand, key: "wallTime"),
            100)
        XCTAssertGreaterThan(
            try Self.p95(in: semanticHundredThousand, key: "processCPUTime"),
            100)
        let incrementalFootprint = try XCTUnwrap(
            semanticHundredThousand["incrementalPeakPhysicalFootprint"] as? [String: Any])
        XCTAssertLessThan(
            incrementalFootprint["p95Bytes"] as? Int ?? .max,
            64 * 1_048_576)

        let afterSemantic = try Self.jsonObject(
            at: "docs/evidence/semantic-scale-after-adapter-20260717.json")
        XCTAssertEqual(afterSemantic["buildConfiguration"] as? String, "release")
        let afterSemanticConfiguration = try XCTUnwrap(
            afterSemantic["configuration"] as? [String: Any])
        XCTAssertEqual(afterSemanticConfiguration["embeddingDimension"] as? Int, 512)
        XCTAssertEqual(afterSemanticConfiguration["measurementRuns"] as? Int, 20)
        let afterSemanticCheckpoints = try XCTUnwrap(
            afterSemantic["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(
            afterSemanticCheckpoints.compactMap { $0["totalSegments"] as? Int },
            [1_000, 10_000, 50_000, 100_000])
        let afterSemanticHundredThousand = try XCTUnwrap(afterSemanticCheckpoints.last)
        let beforeSemanticWall = try Self.p95(
            in: semanticHundredThousand, key: "wallTime")
        let afterSemanticWall = try Self.p95(
            in: afterSemanticHundredThousand, key: "wallTime")
        let beforeSemanticCPU = try Self.p95(
            in: semanticHundredThousand, key: "processCPUTime")
        let afterSemanticCPU = try Self.p95(
            in: afterSemanticHundredThousand, key: "processCPUTime")
        XCTAssertLessThan(afterSemanticWall, 100)
        XCTAssertLessThan(afterSemanticCPU, 100)
        XCTAssertLessThan(afterSemanticWall, beforeSemanticWall / 3)
        XCTAssertLessThan(afterSemanticCPU, beforeSemanticCPU / 3)
        let afterPeakFootprint = try XCTUnwrap(
            afterSemanticHundredThousand["peakPhysicalFootprint"] as? [String: Any])
        XCTAssertLessThan(
            afterPeakFootprint["p95Bytes"] as? Int ?? .max,
            24 * 1_048_576)

        let waveformBaseline = try Self.jsonObject(
            at: "docs/evidence/waveform-scale-baseline-20260717.json")
        let waveformAfter = try Self.jsonObject(
            at: "docs/evidence/waveform-scale-after-accelerate-20260717.json")
        XCTAssertEqual(waveformBaseline["buildConfiguration"] as? String, "release")
        XCTAssertEqual(waveformAfter["buildConfiguration"] as? String, "release")
        let waveformConfiguration = try XCTUnwrap(
            waveformAfter["configuration"] as? [String: Any])
        XCTAssertEqual(waveformConfiguration["repeatedRuns"] as? Int, 20)
        XCTAssertEqual(waveformConfiguration["bucketCount"] as? Int, 600)
        let waveformSource = try XCTUnwrap(waveformAfter["source"] as? [String: Any])
        XCTAssertEqual(waveformSource["copiedToScratch"] as? Bool, true)
        XCTAssertEqual(waveformSource["channelCount"] as? Int, 2)
        XCTAssertGreaterThan(waveformSource["durationSeconds"] as? Double ?? 0, 3_300)
        XCTAssertGreaterThan(waveformSource["totalBytes"] as? Int ?? 0, 600_000_000)
        let waveformBeforeFirst = try XCTUnwrap(
            waveformBaseline["firstGeneration"] as? [String: Any])
        let waveformAfterFirst = try XCTUnwrap(
            waveformAfter["firstGeneration"] as? [String: Any])
        XCTAssertEqual(
            waveformAfterFirst["resultFingerprint"] as? String,
            waveformBeforeFirst["resultFingerprint"] as? String)
        XCTAssertLessThan(
            waveformAfterFirst["wallMilliseconds"] as? Double ?? .infinity,
            150)
        XCTAssertLessThan(
            waveformAfterFirst["processCPUMilliseconds"] as? Double ?? .infinity,
            120)
        let waveformBeforeRepeat = try XCTUnwrap(
            waveformBaseline["repeatedGeneration"] as? [String: Any])
        let waveformAfterRepeat = try XCTUnwrap(
            waveformAfter["repeatedGeneration"] as? [String: Any])
        let waveformBeforeWall = try Self.p95(in: waveformBeforeRepeat, key: "wallTime")
        let waveformAfterWall = try Self.p95(in: waveformAfterRepeat, key: "wallTime")
        let waveformBeforeCPU = try Self.p95(
            in: waveformBeforeRepeat, key: "processCPUTime")
        let waveformAfterCPU = try Self.p95(
            in: waveformAfterRepeat, key: "processCPUTime")
        XCTAssertGreaterThan(waveformBeforeWall, 500)
        XCTAssertLessThan(waveformAfterWall, 100)
        XCTAssertLessThan(waveformAfterCPU, 100)
        XCTAssertLessThan(waveformAfterWall, waveformBeforeWall / 8)
        XCTAssertLessThan(waveformAfterCPU, waveformBeforeCPU / 8)
        let waveformFootprint = try XCTUnwrap(
            waveformAfterRepeat["incrementalPeakPhysicalFootprint"] as? [String: Any])
        XCTAssertLessThan(
            waveformFootprint["p95Bytes"] as? Int ?? .max,
            2 * 1_048_576)
        let waveformInvalidation = try XCTUnwrap(
            waveformAfter["invalidation"] as? [String: Any])
        XCTAssertEqual(waveformInvalidation["resultChanged"] as? Bool, true)
        XCTAssertNotEqual(
            waveformInvalidation["replacementFingerprint"] as? String,
            waveformAfterFirst["resultFingerprint"] as? String)

        let spotlight = try Self.jsonObject(
            at: "docs/evidence/spotlight-scale-after-snapshot-20260717.json")
        XCTAssertEqual(spotlight["buildConfiguration"] as? String, "release")
        let legacySpotlight = try XCTUnwrap(
            spotlight["legacyCheckpoints"] as? [[String: Any]])
        let snapshotSpotlight = try XCTUnwrap(
            spotlight["snapshotCheckpoints"] as? [[String: Any]])
        XCTAssertEqual(
            legacySpotlight.compactMap { $0["meetingCount"] as? Int },
            [1_000, 10_000, 100_000])
        XCTAssertEqual(
            snapshotSpotlight.compactMap { $0["meetingCount"] as? Int },
            [1_000, 10_000, 100_000])
        let legacySpotlightHundredThousand = try XCTUnwrap(legacySpotlight.last)
        let snapshotSpotlightHundredThousand = try XCTUnwrap(snapshotSpotlight.last)
        let legacySpotlightWall = try Self.p95(
            in: legacySpotlightHundredThousand, key: "projection", nestedKey: "wallTime")
        let snapshotSpotlightWall = try Self.p95(
            in: snapshotSpotlightHundredThousand, key: "projection", nestedKey: "wallTime")
        let snapshotSpotlightCPU = try Self.p95(
            in: snapshotSpotlightHundredThousand,
            key: "projection",
            nestedKey: "processCPUTime")
        XCTAssertGreaterThan(legacySpotlightWall, 20_000)
        XCTAssertLessThan(snapshotSpotlightWall, 500)
        XCTAssertLessThan(snapshotSpotlightCPU, 500)
        XCTAssertLessThan(snapshotSpotlightWall, legacySpotlightWall / 40)
        let snapshotSpotlightResources = try XCTUnwrap(
            snapshotSpotlightHundredThousand["projection"] as? [String: Any])
        XCTAssertLessThan(
            try Self.p95Bytes(
                in: snapshotSpotlightResources,
                key: "peakPhysicalFootprint"),
            160 * 1_048_576)
        XCTAssertLessThan(
            try Self.p95Bytes(
                in: snapshotSpotlightResources,
                key: "incrementalPeakPhysicalFootprint"),
            96 * 1_048_576)
        let spotlightEquivalence = try XCTUnwrap(
            spotlight["equivalence"] as? [[String: Any]])
        XCTAssertTrue(spotlightEquivalence.allSatisfy {
            $0["resultFingerprintEquivalent"] as? Bool == true
        })
        let spotlightDelivery = try XCTUnwrap(
            spotlight["syntheticDelivery"] as? [String: Any])
        XCTAssertEqual(spotlightDelivery["status"] as? String, "completed")
        XCTAssertEqual(spotlightDelivery["syntheticItemCount"] as? Int, 1_000)
        XCTAssertEqual(spotlightDelivery["protection"] as? String, "complete")
        XCTAssertEqual(spotlightDelivery["contentSource"] as? String, "synthetic-only")
        XCTAssertEqual(spotlightDelivery["cleanupSucceeded"] as? Bool, true)
    }

    func testApplicationUseCaseProvidesOneAsyncBoundary() async throws {
        let result = try await CharacterCount().execute("Portavoz")
        let callableResult = try await CharacterCount()("local first")

        XCTAssertEqual(result, 8)
        XCTAssertEqual(callableResult, 11)
    }
}

private extension ArchitectureDependencyTests {
    struct SourceImport {
        let file: String
        let module: String
    }

    struct CharacterCount: ApplicationUseCase {
        func execute(_ request: String) async throws -> Int { request.count }
    }

    static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    static func jsonObject(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func p95(in object: [String: Any], key: String) throws -> Double {
        let distribution = try XCTUnwrap(object[key] as? [String: Any])
        return try XCTUnwrap(distribution["p95Milliseconds"] as? Double)
    }

    static func p95(
        in object: [String: Any],
        key: String,
        nestedKey: String
    ) throws -> Double {
        let nested = try XCTUnwrap(object[key] as? [String: Any])
        return try p95(in: nested, key: nestedKey)
    }

    static func p95Bytes(in object: [String: Any], key: String) throws -> Int {
        let distribution = try XCTUnwrap(object[key] as? [String: Any])
        return try XCTUnwrap(distribution["p95Bytes"] as? Int)
    }

    static func imports(under relativeDirectory: String) throws -> [SourceImport] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        let regex = try NSRegularExpression(
            pattern: #"(?m)^\s*(?:@preconcurrency\s+)?import\s+([A-Za-z0-9_]+)"#)
        return try files.flatMap { file -> [SourceImport] in
            let source = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            return regex.matches(in: source, range: range).compactMap { match in
                guard let moduleRange = Range(match.range(at: 1), in: source) else { return nil }
                return SourceImport(file: file, module: String(source[moduleRange]))
            }
        }
    }

    static func sourceMatches(
        under relativeDirectory: String,
        pattern: String
    ) throws -> [String] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let regex = try NSRegularExpression(pattern: pattern)
        return try enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .compactMap { file in
                let source = try String(
                    contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                return regex.firstMatch(in: source, range: range) == nil ? nil : file
            }
    }
}

private struct TargetDeclaration {
    let name: String
    let dependencies: Set<String>
}

private enum TargetManifestParser {
    static func declarations(in manifest: String) throws -> [String: TargetDeclaration] {
        let regex = try NSRegularExpression(
            pattern: #"\.(?:target|executableTarget|testTarget)\s*\("#)
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        return try regex.matches(in: manifest, range: fullRange).reduce(into: [:]) {
            result, match in
            guard let markerRange = Range(match.range, in: manifest),
                let open = manifest[markerRange].lastIndex(of: "(")
            else { return }
            let openIndex = manifest.index(markerRange.lowerBound, offsetBy:
                manifest[markerRange].distance(from: manifest[markerRange].startIndex, to: open))
            guard let closeIndex = closingDelimiter(
                in: manifest, from: openIndex, open: "(", close: ")")
            else { throw ParseError.unbalancedTarget }
            let block = String(manifest[markerRange.lowerBound...closeIndex])
            guard let declaration = try declaration(from: block) else { return }
            result[declaration.name] = declaration
        }
    }

    private static func declaration(from block: String) throws -> TargetDeclaration? {
        let nameRegex = try NSRegularExpression(pattern: #"\bname\s*:\s*\"([^\"]+)\""#)
        let fullRange = NSRange(block.startIndex..., in: block)
        guard let match = nameRegex.firstMatch(in: block, range: fullRange),
            let nameRange = Range(match.range(at: 1), in: block)
        else { return nil }
        let name = String(block[nameRange])
        guard let labelRange = block.range(of: "dependencies:") else {
            return TargetDeclaration(name: name, dependencies: [])
        }
        guard let open = block[labelRange.upperBound...].firstIndex(of: "[") else {
            throw ParseError.missingDependencyArray
        }
        guard let close = closingDelimiter(in: block, from: open, open: "[", close: "]") else {
            throw ParseError.unbalancedDependencies
        }
        let dependencySource = String(block[open...close])
        let stringRegex = try NSRegularExpression(pattern: #"\"([^\"]+)\""#)
        let dependencyRange = NSRange(dependencySource.startIndex..., in: dependencySource)
        let dependencies = Set(stringRegex.matches(
            in: dependencySource, range: dependencyRange).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: dependencySource) else { return nil }
                return String(dependencySource[range])
            })
        return TargetDeclaration(name: name, dependencies: dependencies)
    }

    private static func closingDelimiter(
        in source: String,
        from start: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var state = LexicalState.code
        var index = start
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : nil
            switch state {
            case .code:
                if character == "/", nextCharacter == "/" { state = .lineComment }
                else if character == "/", nextCharacter == "*" { state = .blockComment }
                else if character == "\"" { state = .string }
                else if character == open { depth += 1 }
                else if character == close {
                    depth -= 1
                    if depth == 0 { return index }
                }
            case .string:
                if character == "\\" { index = next }
                else if character == "\"" { state = .code }
            case .lineComment:
                if character == "\n" { state = .code }
            case .blockComment:
                if character == "*", nextCharacter == "/" {
                    state = .code
                    index = next
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private enum LexicalState {
        case code
        case string
        case lineComment
        case blockComment
    }

    private enum ParseError: Error {
        case unbalancedTarget
        case missingDependencyArray
        case unbalancedDependencies
    }
}
