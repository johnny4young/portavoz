import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class StopRecordingUseCaseTests: XCTestCase {
    func testPublishedCaptureInstallsExactJobAndKicksAfterCommit() async throws {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)

        let result = await fixture.useCase(dependencies).execute(fixture.request())

        guard case .completed(let commit) = result else {
            return XCTFail("published capture should complete")
        }
        let state = await dependencies.state()
        let installed = try XCTUnwrap(state.installs.first)
        XCTAssertEqual(commit.meeting.lifecycleState, .processing)
        XCTAssertEqual(commit.meeting.endedAt, fixture.now)
        XCTAssertEqual(commit.meeting.language, "es")
        XCTAssertEqual(commit.assets.map(\.healthStatus), [.healthy, .missing])
        XCTAssertEqual(installed.snapshot.meeting.lifecycleState, .captured)
        XCTAssertEqual(installed.snapshot.contextItems.map(\.content), ["Ship locally"])
        XCTAssertEqual(installed.snapshot.companionCards.map(\.question), ["When?"])
        XCTAssertEqual(installed.requests.count, 1)
        XCTAssertEqual(installed.requests[0].kind, .diarization)
        XCTAssertEqual(installed.requests[0].priority, 20)
        XCTAssertEqual(installed.requests[0].maxAttempts, 3)
        XCTAssertEqual(state.events.suffix(3), ["install", "kick", "release"])
        XCTAssertEqual(state.kickCount, 1)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testMixedTranscriptPreservesPerTurnLanguagesAndLeavesAggregateUnknown() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let mixed = [
            fixture.segment(
                channel: .system,
                text: "Esta intervención permanece en español.",
                language: "es",
                start: 0),
            fixture.segment(
                channel: .microphone,
                text: "This contribution remains in English.",
                language: "en",
                start: 2)
        ]

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(captions: mixed))

        guard case .completed(let commit) = result else {
            return XCTFail("mixed capture should complete")
        }
        let state = await dependencies.state()
        XCTAssertNil(commit.meeting.language)
        XCTAssertEqual(state.installs[0].snapshot.segments.map(\.language), ["es", "en"])
    }

    func testEmptyTranscriptAdmitsDurableAudioRecovery() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(captions: []))

        guard case .completed(let commit) = result else {
            return XCTFail("empty transcript should enter durable recovery")
        }
        let state = await dependencies.state()
        XCTAssertEqual(commit.meeting.lifecycleState, .processing)
        XCTAssertNil(commit.meeting.lastProcessingError)
        XCTAssertEqual(state.installs[0].requests.map(\.kind), [.transcription])
        XCTAssertEqual(state.installs[0].requests.first?.priority, 30)
        XCTAssertEqual(state.kickCount, 1)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testFailedLiveLaneRecoversCompleteTranscriptEvenWithPartialCaptions() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let capture = StopRecordingCapture(
            publishedFiles: [.system: fixture.publishedFile()],
            transcriptRequiresRecovery: true)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(captions: [fixture.captions[0]], capture: capture))

        guard case .completed(let commit) = result else {
            return XCTFail("a failed live lane should enter full transcript recovery")
        }
        let state = await dependencies.state()
        XCTAssertEqual(commit.meeting.lifecycleState, .processing)
        XCTAssertEqual(state.installs[0].snapshot.segments.count, 1)
        XCTAssertEqual(state.installs[0].requests.map(\.kind), [.transcription])
        XCTAssertEqual(state.kickCount, 1)
    }

    func testSilentAudioStillPreservesExplicitEmptyTranscriptGuidance() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let silent = StopRecordingCapture(
            publishedFiles: [.system: fixture.publishedFile(healthStatus: .silent)])

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(captions: [], capture: silent))

        guard case .transcriptEmpty(let commit) = result else {
            return XCTFail("truly silent audio cannot admit transcription work")
        }
        let state = await dependencies.state()
        XCTAssertEqual(commit.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(commit.meeting.lastProcessingError, "transcription.empty")
        XCTAssertTrue(state.installs[0].requests.isEmpty)
        XCTAssertEqual(state.kickCount, 0)
    }

    func testSilentCapturePersistenceFailureRetriesExactSnapshotWithoutDataLoss() async throws {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            installFailuresRemaining: 1)
        let silent = StopRecordingCapture(
            publishedFiles: [.system: fixture.publishedFile(healthStatus: .silent)])
        let generatedCard = CompanionCard(
            question: "What should I say?",
            answer: "Ask about the launch date.",
            kind: .context,
            source: "on-device",
            askedAt: 6)
        let generatedRun = GenerationRun(
            meetingID: fixture.meetingID,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "d", count: 64),
            configJSON: #"{"workflow":"companion"}"#,
            outputLanguage: "en",
            startedAt: fixture.startedAt,
            finishedAt: fixture.now,
            outcome: .succeeded,
            metricsJSON: #"{"answerUTF8Bytes":26}"#)
        let terminalRun = GenerationRun(
            meetingID: fixture.meetingID,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "e", count: 64),
            configJSON: #"{"workflow":"companion"}"#,
            outputLanguage: "en",
            startedAt: fixture.startedAt,
            finishedAt: fixture.now,
            outcome: .failed)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(
                captions: [],
                capture: silent,
                companionArtifacts: [CompanionGenerationArtifact(
                    card: generatedCard,
                    generationRun: generatedRun)],
                companionTerminalRuns: [terminalRun]))

        guard case .processingFailed(let failure, let fallback) = result else {
            return XCTFail("a rejected empty-transcript snapshot must degrade, not vanish")
        }
        XCTAssertEqual(failure, .snapshotPersistenceFailed)
        let commit = try XCTUnwrap(
            fallback,
            "one transient store error must not drop the only copy of the user's notes")
        XCTAssertEqual(commit.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(commit.meeting.lastProcessingError, "transcription.empty")
        let state = await dependencies.state()
        XCTAssertEqual(state.installAttempts, 2)
        let installed = try XCTUnwrap(state.installs.first)
        XCTAssertEqual(installed.snapshot.contextItems.map(\.content), ["Ship locally"])
        XCTAssertEqual(installed.snapshot.companionCards.map(\.question), ["When?"])
        XCTAssertEqual(
            installed.snapshot.companionArtifacts.map(\.card.question),
            ["What should I say?"])
        XCTAssertEqual(installed.snapshot.companionTerminalRuns, [terminalRun])
        XCTAssertTrue(installed.requests.isEmpty)
    }

    func testUnpublishedReservationAtEitherCapturePathPreservesRecovery() async {
        let fixture = StopRecordingFixture()
        let paths = [
            fixture.assets[0].relativePath,
            AudioCapturePath.publishedRelativePath(
                directory: fixture.directory,
                channel: fixture.assets[0].channel)
        ]

        for path in paths {
            let dependencies = StopRecordingDependencies(
                shell: fixture.shell,
                existingPaths: [path])
            let result = await fixture.useCase(dependencies).execute(
                fixture.request(capture: StopRecordingCapture(publishedFiles: [:])))

            guard case .audioRecoveryPreserved(let commit) = result else {
                return XCTFail("recovery evidence should preserve the shell")
            }
            let state = await dependencies.state()
            XCTAssertEqual(commit.meeting.lifecycleState, .needsAttention)
            XCTAssertEqual(commit.meeting.lastProcessingError, "capture.publication.failed")
            XCTAssertEqual(state.markedErrorCode, "capture.publication.failed")
            XCTAssertEqual(state.discardCount, 0)
            XCTAssertEqual(state.releaseCount, 1)
        }
    }

    func testEmptyCaptureWithoutFilesystemEvidenceDiscardsShell() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(capture: StopRecordingCapture(publishedFiles: [:])))

        guard case .noAudioCaptured = result else {
            return XCTFail("an empty reservation should be discarded")
        }
        let state = await dependencies.state()
        XCTAssertEqual(state.discardCount, 1)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testRefusedDiscardReportsUnavailableLocalState() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            discardResult: false)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(capture: StopRecordingCapture(publishedFiles: [:])))

        guard case .localStateUnavailable(let failure) = result else {
            return XCTFail("a protected shell must not be reported as discarded")
        }
        XCTAssertEqual(failure, .localStateUnavailable)
        XCTAssertEqual(failure.category, .critical)
        let state = await dependencies.state()
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testMissingShellOrDirectoryStillSchedulesRelease() async {
        let fixture = StopRecordingFixture()
        var withoutDirectory = fixture.shell
        withoutDirectory.audioDirectory = nil

        let requests = [
            fixture.request(includeShell: false),
            fixture.request(shell: withoutDirectory)
        ]
        for request in requests {
            let dependencies = StopRecordingDependencies(shell: fixture.shell)
            let result = await fixture.useCase(dependencies).execute(request)

            guard case .localStateUnavailable(let failure) = result else {
                return XCTFail("invalid local state should fail explicitly")
            }
            XCTAssertEqual(failure.code, "recording.stop.local-state.unavailable")
            let state = await dependencies.state()
            XCTAssertEqual(state.releaseCount, 1)
        }
    }

    func testPendingSystemPublicationFallsBackWithoutAdmittingJob() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            existingPaths: [fixture.assets[0].relativePath])
        let microphoneOnly = StopRecordingCapture(
            publishedFiles: [.microphone: fixture.publishedFile()])

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(capture: microphoneOnly))

        guard case .processingFailed(let failure, let fallback?) = result else {
            return XCTFail("pending system input should preserve a fallback")
        }
        let state = await dependencies.state()
        XCTAssertEqual(failure, .processingInputInvalid)
        XCTAssertEqual(failure.category, .recoverable)
        XCTAssertEqual(fallback.meeting.lastProcessingError, "capture.publication.failed")
        XCTAssertTrue(state.installs[0].requests.isEmpty)
        XCTAssertEqual(state.kickCount, 0)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testInvalidProcessingInputWithFailedFallbackReportsPersistenceFailure() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            existingPaths: [fixture.assets[0].relativePath],
            installFailuresRemaining: 3)
        let microphoneOnly = StopRecordingCapture(
            publishedFiles: [.microphone: fixture.publishedFile()])

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(capture: microphoneOnly))

        guard case .processingFailed(let failure, let fallback) = result else {
            return XCTFail("failed fallback persistence should replace the input failure")
        }
        let state = await dependencies.state()
        XCTAssertEqual(failure, .snapshotPersistenceFailed)
        XCTAssertEqual(failure.category, .critical)
        XCTAssertNil(fallback)
        XCTAssertEqual(state.installAttempts, 3)
        XCTAssertTrue(state.installs.isEmpty)
        XCTAssertEqual(state.kickCount, 0)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testRecoveryPersistenceFailureIsCriticalAndClaimsNoCommit() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            existingPaths: [fixture.assets[0].relativePath],
            markError: .mark)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(capture: StopRecordingCapture(publishedFiles: [:])))

        guard case .processingFailed(let failure, let fallback) = result else {
            return XCTFail("failed recovery persistence should remain explicit")
        }
        XCTAssertEqual(failure, .recoveryPersistenceFailed)
        XCTAssertEqual(failure.category, .critical)
        XCTAssertNil(fallback)
    }

    func testCleanupFailureIsDestructiveAndClaimsNoDiscard() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            discardError: .discard)

        let result = await fixture.useCase(dependencies).execute(
            fixture.request(capture: StopRecordingCapture(publishedFiles: [:])))

        guard case .processingFailed(let failure, let fallback) = result else {
            return XCTFail("failed cleanup should remain explicit")
        }
        XCTAssertEqual(failure, .cleanupFailed)
        XCTAssertEqual(failure.category, .destructive)
        XCTAssertNil(fallback)
    }

    func testTransientFullSnapshotFailureRetriesWithoutLosingOptionalContent() async throws {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            installFailuresRemaining: 1)

        let result = await fixture.useCase(dependencies).execute(fixture.request())

        guard case .completed(let commit) = result else {
            return XCTFail("a rejected optional payload should keep durable processing")
        }
        let state = await dependencies.state()
        XCTAssertEqual(state.installAttempts, 2)
        XCTAssertEqual(state.installs.count, 1)
        let installed = try XCTUnwrap(state.installs.first)
        XCTAssertEqual(commit.meeting.lifecycleState, .processing)
        XCTAssertEqual(installed.snapshot.segments.count, fixture.captions.count)
        XCTAssertEqual(installed.snapshot.contextItems.map(\.content), ["Ship locally"])
        XCTAssertEqual(installed.snapshot.companionCards.map(\.question), ["When?"])
        XCTAssertEqual(installed.requests.map(\.kind), [.diarization])
        XCTAssertEqual(state.kickCount, 1)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testRejectedCoreSnapshotFallsBackToAudioAndDurableTranscription() async throws {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            installFailuresRemaining: 3)

        let result = await fixture.useCase(dependencies).execute(fixture.request())

        guard case .completed(let commit) = result else {
            return XCTFail("validated audio should remain resumable after content rejection")
        }
        let state = await dependencies.state()
        let installed = try XCTUnwrap(state.installs.first)
        XCTAssertEqual(commit.meeting.lifecycleState, .processing)
        XCTAssertEqual(state.installAttempts, 4)
        XCTAssertTrue(installed.snapshot.segments.isEmpty)
        XCTAssertTrue(installed.snapshot.speakers.isEmpty)
        XCTAssertEqual(installed.snapshot.contextItems.map(\.content), ["Ship locally"])
        XCTAssertEqual(installed.requests.map(\.kind), [.transcription])
        XCTAssertEqual(state.kickCount, 1)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testEveryPersistenceProjectionFailureNeverClaimsACommit() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(
            shell: fixture.shell,
            installFailuresRemaining: 8)

        let result = await fixture.useCase(dependencies).execute(fixture.request())

        guard case .processingFailed(let failure, let fallback) = result else {
            return XCTFail("exhausting the bounded fallback ladder must remain explicit")
        }
        let state = await dependencies.state()
        XCTAssertEqual(failure, .snapshotPersistenceFailed)
        XCTAssertNil(fallback)
        XCTAssertEqual(state.installAttempts, 8)
        XCTAssertTrue(state.installs.isEmpty)
        XCTAssertEqual(state.kickCount, 0)
        XCTAssertEqual(state.releaseCount, 1)
    }

    func testExecutionEmitsOneRecordingCriticalWorkload() async {
        let fixture = StopRecordingFixture()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let recorder = ResourceWorkloadEventRecorder()

        let result = await fixture.useCase(
            dependencies,
            telemetry: ResourceWorkloadTelemetry(receiver: recorder.receive)
        ).execute(fixture.request())

        guard case .completed = result else {
            return XCTFail("fixture should complete")
        }
        assertRecordingCriticalWorkload(recorder.events)
    }

    func testRealStoreAdapterAtomicallyInstallsSnapshotAndInitialJob() async throws {
        let fixture = StopRecordingFixture()
        let store = try MeetingStore.inMemory()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let reservedAssets = fixture.assets
        try await store.beginRecording(fixture.shell, assets: reservedAssets)
        let useCase = StopRecording(
            audioFiles: dependencies,
            store: store,
            lifecycle: dependencies,
            now: { fixture.now })

        let result = await useCase.execute(fixture.request(assets: reservedAssets))

        guard case .completed = result else {
            if case .processingFailed(let failure, _) = result {
                return XCTFail("real Unit of Work failed: \(failure.code)")
            }
            return XCTFail("real Unit of Work should complete: \(result)")
        }
        let storedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(storedDetail)
        let assets = try await store.audioAssets(for: fixture.meetingID)
        let jobs = try await store.processingJobs(for: fixture.meetingID)
        XCTAssertEqual(detail.meeting.lifecycleState, .processing)
        XCTAssertEqual(detail.segments.count, fixture.captions.count)
        XCTAssertEqual(assets.map(\.healthStatus), [.missing, .healthy])
        XCTAssertEqual(jobs.map(\.kind), [.diarization])
        let state = await dependencies.state()
        XCTAssertEqual(state.kickCount, 1)
    }

    func testRealStoreDropsInvalidCompanionProvenanceWithoutLosingAudioOrTranscript() async throws {
        let fixture = StopRecordingFixture()
        let store = try MeetingStore.inMemory()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let reservedAssets = fixture.assets
        try await store.beginRecording(fixture.shell, assets: reservedAssets)
        let card = CompanionCard(
            question: "Is this optional payload valid?",
            answer: "No",
            kind: .context,
            source: "on-device",
            askedAt: 5)
        let invalidRun = GenerationRun(
            meetingID: fixture.meetingID,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "b", count: 64),
            configJSON: #"{"workflow":"wrong"}"#,
            outputLanguage: "en",
            startedAt: fixture.startedAt,
            finishedAt: fixture.now,
            outcome: .succeeded,
            metricsJSON: #"{"answerUTF8Bytes":2}"#)
        let useCase = StopRecording(
            audioFiles: dependencies,
            store: store,
            lifecycle: dependencies,
            now: { fixture.now })

        let result = await useCase.execute(fixture.request(
            assets: reservedAssets,
            companionArtifacts: [CompanionGenerationArtifact(
                card: card,
                generationRun: invalidRun)]))

        guard case .completed = result else {
            if case .processingFailed(let failure, let fallback) = result {
                return XCTFail(
                    "optional Companion rejection must degrade to the core capture; "
                        + "failure=\(failure.code), fallback=\(fallback != nil)")
            }
            return XCTFail("optional Companion rejection returned an unexpected outcome")
        }
        let loadedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(loadedDetail)
        let assets = try await store.audioAssets(for: fixture.meetingID)
        let jobs = try await store.processingJobs(for: fixture.meetingID)
        let cards = try await store.companionCards(for: fixture.meetingID)
        XCTAssertEqual(detail.meeting.lifecycleState, .processing)
        XCTAssertEqual(detail.segments.count, fixture.captions.count)
        XCTAssertEqual(cards.map(\.question), ["When?"])
        XCTAssertTrue(assets.contains { $0.healthStatus == .healthy })
        XCTAssertEqual(jobs.map(\.kind), [.diarization])
    }

    func testRealStoreDropsInvalidCompanionTerminalRunWithoutLosingCoreCapture() async throws {
        let fixture = StopRecordingFixture()
        let store = try MeetingStore.inMemory()
        let dependencies = StopRecordingDependencies(shell: fixture.shell)
        let reservedAssets = fixture.assets
        try await store.beginRecording(fixture.shell, assets: reservedAssets)
        let invalidRun = GenerationRun(
            meetingID: fixture.meetingID,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "c", count: 64),
            configJSON: #"{"workflow":"wrong"}"#,
            outputLanguage: "en",
            startedAt: fixture.startedAt,
            finishedAt: fixture.now,
            outcome: .failed)
        let useCase = StopRecording(
            audioFiles: dependencies,
            store: store,
            lifecycle: dependencies,
            now: { fixture.now })

        let result = await useCase.execute(fixture.request(
            assets: reservedAssets,
            companionTerminalRuns: [invalidRun]))

        guard case .completed = result else {
            if case .processingFailed(let failure, let fallback) = result {
                return XCTFail(
                    "invalid optional terminal provenance must degrade to the core capture; "
                        + "failure=\(failure.code), fallback=\(fallback != nil)")
            }
            return XCTFail("optional Companion rejection returned an unexpected outcome")
        }
        let loadedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(loadedDetail)
        let assets = try await store.audioAssets(for: fixture.meetingID)
        let jobs = try await store.processingJobs(for: fixture.meetingID)
        let runs = try await store.generationRuns(for: fixture.meetingID)
        let contextItems = try await store.contextItems(for: fixture.meetingID)
        XCTAssertEqual(detail.meeting.lifecycleState, .processing)
        XCTAssertEqual(detail.segments.count, fixture.captions.count)
        XCTAssertEqual(contextItems.map(\.content), ["Ship locally"])
        XCTAssertTrue(assets.contains { $0.healthStatus == .healthy })
        XCTAssertEqual(jobs.map(\.kind), [.diarization])
        XCTAssertTrue(runs.isEmpty)
    }
}

