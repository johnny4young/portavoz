import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit
import TranscriptionKit
import XCTest

private let processPostCaptureNow = Date(timeIntervalSince1970: 1_784_337_600)

final class ProcessPostCaptureJobsUseCaseTests: XCTestCase {
    private var now: Date { processPostCaptureNow }

    func testTranscriptionOwnsFilteringAttributionFollowUpAndResourceRelease() async throws {
        let fixture = Fixture(now: now)
        let systemAsset = fixture.asset(channel: .system, sha256: "system-sha")
        let microphoneAsset = fixture.asset(channel: .microphone, sha256: "microphone-sha")
        let assets = [systemAsset, microphoneAsset]
        let fingerprint = try XCTUnwrap(InitialTranscriptionOperationFingerprint.compute(
            meetingID: fixture.meeting.id,
            transcriptRevision: fixture.meeting.transcriptRevision,
            assets: assets))
        let job = fixture.job(kind: .transcription, fingerprint: fingerprint)
        let system = fixture.segment(
            channel: .system, text: "Hello", language: "en", start: 0)
        let noise = fixture.segment(
            channel: .microphone, text: ".", language: "es", start: 1)
        let microphone = fixture.segment(
            channel: .microphone, text: "Gracias", language: "es", start: 2)
        let store = WorkflowStoreFake(
            jobs: [job],
            details: [fixture.meeting.id: fixture.detail()],
            assets: [fixture.meeting.id: assets])
        let capabilities = WorkflowCapabilitiesFake(
            transcriptions: [
                .system: fixture.transcription([system]),
                .microphone: fixture.transcription([noise, microphone])
            ])
        let events = EventRecorder()
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })

        let result = await workflow.execute(.init(owner: "test-owner") { event in
            await events.record(event)
        })

        XCTAssertEqual(result.processedJobCount, 1)
        XCTAssertTrue(result.durableStateChanged)
        XCTAssertTrue(result.issues.isEmpty)
        let storedPublication = await store.transcriptionPublication()
        let publication = try XCTUnwrap(storedPublication)
        XCTAssertEqual(publication.artifact.language, nil)
        XCTAssertEqual(publication.artifact.segments.map(\.text), ["Hello", "Gracias"])
        XCTAssertEqual(publication.artifact.segments.map(\.language), ["en", "es"])
        XCTAssertEqual(publication.followUps.count, 1)
        XCTAssertEqual(publication.followUps.first?.kind, .diarization)
        XCTAssertEqual(publication.followUps.first?.priority, 20)
        let channels = await capabilities.transcribedChannels()
        let releaseCount = await capabilities.releaseCount()
        let actions = await capabilities.actionMeetingIDs()
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(channels, [.system, .microphone])
        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(recordedEvents, [
            .started(kind: .transcription, attempt: 1),
            .finished(
                kind: .transcription,
                attempt: 1,
                outcome: .succeeded,
                durableStateChanged: true)
        ])
    }

    func testRealStoreDrainsDiarizationThenSummaryWithOneAtomicProvenanceChain() async throws {
        let fixture = Fixture(now: now)
        let store = try MeetingStore.inMemory()
        let speaker = Speaker(meetingID: fixture.meeting.id, label: "S1")
        let segment = fixture.segment(
            speakerID: speaker.id,
            channel: .system,
            text: "Conserva el idioma hablado.",
            language: "es",
            start: 0)
        try await store.save(fixture.meeting)
        try await store.save([speaker])
        try await store.save([segment])
        let request = try StopRecordingJobFactory.initialDiarizationRequest(
            meeting: fixture.meeting,
            segments: [segment],
            assets: [],
            voiceprint: nil)
        _ = try await store.enqueueProcessingJobs(
            for: fixture.meeting.id,
            requests: [request],
            at: now)
        let provider = RecordingSummaryProvider(providerID: "durable-test")
        let capabilities = WorkflowCapabilitiesFake(
            provider: PostCaptureSummaryProviderSelection(
                provider: provider,
                providerID: "durable-test",
                modelID: "test-model",
                modelRevision: "test-revision"),
            preferences: PostCaptureSummaryPreferences(
                outputLanguage: "es",
                vocabulary: ["Portavoz"]))
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })

        let result = await workflow.execute(.init(owner: "real-store-owner"))

        XCTAssertEqual(result.processedJobCount, 2)
        XCTAssertTrue(result.issues.isEmpty)
        let jobs = try await store.processingJobs(for: fixture.meeting.id)
        XCTAssertEqual(jobs.map(\.kind), [.diarization, .summary])
        XCTAssertEqual(jobs.map(\.state), [.succeeded, .succeeded])
        let storedSummary = try await store.summary(fixture.meeting.id)
        let summary = try XCTUnwrap(storedSummary)
        XCTAssertEqual(summary.draft.language, "es")
        XCTAssertEqual(summary.draft.markdown, "Summary in es")
        let runs = try await store.generationRuns(for: fixture.meeting.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.providerID, "durable-test")
        XCTAssertEqual(runs.first?.outcome, .succeeded)
        XCTAssertTrue(runs.first?.configJSON.contains("\"workflow\":\"post-capture\"") == true)
        let providerRequests = await provider.requests()
        XCTAssertEqual(providerRequests.count, 1)
        XCTAssertEqual(providerRequests.first?.targetLanguage, "es")
        XCTAssertEqual(providerRequests.first?.glossary, ["Portavoz"])
        XCTAssertEqual(providerRequests.first?.segments.map(\.language), ["es"])
        let actionIDs = await capabilities.actionMeetingIDs()
        let releaseCount = await capabilities.releaseCount()
        XCTAssertEqual(actionIDs, [fixture.meeting.id])
        XCTAssertEqual(releaseCount, 1)
    }

    func testUnavailableSummaryRetriesAfterFiveSecondsWithoutInventingProvenance() async throws {
        let fixture = Fixture(now: now)
        let segment = fixture.segment(
            channel: .system, text: "Ready", language: "en", start: 0)
        let job = fixture.job(kind: .summary, fingerprint: "stale-unread", attempt: 1)
        let store = WorkflowStoreFake(
            jobs: [job],
            details: [fixture.meeting.id: fixture.detail(segments: [segment])])
        let capabilities = WorkflowCapabilitiesFake()
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })

        let result = await workflow.execute(.init(owner: "test-owner"))

        XCTAssertEqual(result.processedJobCount, 1)
        XCTAssertTrue(result.durableStateChanged)
        let failures = await store.failureRecords()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.failure.code, "processing.summary.failed")
        XCTAssertEqual(failures.first?.retryAt, now.addingTimeInterval(5))
        let runs = await store.generationRuns()
        let actions = await capabilities.actionMeetingIDs()
        XCTAssertTrue(runs.isEmpty)
        XCTAssertTrue(actions.isEmpty)
    }

    func testExhaustedOptionalSummaryCancelsAndRunsPostMeetingAction() async throws {
        let fixture = Fixture(now: now)
        let segment = fixture.segment(
            channel: .system, text: "Ready", language: "en", start: 0)
        let job = fixture.job(
            kind: .summary,
            fingerprint: "provider-unavailable",
            attempt: 3,
            maxAttempts: 3)
        let store = WorkflowStoreFake(
            jobs: [job],
            details: [fixture.meeting.id: fixture.detail(segments: [segment])])
        let capabilities = WorkflowCapabilitiesFake()
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })

        let result = await workflow.execute(.init(owner: "test-owner"))

        XCTAssertEqual(result.processedJobCount, 1)
        let cancellations = await store.cancellationRecords()
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertEqual(cancellations.first?.reason.code, "processing.summary.unavailable")
        let actions = await capabilities.actionMeetingIDs()
        XCTAssertEqual(actions, [fixture.meeting.id])
    }

    func testSupersededSummaryCancelsWithoutCallingProviderAndRunsAction() async throws {
        let fixture = Fixture(now: now)
        let segment = fixture.segment(
            channel: .system, text: "Current", language: "en", start: 0)
        let provider = RecordingSummaryProvider(providerID: "durable-test")
        let job = fixture.job(kind: .summary, fingerprint: "superseded-fingerprint")
        let store = WorkflowStoreFake(
            jobs: [job],
            details: [fixture.meeting.id: fixture.detail(segments: [segment])])
        let capabilities = WorkflowCapabilitiesFake(provider: PostCaptureSummaryProviderSelection(
            provider: provider,
            providerID: "durable-test",
            modelID: "test-model",
            modelRevision: nil))
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })

        _ = await workflow.execute(.init(owner: "test-owner"))

        let cancellations = await store.cancellationRecords()
        XCTAssertEqual(cancellations.first?.reason.code, "processing.input.superseded")
        let providerRequests = await provider.requests()
        let runs = await store.generationRuns()
        let actions = await capabilities.actionMeetingIDs()
        XCTAssertTrue(providerRequests.isEmpty)
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(actions, [fixture.meeting.id])
    }

    func testSummaryPublicationLeaseLossRecordsCancelledAttemptWithoutFalseStateChange() async throws {
        let fixture = Fixture(now: now)
        let segment = fixture.segment(
            channel: .system, text: "Current", language: "en", start: 0)
        let provider = RecordingSummaryProvider(providerID: "durable-test")
        let summaryRequest = SummaryRequest(
            meetingID: fixture.meeting.id,
            segments: [segment],
            speakers: [],
            recipe: .general,
            targetLanguage: "en")
        let fingerprint = SummaryOperationFingerprint.compute(
            request: summaryRequest,
            providerID: "durable-test",
            transcriptRevision: fixture.meeting.transcriptRevision)
        let job = fixture.job(kind: .summary, fingerprint: fingerprint)
        let store = WorkflowStoreFake(
            jobs: [job],
            details: [fixture.meeting.id: fixture.detail(segments: [segment])],
            summaryPublicationError: .leaseLost(job.id))
        let capabilities = WorkflowCapabilitiesFake(provider: PostCaptureSummaryProviderSelection(
            provider: provider,
            providerID: "durable-test",
            modelID: "test-model",
            modelRevision: nil))
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })

        let result = await workflow.execute(.init(owner: "test-owner"))

        XCTAssertEqual(result.processedJobCount, 1)
        XCTAssertFalse(result.durableStateChanged)
        let runs = await store.generationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.outcome, .cancelled)
        let failures = await store.failureRecords()
        let cancellations = await store.cancellationRecords()
        let actions = await capabilities.actionMeetingIDs()
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertTrue(actions.isEmpty)
    }

    func testClaimAndFailurePreservationErrorsRemainTypedDiagnosticIssues() async throws {
        let fixture = Fixture(now: now)
        let claimStore = WorkflowStoreFake(claimError: .claimFailed)
        let capabilities = WorkflowCapabilitiesFake()
        let claimWorkflow = ProcessPostCaptureJobs(
            store: claimStore,
            capabilities: capabilities,
            now: { processPostCaptureNow })
        let claim = await claimWorkflow.execute(.init(owner: "test-owner"))
        XCTAssertEqual(claim.processedJobCount, 0)
        XCTAssertEqual(claim.issues.first?.stage, .claim)

        let job = fixture.job(kind: .summary, fingerprint: "unavailable")
        let segment = fixture.segment(
            channel: .system, text: "Current", language: "en", start: 0)
        let preservationStore = WorkflowStoreFake(
            jobs: [job],
            details: [fixture.meeting.id: fixture.detail(segments: [segment])],
            failurePreservationError: .preservationFailed)
        let preservationWorkflow = ProcessPostCaptureJobs(
            store: preservationStore,
            capabilities: capabilities,
            heartbeatInterval: .seconds(3_600),
            now: { processPostCaptureNow })
        let preservation = await preservationWorkflow.execute(.init(owner: "test-owner"))
        XCTAssertEqual(
            preservation.issues.first?.stage,
            .failurePreservation(.summary))
        XCTAssertFalse(preservation.durableStateChanged)
    }

    func testNextScheduledDateUsesSupportedKindsAndInjectedClock() async throws {
        let scheduled = now.addingTimeInterval(30)
        let store = WorkflowStoreFake(nextScheduledDate: scheduled)
        let workflow = ProcessPostCaptureJobs(
            store: store,
            capabilities: WorkflowCapabilitiesFake(),
            now: { processPostCaptureNow })

        let result = try await workflow.nextScheduledDate()

        XCTAssertEqual(result, scheduled)
        let request = await store.schedulingRequest()
        XCTAssertEqual(request?.kinds, ProcessPostCaptureJobs.supportedKinds)
        XCTAssertEqual(request?.after, now)
    }
}

