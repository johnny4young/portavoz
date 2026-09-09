import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
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
        XCTAssertTrue(ci.contains(
            "run: scripts/run-swift-tests.sh -Xswiftc -warnings-as-errors"))
        XCTAssertFalse(ci.contains("run: swift build"))
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

    func testIOSReadinessUsesRealCompilationAndDormantContentFreeContracts() throws {
        let runner = try Self.contents(of: "scripts/check-ios-portability.sh")
        let workflow = try Self.contents(of: ".github/workflows/ci.yml")
        let commitmentMerge = try Self.contents(
            of: "Sources/PortavozCore/CommitmentReplicaMerge.swift")
        let deferredWork = try Self.contents(
            of: "Sources/PortavozCore/DeferredMacWork.swift")
        let cloudPlatform = try Self.contents(
            of: "Sources/IntegrationsKit/CloudKitMeetingSyncPlatform.swift")
        let meetingSync = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(runner.contains(
            "targets=(PortavozCore StorageKit ApplicationKit IntegrationsKit)"))
        XCTAssertTrue(runner.contains("arm64-apple-ios17.0-simulator"))
        XCTAssertTrue(runner.contains("for target in \"${targets[@]}\""))
        XCTAssertTrue(workflow.contains("  ios-portability:"))
        XCTAssertTrue(workflow.contains("run: scripts/check-ios-portability.sh"))
        XCTAssertFalse(runner.contains("xcodebuild test"))

        XCTAssertTrue(commitmentMerge.contains(
            "CommitmentContinuityPolicy.projectedCommitment"))
        XCTAssertTrue(commitmentMerge.contains("immutableSourceRewrite"))
        XCTAssertTrue(commitmentMerge.contains("immutableEventRewrite"))
        XCTAssertFalse(meetingSync.contains("CommitmentContinuityEnvelope"))

        for forbidden in [
            "transcript", "audio", "path", "prompt", "provider", "credential",
        ] {
            XCTAssertFalse(
                deferredWork.contains("public let \(forbidden)"),
                forbidden)
        }
        XCTAssertTrue(deferredWork.contains("maximumLeaseDuration"))
        XCTAssertTrue(deferredWork.contains("case staleSource"))
        XCTAssertTrue(deferredWork.contains("case cancel"))
        XCTAssertTrue(deferredWork.contains("case supersede"))

        XCTAssertTrue(cloudPlatform.contains("#if os(macOS)"))
        XCTAssertTrue(cloudPlatform.contains("SecTaskCreateFromSelf"))
        XCTAssertTrue(cloudPlatform.contains("containerIdentifiers: []"))
        XCTAssertTrue(decisions.contains("## D438"))
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

    func testApplicationUseCaseProvidesOneAsyncBoundary() async throws {
        let result = try await CharacterCount().execute("Portavoz")
        let callableResult = try await CharacterCount()("local first")

        XCTAssertEqual(result, 8)
        XCTAssertEqual(callableResult, 11)
    }
}