private struct StopRecordingFixture {
    let meetingID = MeetingID(rawValue: UUID(
        uuidString: "81818181-8181-8181-8181-818181818181")!)
    let startedAt = Date(timeIntervalSince1970: 1_783_695_600)
    let now = Date(timeIntervalSince1970: 1_783_695_660)

    var directory: String { "Audio/\(meetingID.rawValue.uuidString)" }
    var shell: Meeting {
        Meeting(
            id: meetingID,
            title: "Stop recording fixture",
            startedAt: startedAt,
            audioDirectory: directory,
            lifecycleState: .recording)
    }
    var assets: [AudioAsset] {
        [.system, .microphone].map { channel in
            AudioAsset.pendingCapture(
                meetingID: meetingID,
                channel: channel,
                relativePath: AudioCapturePath.stagingRelativePath(
                    directory: directory,
                    channel: channel),
                at: startedAt)
        }
    }
    var captions: [TranscriptSegment] {
        [
            segment(
                channel: .system,
                text: "Revisamos el lanzamiento local.",
                language: "es",
                start: 0),
            segment(
                channel: .microphone,
                text: "Yo prepararé la entrega.",
                language: "es",
                start: 2)
        ]
    }

    func segment(
        channel: AudioChannel,
        text: String,
        language: String,
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: text,
            language: language,
            startTime: start,
            endTime: start + 2,
            confidence: 0.95,
            isFinal: true)
    }

    func publishedFile(
        healthStatus: AudioAssetHealthStatus = .healthy
    ) -> StopRecordingPublishedFile {
        StopRecordingPublishedFile(
            container: "caf",
            codec: "pcm-s16le",
            sampleRate: 48_000,
            channelCount: 1,
            durationSeconds: 60,
            byteCount: 5_760_128,
            sha256: String(repeating: "a", count: 64),
            healthStatus: healthStatus,
            peakDBFS: -6,
            rmsDBFS: -18)
    }

    func request(
        shell: Meeting? = nil,
        includeShell: Bool = true,
        assets: [AudioAsset]? = nil,
        captions: [TranscriptSegment]? = nil,
        capture: StopRecordingCapture? = nil,
        companionArtifacts: [CompanionGenerationArtifact] = [],
        companionTerminalRuns: [GenerationRun] = []
    ) -> StopRecordingRequest {
        StopRecordingRequest(
            recordingShell: includeShell ? (shell ?? self.shell) : nil,
            reservedAssets: assets ?? self.assets,
            captions: captions ?? self.captions,
            contextItems: [ContextItem(
                meetingID: meetingID,
                kind: .note,
                content: "Ship locally",
                timestamp: 4)],
            companionCards: [CompanionCard(
                question: "When?",
                answer: "Tomorrow",
                kind: .context,
                source: "on-device",
                askedAt: 5)],
            companionArtifacts: companionArtifacts,
            companionTerminalRuns: companionTerminalRuns,
            capture: capture ?? StopRecordingCapture(
                publishedFiles: [.system: publishedFile()]),
            voiceprint: Voiceprint(embedding: [0.1, 0.2], createdAt: startedAt))
    }

    func useCase(
        _ dependencies: StopRecordingDependencies,
        telemetry: ResourceWorkloadTelemetry = .disabled
    ) -> StopRecording {
        StopRecording(
            audioFiles: dependencies,
            store: dependencies,
            lifecycle: dependencies,
            now: { now },
            telemetry: telemetry)
    }
}