private struct Fixture {
    let now: Date
    let meeting: Meeting

    init(now: Date) {
        self.now = now
        meeting = Meeting(
            title: "Durable workflow",
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            lifecycleState: .captured)
    }

    func detail(
        speakers: [Speaker] = [],
        segments: [TranscriptSegment] = []
    ) -> MeetingDetail {
        MeetingDetail(
            meeting: meeting,
            speakers: speakers,
            segments: segments,
            summaries: [])
    }

    func asset(channel: AudioChannel, sha256: String) -> AudioAsset {
        AudioAsset(
            meetingID: meeting.id,
            channel: channel,
            role: .capture,
            relativePath: "Audio/\(meeting.id.rawValue.uuidString)/\(channel.rawValue).caf",
            container: "caf",
            codec: "pcm",
            sampleRate: 16_000,
            channelCount: 1,
            durationSeconds: 30,
            byteCount: 960_000,
            sha256: sha256,
            healthStatus: .healthy,
            createdAt: now)
    }

    func segment(
        speakerID: SpeakerID? = nil,
        channel: AudioChannel,
        text: String,
        language: String,
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speakerID,
            channel: channel,
            text: text,
            language: language,
            startTime: start,
            endTime: start + 0.8,
            confidence: 0.95,
            isFinal: true)
    }

    func transcription(_ segments: [TranscriptSegment]) -> FileTranscription {
        FileTranscription(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            audioDuration: 30,
            processingTime: 1)
    }

    func job(
        kind: ProcessingJobKind,
        fingerprint: String,
        attempt: Int = 1,
        maxAttempts: Int = 3
    ) -> ProcessingJob {
        ProcessingJob(
            meetingID: meeting.id,
            kind: kind,
            inputFingerprint: fingerprint,
            state: .running,
            attempt: attempt,
            maxAttempts: maxAttempts,
            leaseOwner: "test-owner",
            leaseExpiresAt: now.addingTimeInterval(120),
            createdAt: now,
            startedAt: now,
            updatedAt: now)
    }
}

