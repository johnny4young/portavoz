import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
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
            "### Signal-driven live translation (D169/D433)"))
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
        let checkpoint = try Self.contents(
            of: "Sources/IntelligenceKit/DeterministicLiveSummary.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let appProviders = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")
        let resourceGovernor = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let detection = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
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
        XCTAssertTrue(controller.contains("requestLiveSummaryRefresh()"))
        XCTAssertTrue(controller.contains("liveSummaryCoordinator().request()"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "cancelLiveSummaryWork()").count - 1,
            4,
            "Reset, next-session, and Stop must cancel live-summary work")
        XCTAssertTrue(detection.contains("requestLiveSummaryRefresh()"))
        XCTAssertTrue(checkpoint.contains("public enum DeterministicLiveSummary"))
        XCTAssertTrue(checkpoint.contains("public static let maximumExtracts = 24"))
        XCTAssertTrue(checkpoint.contains("public static let maximumCharacters = 6_000"))
        XCTAssertFalse(checkpoint.contains("FoundationModels"))
        XCTAssertFalse(checkpoint.contains("URLSession"))
        XCTAssertTrue(controller.contains(
            "liveSummaryCheckpoint = checkpoint"))
        XCTAssertTrue(controller.contains(
            "summarizedCaptionIDs.formUnion(window.map(\\.id))"))
        XCTAssertTrue(controller.contains(
            "sourceRevision == liveSummarySourceRevision"))
        XCTAssertTrue(controller.contains(
            "services?.refineLiveSummary("))
        XCTAssertTrue(appProviders.contains("case .appleOnDevice:"))
        XCTAssertTrue(appProviders.contains("case .ollama:"))
        XCTAssertTrue(appProviders.contains("case .mlx:"))
        XCTAssertTrue(appProviders.contains("priority: .background"))
        XCTAssertTrue(appProviders.contains("workloadClass: .liveInteractive"))
        XCTAssertEqual(
            appProviders.components(
                separatedBy: "withLiveSummaryRefinementTimeout(.seconds(12)").count - 1,
            3,
            "Every optional live-summary provider needs the same latency fence")
        XCTAssertTrue(appProviders.contains("-use-temp-store"))
        XCTAssertTrue(resourceGovernor.contains(
            "workloadClass: .liveInteractive"))
        XCTAssertTrue(resourceGovernor.contains(
            "func admitLiveLanguageInference() async -> Bool"))
        XCTAssertTrue(resourceGovernor.contains(
            "case .admitNow:\n            return true"))
        XCTAssertTrue(resourceGovernor.contains(
            "case .admitWithReducedConcurrency, .defer, .pauseAfterCheckpoint,"))
        XCTAssertTrue(resourceGovernor.contains(
            ".reject:\n            return false"))
        // Objective response fencing is exercised across the actual await in
        // RecordingObjectiveProposalTests, not frozen to predicate spelling.

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
        let qualitySpec = try Self.contents(
            of: "docs/specs/08-quality.md")
        XCTAssertTrue(architecture.contains(
            "Bounded signal-driven live summary"))
        XCTAssertFalse(architecture.contains("D171"))
        XCTAssertTrue(decisions.contains("## D171"))
        XCTAssertTrue(decisions.contains("## D433"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Bounded live-summary delivery (D171/D433)"))
        XCTAssertTrue(appSpec.contains(
            "### Recording-scoped live-summary coordinator (D171/D433)"))
        XCTAssertTrue(qualitySpec.contains(
            "### LIVE-0/LIVE-2 live-assistance authority (D430/D433)"))
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

    func testClearPlaybackSchedulesVolumeAsPurePolicyAndFailsClosed() throws {
        let composition = try Self.contents(
            of: "Sources/AudioPlaybackKit/MeetingAudioComposition.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        for boundary in [
            "enum CleanPlaybackVolumeEvent",
            "public static func canDuckBetween(",
            "earlierEnd + release <= laterStart - attack",
            "public static func volumeSchedule(",
            "public static func isStrictlyOrdered(",
            "CleanPlaybackPolicy.isStrictlyOrdered(schedule)",
        ] {
            XCTAssertTrue(composition.contains(boundary), boundary)
        }
        // The ramps must be replayed from the schedule, never recomputed at
        // the AVFoundation boundary where ordering cannot be proven.
        XCTAssertFalse(composition.contains("range.lowerBound - CleanPlaybackPolicy.attack"))
        XCTAssertFalse(composition.contains("range.upperBound + CleanPlaybackPolicy.release"))
        XCTAssertEqual(
            composition.components(separatedBy: "setVolumeRamp(").count - 1,
            1,
            "exactly one ramp call, driven by the schedule")
        XCTAssertTrue(decisions.contains("## D287"))
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

    func testInterviewAssistRemainsPullBasedBoundedAndRecordingScoped() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/AssistInterviewQuestion.swift")
        let citationPolicy = try Self.contents(
            of: "Sources/ApplicationKit/NumberedCitationAnswer.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/RecordingInterviewAssistModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/RecordingInterviewAssistView.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let router = try Self.contents(
            of: "Sources/portavoz-app/AppSelectedAskMeetingAnswering.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/InterviewAssistUITests.swift")

        XCTAssertTrue(workflow.contains("maximumCandidateRows = 24"))
        XCTAssertTrue(workflow.contains("maximumEvidenceRows = 8"))
        XCTAssertTrue(workflow.contains("candidate.meetingID == row.meetingID"))
        XCTAssertTrue(workflow.contains("item.endedAt <= question.askedAt"))
        XCTAssertTrue(workflow.contains("NumberedCitationAnswer.exactIndexes"))
        XCTAssertTrue(citationPolicy.contains("everySentenceHasCitation"))
        XCTAssertTrue(workflow.contains("timeout: Duration = .seconds(8)"))
        XCTAssertFalse(workflow.contains("import SwiftUI"))
        XCTAssertFalse(workflow.contains("import StorageKit"))

        XCTAssertTrue(model.contains("requestID == id"))
        XCTAssertTrue(model.contains("task?.cancel()"))
        XCTAssertTrue(model.contains("self.context?.question == context.question"))
        XCTAssertTrue(controller.contains("interviewAssist.reset()"))
        XCTAssertTrue(router.contains("InterviewQuestionAnswering"))
        XCTAssertFalse(view.contains("RAGAnswerer"))
        XCTAssertFalse(view.contains("import IntelligenceKit"))
        XCTAssertTrue(view.contains(".accessibilityElement(children: .contain)"))
        for identifier in [
            "recording-interview-panel",
            "recording-interview-current-question",
            "recording-interview-answer",
            "recording-interview-grounded-answer",
        ] {
            XCTAssertTrue(view.contains(identifier), "missing \(identifier)")
        }
        XCTAssertTrue(uiTest.contains(
            "testInterviewAssistGroundsTheCurrentQuestionInExactEvidence"))

        XCTAssertTrue(try Self.contents(of: "docs/ARCHITECTURE.md").contains(
            "Live interview assistance is a separate pull-based ApplicationKit workflow"))
        for path in [
            "docs/DECISIONS.md",
            "docs/specs/04-intelligence.md", "docs/specs/06-app-macos.md",
            "docs/specs/08-quality.md",
        ] {
            XCTAssertTrue(try Self.contents(of: path).contains("D388"), path)
        }
    }

    func testLiveAssistBaselineStaysPublicContentFreeAndNonServing() throws {
        let contract = try Self.contents(
            of: "Sources/portavoz-app/LiveAssistValidationContract.swift")
        let runner = try Self.contents(
            of: "Sources/portavoz-app/LiveAssistValidationRunner.swift")
        let faults = try Self.contents(
            of: "Sources/portavoz-app/LiveAssistValidationFaultRunner.swift")
        let bench = try Self.contents(of: "Sources/portavoz-app/BenchMode.swift")
        let launch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let wrapper = try Self.contents(
            of: "scripts/run-live-assist-validation.sh")
        let scorer = try Self.contents(of: "scripts/live_assist_validation.py")
        let makefile = try Self.contents(of: "Makefile")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(contract.contains(
            "287e77db9d9a277c3243c2ce3d7be37f1ada65379e8dae62bb1ed60aba466cb4"))
        XCTAssertTrue(contract.contains("public-synthetic-only"))
        XCTAssertFalse(runner.contains("expectedDecision"))
        XCTAssertFalse(runner.contains("referenceSummary"))
        XCTAssertTrue(runner.contains("FoundationModelsCapability.current().isAvailable"))
        XCTAssertTrue(runner.contains("outputAlreadyExists"))
        XCTAssertTrue(faults.contains("LiveCompanionWorkCoordinator"))
        XCTAssertTrue(faults.contains("RecordingInterviewAssistModel"))
        XCTAssertTrue(faults.contains("LiveSummaryWorkCoordinator"))
        XCTAssertTrue(faults.contains("LiveTranslationWakeHub"))

        XCTAssertTrue(bench.contains("--bench-live-assist"))
        XCTAssertTrue(launch.contains("!BenchMode.runsBeforeAppServices"))
        XCTAssertTrue(wrapper.contains("--live-assist-source-state"))
        XCTAssertTrue(wrapper.contains("--require-targets"))
        XCTAssertTrue(wrapper.contains(
            "PORTAVOZ_SIGN_IDENTITY must select a real Developer ID identity"))
        XCTAssertFalse(wrapper.contains("PORTAVOZ_SIGN_IDENTITY:--"))
        XCTAssertFalse(wrapper.contains("-seed-demo"))
        XCTAssertFalse(wrapper.contains("MeetingStore"))
        XCTAssertTrue(scorer.contains("os.link(temporary, path)"))
        XCTAssertFalse(scorer.contains("os.replace(temporary, path)"))
        XCTAssertTrue(makefile.contains("test-live-assist-validation:"))
        XCTAssertTrue(makefile.contains("live-assist-bundled-question:"))
        XCTAssertTrue(makefile.contains("live-assist-foundation-models:"))
        XCTAssertTrue(decisions.contains("## D430"))
    }

    func testLiveApuntadorUsesPinnedProviderNeutralSequoiaDetector() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let detector = try Self.contents(
            of: "Sources/IntelligenceKit/LiveQuestionDetector.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/ProviderNeutralCompanion.swift")
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/CompanionSettingsSection.swift")
        let packager = try Self.contents(of: "scripts/make-app.sh")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")

        XCTAssertTrue(manifest.contains(
            #".copy("Resources/PortavozLiveQuestionClassifier.mlmodelc")"#))
        XCTAssertTrue(detector.contains("public actor BundledLiveQuestionDetector"))
        XCTAssertTrue(detector.contains(
            "d7d15611f91148ee4e4dd10cb3ea214b747009b82b2e82647bb7a8ab970dbe3d"))
        XCTAssertTrue(detector.contains(
            "db169ed16b55eef846eb7e779eb0490e158f872c7c5e25fb025af60ff582e1e8"))
        XCTAssertTrue(provider.contains("authoritativeDetection"))
        XCTAssertTrue(provider.contains("questionOnlyCard"))
        XCTAssertTrue(provider.contains("detection.kind == .knowledge, let byok"))
        XCTAssertTrue(recording.contains("ProviderNeutralProvenanceCompanion("))
        XCTAssertTrue(recording.contains(
            "allowsFoundationModelChallenger: services.appleSummaryAvailable"))
        XCTAssertFalse(recording.contains(
            "guard FoundationModelsCapability.current().isAvailable"))
        XCTAssertTrue(services.contains(
            "BundledLiveQuestionDetector.resourceIsLoadable"))
        XCTAssertTrue(settings.contains("settings-apuntador-enabled"))
        XCTAssertTrue(settings.contains(
            "the bundled bilingual detector works fully offline"))
        XCTAssertTrue(packager.contains("Portavoz_IntelligenceKit.bundle"))
        XCTAssertTrue(packager.contains(
            "PortavozLiveQuestionClassifier.mlmodelc"))
        XCTAssertTrue(scope.contains("livequestiondetector.swift"))
        XCTAssertTrue(scope.contains(
            "testSequoiaSummaryFailureOpensExactSetupAndExplainsApuntador"))
        XCTAssertTrue(decisions.contains("## D431"))
        XCTAssertTrue(architecture.contains(
            "bundled bilingual question classifier"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Provider-neutral live question admission (D431)"))
    }
}