private enum StopRecordingDependencyError: Error, LocalizedError {
    case discard
    case install
    case mark

    var errorDescription: String? { "Stop recording fixture dependency failed: \(self)" }
}

private actor StopRecordingDependencies:
    StopRecordingAudioFiles,
    StopRecordingStore,
    StopRecordingLifecycle {
    struct Install: Sendable {
        let snapshot: CapturedMeetingSnapshot
        let requests: [ProcessingJobRequest]
    }

    struct State: Sendable {
        let installs: [Install]
        let installAttempts: Int
        let markedErrorCode: String?
        let discardCount: Int
        let kickCount: Int
        let releaseCount: Int
        let events: [String]
    }

    private let shell: Meeting
    private let existingPaths: Set<String>
    private let discardResult: Bool
    private let discardError: StopRecordingDependencyError?
    private let markError: StopRecordingDependencyError?
    private var installFailuresRemaining: Int
    private var installs: [Install] = []
    private var installAttempts = 0
    private var markedErrorCode: String?
    private var discardCount = 0
    private var kickCount = 0
    private var releaseCount = 0
    private var events: [String] = []

    init(
        shell: Meeting,
        existingPaths: Set<String> = [],
        discardResult: Bool = true,
        discardError: StopRecordingDependencyError? = nil,
        markError: StopRecordingDependencyError? = nil,
        installFailuresRemaining: Int = 0
    ) {
        self.shell = shell
        self.existingPaths = existingPaths
        self.discardResult = discardResult
        self.discardError = discardError
        self.markError = markError
        self.installFailuresRemaining = installFailuresRemaining
    }

    func captureFileExists(relativePath: String) async -> Bool {
        existingPaths.contains(relativePath)
    }

    func discardUnstartedRecording(_ meetingID: MeetingID) async throws -> Bool {
        discardCount += 1
        events.append("discard")
        if let discardError { throw discardError }
        return discardResult
    }

    func markStoppedMeetingNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting {
        if let markError { throw markError }
        markedErrorCode = errorCode
        events.append("mark")
        var marked = shell
        marked.endedAt = endedAt
        marked.lifecycleState = .needsAttention
        marked.lastProcessingError = errorCode
        return marked
    }

    func installStoppedSnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        enqueue requests: [ProcessingJobRequest]
    ) async throws {
        installAttempts += 1
        events.append("install")
        if installFailuresRemaining > 0 {
            installFailuresRemaining -= 1
            throw StopRecordingDependencyError.install
        }
        installs.append(Install(snapshot: snapshot, requests: requests))
    }

    func kickPostCaptureProcessing() async {
        kickCount += 1
        events.append("kick")
    }

    func scheduleRecordingEngineRelease() async {
        releaseCount += 1
        events.append("release")
    }

    func state() -> State {
        State(
            installs: installs,
            installAttempts: installAttempts,
            markedErrorCode: markedErrorCode,
            discardCount: discardCount,
            kickCount: kickCount,
            releaseCount: releaseCount,
            events: events)
    }
}