private enum WorkflowFakeError: Error, LocalizedError, Sendable {
    case claimFailed
    case preservationFailed

    var errorDescription: String? {
        switch self {
        case .claimFailed: "claim failed"
        case .preservationFailed: "failure preservation failed"
        }
    }
}

private enum SummaryPublicationError: Sendable {
    case leaseLost(ProcessingJobID)
}

private struct TranscriptionPublication: Sendable {
    let artifact: TranscriptionArtifact
    let followUps: [ProcessingJobRequest]
}

private struct FailureRecord: Sendable {
    let failure: ProcessingJobFailure
    let retryAt: Date?
}

private struct CancellationRecord: Sendable {
    let reason: ProcessingJobFailure
}

private struct SchedulingRequest: Sendable {
    let kinds: Set<ProcessingJobKind>
    let after: Date
}

private actor WorkflowStoreFake: PostCaptureProcessingStore {
    private var jobs: [ProcessingJob]
    private let details: [MeetingID: MeetingDetail]
    private let assets: [MeetingID: [AudioAsset]]
    private let claimError: WorkflowFakeError?
    private let summaryPublicationError: SummaryPublicationError?
    private let failurePreservationError: WorkflowFakeError?
    private let nextScheduledDate: Date?
    private var claimed: [ProcessingJobID: ProcessingJob] = [:]
    private var publishedTranscription: TranscriptionPublication?
    private var runs: [GenerationRun] = []
    private var failures: [FailureRecord] = []
    private var cancellations: [CancellationRecord] = []
    private var scheduledRequest: SchedulingRequest?

    init(
        jobs: [ProcessingJob] = [],
        details: [MeetingID: MeetingDetail] = [:],
        assets: [MeetingID: [AudioAsset]] = [:],
        claimError: WorkflowFakeError? = nil,
        summaryPublicationError: SummaryPublicationError? = nil,
        failurePreservationError: WorkflowFakeError? = nil,
        nextScheduledDate: Date? = nil
    ) {
        self.jobs = jobs
        self.details = details
        self.assets = assets
        self.claimError = claimError
        self.summaryPublicationError = summaryPublicationError
        self.failurePreservationError = failurePreservationError
        self.nextScheduledDate = nextScheduledDate
    }

    func claimPostCaptureJob(
        kinds: Set<ProcessingJobKind>,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) throws -> ProcessingJob? {
        if let claimError { throw claimError }
        guard !jobs.isEmpty else { return nil }
        let job = jobs.removeFirst()
        claimed[job.id] = job
        return job
    }

    func heartbeatPostCaptureJob(
        _ id: ProcessingJobID,
        owner: String,
        progress: Double,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) {}

    func postCaptureDetail(_ meetingID: MeetingID) -> MeetingDetail? {
        details[meetingID]
    }

    func postCaptureAudioAssets(_ meetingID: MeetingID) -> [AudioAsset] {
        assets[meetingID] ?? []
    }

    func postCaptureContextItems(_ meetingID: MeetingID) -> [ContextItem] { [] }

    func publishPostCaptureTranscription(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: TranscriptionArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) -> ProcessingArtifactCommit {
        publishedTranscription = TranscriptionPublication(
            artifact: artifact,
            followUps: followUps)
        return commit(jobID: jobID, meetingID: artifact.meetingID, followUps: followUps)
    }

    func publishPostCaptureDiarization(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: DiarizationArtifact,
        followUps: [ProcessingJobRequest],
        at timestamp: Date
    ) -> ProcessingArtifactCommit {
        commit(jobID: jobID, meetingID: artifact.meetingID, followUps: followUps)
    }

    func publishPostCaptureSummary(
        _ jobID: ProcessingJobID,
        owner: String,
        artifact: SummaryArtifact,
        at timestamp: Date
    ) throws {
        if case .leaseLost(let id) = summaryPublicationError {
            throw StorageError.processingJobLeaseLost(id)
        }
    }

    func savePostCaptureGenerationRun(_ run: GenerationRun) {
        runs.append(run)
    }

    func failPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        failure: ProcessingJobFailure,
        retryAt: Date?,
        at timestamp: Date
    ) throws {
        if let failurePreservationError { throw failurePreservationError }
        failures.append(FailureRecord(failure: failure, retryAt: retryAt))
    }

    func cancelPostCaptureJob(
        _ jobID: ProcessingJobID,
        owner: String,
        reason: ProcessingJobFailure,
        at timestamp: Date
    ) throws {
        if let failurePreservationError { throw failurePreservationError }
        cancellations.append(CancellationRecord(reason: reason))
    }

    func nextPostCaptureProcessingDate(
        kinds: Set<ProcessingJobKind>,
        after timestamp: Date
    ) -> Date? {
        scheduledRequest = SchedulingRequest(kinds: kinds, after: timestamp)
        return nextScheduledDate
    }

    func transcriptionPublication() -> TranscriptionPublication? { publishedTranscription }
    func generationRuns() -> [GenerationRun] { runs }
    func failureRecords() -> [FailureRecord] { failures }
    func cancellationRecords() -> [CancellationRecord] { cancellations }
    func schedulingRequest() -> SchedulingRequest? { scheduledRequest }

    private func commit(
        jobID: ProcessingJobID,
        meetingID: MeetingID,
        followUps: [ProcessingJobRequest]
    ) -> ProcessingArtifactCommit {
        let completed = claimed[jobID] ?? ProcessingJob(
            id: jobID,
            meetingID: meetingID,
            kind: .diarization,
            inputFingerprint: "fixture")
        let enqueued = followUps.map {
            ProcessingJob(
                meetingID: meetingID,
                kind: $0.kind,
                inputFingerprint: $0.inputFingerprint,
                priority: $0.priority,
                maxAttempts: $0.maxAttempts,
                notBefore: $0.notBefore)
        }
        return ProcessingArtifactCommit(
            completedJob: completed,
            enqueuedJobs: enqueued,
            artifactVersion: 1)
    }
}

