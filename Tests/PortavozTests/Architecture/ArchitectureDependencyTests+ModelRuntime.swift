import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
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

    func testPressureDrivenReleaseUsesGovernorAndAllConcreteOwners() throws {
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let monitor = try Self.contents(
            of: "Sources/portavoz-app/AppResourcePressureMonitor.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
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
        XCTAssertTrue(recording.contains(
            "@ObservationIgnored private let processActivity = RecordingProcessActivity()"))
        XCTAssertTrue(recording.contains(
            "didSet {\n            processActivity.update(for: phase)"),
            "Every recording phase transition must update the owned process activity")
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
        XCTAssertTrue(importAdapter.contains("resolver: summaryProviderResolver"),
                      "Import must reuse the shared resolver whose MLX factory crosses the app-owned ledger")
        XCTAssertFalse(importAdapter.contains("AppSummaryRegenerationProviderResolver("),
                       "Import must not duplicate the shared provider factory")
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
}