private actor WorkflowCapabilitiesFake:
    PostCaptureAudioProcessing,
    PostCaptureSummaryConfiguration,
    PostCaptureCompletionActions {
    private let transcriptions: [AudioChannel: FileTranscription]
    private let provider: PostCaptureSummaryProviderSelection?
    private let preferences: PostCaptureSummaryPreferences
    private var channels: [AudioChannel] = []
    private var actions: [MeetingID] = []
    private var releases = 0

    init(
        transcriptions: [AudioChannel: FileTranscription] = [:],
        provider: PostCaptureSummaryProviderSelection? = nil,
        preferences: PostCaptureSummaryPreferences = PostCaptureSummaryPreferences(
            outputLanguage: "en",
            vocabulary: [])
    ) {
        self.transcriptions = transcriptions
        self.provider = provider
        self.preferences = preferences
    }

    func transcribePostCaptureAudio(
        _ asset: AudioAsset,
        channel: AudioChannel,
        hints: TranscriptionHints
    ) throws -> FileTranscription {
        channels.append(channel)
        guard let result = transcriptions[channel] else {
            throw PostCaptureProcessingCapabilityError.audioUnavailable
        }
        return result
    }

    func currentPostCaptureVoiceprint() -> Voiceprint? { nil }
    func diarizePostCaptureAudio(_ asset: AudioAsset) -> [SpeakerTurn] { [] }
    func postCaptureSummaryProvider() -> PostCaptureSummaryProviderSelection? { provider }

    func postCaptureSummaryPreferences(
        spokenLanguage: String?
    ) -> PostCaptureSummaryPreferences {
        preferences
    }

    func runPostMeetingAction(for meetingID: MeetingID) {
        actions.append(meetingID)
    }

    func schedulePostCaptureIdleRelease() {
        releases += 1
    }

    func transcribedChannels() -> [AudioChannel] { channels }
    func actionMeetingIDs() -> [MeetingID] { actions }
    func releaseCount() -> Int { releases }
}

private actor RecordingSummaryProvider: SummaryProvider {
    private let providerID: String
    private var recorded: [SummaryRequest] = []

    init(providerID: String) {
        self.providerID = providerID
    }

    func summarize(_ request: SummaryRequest) -> SummaryDraft {
        recorded.append(request)
        return SummaryDraft(
            meetingID: request.meetingID,
            recipeID: request.recipe.id,
            language: request.targetLanguage,
            markdown: "Summary in \(request.targetLanguage)",
            actionItems: [],
            fingerprint: SummaryFingerprint.compute(
                request: request,
                providerID: providerID))
    }

    func requests() -> [SummaryRequest] { recorded }
}

private actor EventRecorder {
    private var events: [PostCaptureProcessingEvent] = []

    func record(_ event: PostCaptureProcessingEvent) {
        events.append(event)
    }

    func snapshot() -> [PostCaptureProcessingEvent] { events }
}
