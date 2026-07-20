import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class ProcessingJobPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_699_200)

    private func meeting(
        id: MeetingID = MeetingID(),
        lifecycle: MeetingLifecycleState = .captured
    ) -> Meeting {
        Meeting(
            id: id,
            title: "Durable processing",
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            audioDirectory: "Audio/\(id.rawValue.uuidString)",
            lifecycleState: lifecycle)
    }

    private func detail(
        _ meetingID: MeetingID,
        in store: MeetingStore
    ) async throws -> MeetingDetail {
        let loaded = try await store.detail(meetingID)
        return try XCTUnwrap(loaded)
    }

    private func seedCast(
        for meetingID: MeetingID,
        in store: MeetingStore
    ) async throws -> (speaker: Speaker, segment: TranscriptSegment) {
        let speaker = Speaker(meetingID: meetingID, label: "Them")
        let segment = TranscriptSegment(
            meetingID: meetingID,
            speakerID: speaker.id,
            channel: .system,
            text: "provisional transcript",
            language: "en",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        try await store.save([speaker])
        try await store.save([segment])
        return (speaker, segment)
    }

    private func summaryRun(
        meetingID: MeetingID,
        inputFingerprint: String,
        language: String = "es",
        id: GenerationRunID = GenerationRunID()
    ) -> GenerationRun {
        GenerationRun(
            id: id,
            meetingID: meetingID,
            kind: .summary,
            providerID: "durable-test",
            modelID: "test-model",
            modelRevision: "test-revision",
            inputFingerprint: inputFingerprint,
            configJSON: "{}",
            outputLanguage: language,
            startedAt: now,
            finishedAt: now.addingTimeInterval(0.5),
            outcome: .succeeded,
            metricsJSON: "{}")
    }

    func testEnqueueIsAtomicIdempotentAndAdvancesMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let requests = [
            ProcessingJobRequest(
                kind: .diarization, inputFingerprint: "audio-sha-1", priority: 20),
            ProcessingJobRequest(
                kind: .summary, inputFingerprint: "transcript-revision-0", priority: 10),
        ]

        let first = try await store.enqueueProcessingJobs(
            for: captured.id, requests: requests, at: now)
        let second = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [
                ProcessingJobRequest(
                    kind: .diarization, inputFingerprint: "audio-sha-1", priority: -100),
                requests[1],
            ],
            at: now.addingTimeInterval(5))

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(second.map(\.priority), [20, 10])
        XCTAssertTrue(first.allSatisfy { $0.state == .pending && $0.attempt == 0 })
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.map(\.id), first.map(\.id))
        let storedDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(storedDetail.meeting.lifecycleState, .processing)
        XCTAssertNil(storedDetail.meeting.lastProcessingError)
    }

    func testEnqueueRejectsInvalidBatchBeforeWriting() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let duplicate = ProcessingJobRequest(
            kind: .summary, inputFingerprint: "transcript-revision-0")

        do {
            _ = try await store.enqueueProcessingJobs(
                for: captured.id,
                requests: [duplicate, duplicate],
                at: now)
            XCTFail("duplicate idempotency keys must be rejected")
        } catch {
            guard case StorageError.invalidProcessingJob = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let capturedJobs = try await store.processingJobs(for: captured.id)
        XCTAssertTrue(capturedJobs.isEmpty)
        let capturedDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(capturedDetail.meeting.lifecycleState, .captured)

        let recording = meeting(lifecycle: .recording)
        try await store.save(recording)
        do {
            _ = try await store.enqueueProcessingJobs(
                for: recording.id, requests: [duplicate], at: now)
            XCTFail("capture must be installed before enqueue")
        } catch {
            guard case StorageError.invalidProcessingJob = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let recordingJobs = try await store.processingJobs(for: recording.id)
        XCTAssertTrue(recordingJobs.isEmpty)
    }

    func testManualRetryResetsOnlyFailedJobsAndRestoresProcessingLifecycle() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(
                kind: .transcription,
                inputFingerprint: "retry-fingerprint",
                maxAttempts: 1)],
            at: now)
        let claimedValue = try await store.claimNextProcessingJob(
            kinds: [.transcription],
            owner: "worker-a",
            leaseDuration: 30,
            at: now)
        let claimed = try XCTUnwrap(claimedValue)
        _ = try await store.failProcessingJob(
            claimed.id,
            owner: "worker-a",
            failure: ProcessingJobFailure(
                code: "processing.transcription.failed",
                message: "/private/customer/audio.caf"),
            at: now.addingTimeInterval(1))

        let failed = try await detail(captured.id, in: store)
        XCTAssertEqual(failed.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(failed.meeting.lastProcessingError, "processing.transcription.failed")

        let retried = try await store.retryFailedProcessingJobs(
            for: captured.id,
            at: now.addingTimeInterval(2))
        let job = try XCTUnwrap(retried.first)
        XCTAssertEqual(retried.count, 1)
        XCTAssertEqual(job.id, claimed.id)
        XCTAssertEqual(job.state, .pending)
        XCTAssertEqual(job.attempt, 0)
        XCTAssertEqual(job.notBefore, now.addingTimeInterval(2))
        XCTAssertNil(job.errorCode)
        XCTAssertNil(job.errorMessage)
        XCTAssertNil(job.startedAt)
        XCTAssertNil(job.finishedAt)

        let processing = try await detail(captured.id, in: store)
        XCTAssertEqual(processing.meeting.lifecycleState, .processing)
        XCTAssertNil(processing.meeting.lastProcessingError)
        let secondRetry = try await store.retryFailedProcessingJobs(
            for: captured.id,
            at: now.addingTimeInterval(3))
        XCTAssertEqual(secondRetry.count, 0)
    }

    func testLeaseClaimHeartbeatAndCompletionAreOwnerBound() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let cleanup = ProcessingJobKind(rawValue: "cleanup")
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [
                ProcessingJobRequest(
                    kind: cleanup, inputFingerprint: "cleanup-0", priority: 10),
                ProcessingJobRequest(
                    kind: .index, inputFingerprint: "index-0", priority: 1),
            ],
            at: now)

        let firstClaimValue = try await store.claimNextProcessingJob(
            kinds: [cleanup, .index], owner: "worker-a", leaseDuration: 30, at: now)
        let firstClaim = try XCTUnwrap(firstClaimValue)
        XCTAssertEqual(firstClaim.kind, cleanup)
        XCTAssertEqual(firstClaim.state, .running)
        XCTAssertEqual(firstClaim.attempt, 1)

        do {
            _ = try await store.heartbeatProcessingJob(
                firstClaim.id,
                owner: "worker-b",
                progress: 0.4,
                leaseDuration: 30,
                at: now.addingTimeInterval(1))
            XCTFail("another worker cannot mutate the lease")
        } catch {
            guard case StorageError.processingJobLeaseLost(let id) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(id, firstClaim.id)
        }

        let heartbeat = try await store.heartbeatProcessingJob(
            firstClaim.id,
            owner: "worker-a",
            progress: 0.4,
            leaseDuration: 60,
            at: now.addingTimeInterval(1))
        XCTAssertEqual(heartbeat.progress, 0.4)
        XCTAssertEqual(heartbeat.leaseExpiresAt, now.addingTimeInterval(61))

        let secondClaimValue = try await store.claimNextProcessingJob(
            kinds: [cleanup, .index], owner: "worker-b", leaseDuration: 30, at: now)
        let secondClaim = try XCTUnwrap(secondClaimValue)
        XCTAssertEqual(secondClaim.kind, .index)
        _ = try await store.completeProcessingJob(
            firstClaim.id, owner: "worker-a", at: now.addingTimeInterval(2))
        let processingDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(processingDetail.meeting.lifecycleState, .processing)

        _ = try await store.completeProcessingJob(
            secondClaim.id, owner: "worker-b", at: now.addingTimeInterval(2))
        let readyDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(readyDetail.meeting.lifecycleState, .ready)
        XCTAssertNil(readyDetail.meeting.lastProcessingError)
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertTrue(jobs.allSatisfy { $0.state == .succeeded && $0.progress == 1 })
    }

    func testGeneratedJobCannotCompleteWithoutItsArtifact() async throws {
        for kind in [ProcessingJobKind.transcription, .summary] {
            let store = try MeetingStore.inMemory()
            let captured = meeting()
            try await store.save(captured)
            _ = try await store.enqueueProcessingJobs(
                for: captured.id,
                requests: [ProcessingJobRequest(
                    kind: kind,
                    inputFingerprint: "\(kind.rawValue):required-artifact")],
                at: now)
            let claimValue = try await store.claimNextProcessingJob(
                kinds: [kind], owner: "worker-a", leaseDuration: 30, at: now)
            let claim = try XCTUnwrap(claimValue)

            do {
                _ = try await store.completeProcessingJob(
                    claim.id, owner: "worker-a", at: now.addingTimeInterval(1))
                XCTFail("\(kind.rawValue) cannot succeed without its artifact")
            } catch StorageError.invalidProcessingJob(let reason) {
                XCTAssertTrue(reason.contains("artifact completion"))
            }
            let jobs = try await store.processingJobs(for: captured.id)
            XCTAssertEqual(jobs.first?.state, .running)
            XCTAssertEqual(jobs.first?.leaseOwner, "worker-a")
        }
    }

    func testTranscriptionCompletionPublishesRevisionAndDiarizationAtomically() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let fingerprint = "transcription:audio-sha:revision-0"
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(
                kind: .transcription,
                inputFingerprint: fingerprint,
                priority: 30)],
            at: now)
        let claimValue = try await store.claimNextProcessingJob(
            kinds: [.transcription],
            owner: "worker-a",
            leaseDuration: 30,
            at: now)
        let claim = try XCTUnwrap(claimValue)
        let speaker = Speaker(meetingID: captured.id, label: "Them")
        let segment = TranscriptSegment(
            meetingID: captured.id,
            speakerID: speaker.id,
            channel: .system,
            text: "La transcripción se recuperó desde el audio.",
            language: "es",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        let diarization = ProcessingJobRequest(
            kind: .diarization,
            inputFingerprint: "diarization:recovered-revision-1",
            priority: 20)

        let commit = try await store.completeTranscriptionJob(
            claim.id,
            owner: "worker-a",
            artifact: TranscriptionArtifact(
                meetingID: captured.id,
                inputFingerprint: fingerprint,
                sourceTranscriptRevision: 0,
                language: "es",
                speakers: [speaker],
                segments: [segment]),
            enqueue: [diarization],
            at: now.addingTimeInterval(2))

        XCTAssertEqual(commit.artifactVersion, 1)
        XCTAssertEqual(commit.completedJob.state, .succeeded)
        XCTAssertEqual(commit.enqueuedJobs.map(\.kind), [.diarization])
        let stored = try await detail(captured.id, in: store)
        XCTAssertEqual(stored.meeting.transcriptRevision, 1)
        XCTAssertEqual(stored.meeting.language, "es")
        XCTAssertEqual(stored.segments.map(\.text), [segment.text])
        XCTAssertEqual(stored.speakers.map(\.label), ["Them"])
        XCTAssertEqual(stored.meeting.lifecycleState, .processing)
    }

    func testDiarizationCompletionPublishesRevisionAndFollowUpAtomically() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let provisional = try await seedCast(for: captured.id, in: store)
        let fingerprint = "diarization:audio-sha-1:revision-0"
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(
                kind: .diarization, inputFingerprint: fingerprint)],
            at: now)
        let claimValue = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker-a", leaseDuration: 30, at: now)
        let claim = try XCTUnwrap(claimValue)

        let remote = Speaker(meetingID: captured.id, label: "S1", displayName: "Ana")
        var attributed = provisional.segment
        attributed.speakerID = remote.id
        attributed.text = "transcripción atribuida"
        attributed.language = "es"
        let commit = try await store.completeDiarizationJob(
            claim.id,
            owner: "worker-a",
            artifact: DiarizationArtifact(
                meetingID: captured.id,
                inputFingerprint: fingerprint,
                sourceTranscriptRevision: 0,
                language: "es",
                speakers: [remote],
                segments: [attributed]),
            enqueue: [ProcessingJobRequest(
                kind: .summary,
                inputFingerprint: "summary:material-1:es")],
            at: now.addingTimeInterval(1))

        XCTAssertEqual(commit.completedJob.state, .succeeded)
        XCTAssertEqual(commit.artifactVersion, 1)
        XCTAssertEqual(commit.enqueuedJobs.map(\.kind), [.summary])
        let stored = try await detail(captured.id, in: store)
        XCTAssertEqual(stored.meeting.transcriptRevision, 1)
        XCTAssertEqual(stored.meeting.language, "es")
        XCTAssertEqual(stored.meeting.lifecycleState, .processing)
        XCTAssertEqual(stored.speakers.map(\.label), ["S1"])
        XCTAssertEqual(stored.segments.map(\.text), ["transcripción atribuida"])
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertEqual(jobs.map(\.state), [.succeeded, .pending])
    }

    func testDiarizationCompletionRollsBackArtifactWhenJobCommitFails() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let provisional = try await seedCast(for: captured.id, in: store)
        let fingerprint = "diarization:rollback"
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(
                kind: .diarization, inputFingerprint: fingerprint)],
            at: now)
        let claimValue = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker-a", leaseDuration: 30, at: now)
        let claim = try XCTUnwrap(claimValue)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_processing_completion
                BEFORE UPDATE OF state ON processingJob
                WHEN NEW.state = 'succeeded'
                BEGIN
                    SELECT RAISE(ABORT, 'forced completion failure');
                END
                """)
        }

        let replacement = Speaker(meetingID: captured.id, label: "S1")
        var attributed = provisional.segment
        attributed.speakerID = replacement.id
        attributed.text = "must roll back"
        do {
            _ = try await store.completeDiarizationJob(
                claim.id,
                owner: "worker-a",
                artifact: DiarizationArtifact(
                    meetingID: captured.id,
                    inputFingerprint: fingerprint,
                    sourceTranscriptRevision: 0,
                    language: "en",
                    speakers: [replacement],
                    segments: [attributed]),
                at: now.addingTimeInterval(1))
            XCTFail("the injected job failure must abort the Unit of Work")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("forced completion failure"))
        }

        let stored = try await detail(captured.id, in: store)
        XCTAssertEqual(stored.meeting.transcriptRevision, 0)
        XCTAssertEqual(stored.speakers.map(\.id), [provisional.speaker.id])
        XCTAssertEqual(stored.segments.map(\.text), ["provisional transcript"])
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertEqual(jobs.first?.state, .running)
        XCTAssertEqual(jobs.first?.leaseOwner, "worker-a")
    }

    func testSummaryCompletionRejectsChangedTranscriptWithoutWriting() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        _ = try await seedCast(for: captured.id, in: store)
        let fingerprint = "summary:material-1:es"
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(kind: .summary, inputFingerprint: fingerprint)],
            at: now)
        let claimValue = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-a", leaseDuration: 30, at: now)
        let claim = try XCTUnwrap(claimValue)
        var changed = try await detail(captured.id, in: store).meeting
        changed.transcriptRevision = 1
        try await store.save(changed)

        do {
            _ = try await store.completeSummaryJob(
                claim.id,
                owner: "worker-a",
                artifact: SummaryArtifact(
                    inputFingerprint: fingerprint,
                    sourceTranscriptRevision: 0,
                    draft: SummaryDraft(
                        meetingID: captured.id,
                        recipeID: Recipe.general.id,
                        language: "es",
                        markdown: "# Resumen",
                        actionItems: [],
                        fingerprint: "material-1"),
                    generationRun: summaryRun(
                        meetingID: captured.id,
                        inputFingerprint: fingerprint)),
                at: now.addingTimeInterval(1))
            XCTFail("a stale transcript revision must reject the artifact")
        } catch StorageError.processingJobInputChanged(let id) {
            XCTAssertEqual(id, claim.id)
        }

        let absentSummary = try await store.summary(captured.id)
        let absentRuns = try await store.generationRuns(for: captured.id)
        XCTAssertNil(absentSummary)
        XCTAssertTrue(absentRuns.isEmpty)
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertEqual(jobs.first?.state, .running)
    }

    func testSummaryCompletionWritesOneImmutableVersionWithJob() async throws {
        let store = try MeetingStore.inMemory()
        var captured = meeting()
        captured.transcriptRevision = 2
        try await store.save(captured)
        let cast = try await seedCast(for: captured.id, in: store)
        let fingerprint = "summary:material-2:es"
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(kind: .summary, inputFingerprint: fingerprint)],
            at: now)
        let claimValue = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-a", leaseDuration: 30, at: now)
        let claim = try XCTUnwrap(claimValue)
        let draft = SummaryDraft(
            meetingID: captured.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "# Resumen durable",
            actionItems: [ActionItem(text: "Enviar plan", ownerSpeakerID: cast.speaker.id)],
            fingerprint: "material-2")
        do {
            _ = try await store.completeSummaryJob(
                claim.id,
                owner: "worker-a",
                artifact: SummaryArtifact(
                    inputFingerprint: fingerprint,
                    sourceTranscriptRevision: 2,
                    draft: draft,
                    generationRun: summaryRun(
                        meetingID: captured.id,
                        inputFingerprint: "another-operation")),
                at: now.addingTimeInterval(0.75))
            XCTFail("the run must carry the exact job operation fingerprint")
        } catch StorageError.invalidProcessingJob(let reason) {
            XCTAssertTrue(reason.contains("canonical identity"))
        }
        let runID = GenerationRunID()
        let artifact = SummaryArtifact(
            inputFingerprint: fingerprint,
            sourceTranscriptRevision: 2,
            draft: draft,
            generationRun: summaryRun(
                meetingID: captured.id,
                inputFingerprint: fingerprint,
                id: runID))

        let commit = try await store.completeSummaryJob(
            claim.id,
            owner: "worker-a",
            artifact: artifact,
            at: now.addingTimeInterval(1))
        XCTAssertEqual(commit.completedJob.state, .succeeded)
        XCTAssertEqual(commit.artifactVersion, 1)
        XCTAssertTrue(commit.enqueuedJobs.isEmpty)
        let storedSummary = try await store.summary(captured.id)
        let linkedRun = try await store.generationRun(forSummary: captured.id)
        let readyDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(storedSummary?.draft.markdown, "# Resumen durable")
        XCTAssertEqual(linkedRun?.id, runID)
        XCTAssertEqual(linkedRun?.inputFingerprint, fingerprint)
        XCTAssertEqual(readyDetail.meeting.lifecycleState, .ready)

        do {
            _ = try await store.completeSummaryJob(
                claim.id,
                owner: "worker-a",
                artifact: artifact,
                at: now.addingTimeInterval(2))
            XCTFail("a committed lease cannot publish the artifact twice")
        } catch StorageError.processingJobLeaseLost(let id) {
            XCTAssertEqual(id, claim.id)
        }
        let repeatedDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(repeatedDetail.summaries.count, 1)
    }

    func testSummaryCompletionRollsBackRunAndArtifactWhenJobCommitFails() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        _ = try await seedCast(for: captured.id, in: store)
        let fingerprint = "summary:rollback"
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [ProcessingJobRequest(kind: .summary, inputFingerprint: fingerprint)],
            at: now)
        let claimValue = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-a", leaseDuration: 30, at: now)
        let claim = try XCTUnwrap(claimValue)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_summary_completion
                BEFORE UPDATE OF state ON processingJob
                WHEN NEW.state = 'succeeded'
                BEGIN
                    SELECT RAISE(ABORT, 'forced summary completion failure');
                END
                """)
        }

        do {
            _ = try await store.completeSummaryJob(
                claim.id,
                owner: "worker-a",
                artifact: SummaryArtifact(
                    inputFingerprint: fingerprint,
                    sourceTranscriptRevision: 0,
                    draft: SummaryDraft(
                        meetingID: captured.id,
                        recipeID: Recipe.general.id,
                        language: "es",
                        markdown: "# Must roll back",
                        actionItems: [],
                        fingerprint: "material-rollback"),
                    generationRun: summaryRun(
                        meetingID: captured.id,
                        inputFingerprint: fingerprint)),
                at: now.addingTimeInterval(1))
            XCTFail("the injected job failure must abort provenance and artifact")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("forced summary completion failure"))
        }

        let storedSummary = try await store.summary(captured.id)
        let runs = try await store.generationRuns(for: captured.id)
        XCTAssertNil(storedSummary)
        XCTAssertTrue(runs.isEmpty)
        let jobs = try await store.processingJobs(for: captured.id)
        XCTAssertEqual(jobs.first?.state, .running)
        XCTAssertEqual(jobs.first?.leaseOwner, "worker-a")
    }

    func testClaimHonorsWorkerKindsAndSkipsDeletedMeetings() async throws {
        let store = try MeetingStore.inMemory()
        let deleted = meeting()
        let live = meeting()
        try await store.save(deleted)
        try await store.save(live)
        _ = try await store.enqueueProcessingJobs(
            for: deleted.id,
            requests: [
                ProcessingJobRequest(
                    kind: .summary, inputFingerprint: "deleted-summary", priority: 100),
            ],
            at: now)
        _ = try await store.enqueueProcessingJobs(
            for: live.id,
            requests: [
                ProcessingJobRequest(
                    kind: .index, inputFingerprint: "live-index", priority: 1),
            ],
            at: now)
        try await store.delete(deleted.id)

        let unsupported = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 10, at: now)
        XCTAssertNil(unsupported)
        let claim = try await store.claimNextProcessingJob(
            kinds: [.index], owner: "worker", leaseDuration: 10, at: now)
        XCTAssertEqual(claim?.meetingID, live.id)
        let hiddenJobs = try await store.processingJobs(for: deleted.id)
        XCTAssertTrue(hiddenJobs.isEmpty)
    }

    func testFailureRetriesThenExhaustsWithoutDuplicatingJob() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let request = ProcessingJobRequest(
            kind: .diarization,
            inputFingerprint: "audio-sha-1",
            maxAttempts: 2)
        let enqueued = try await store.enqueueProcessingJobs(
            for: captured.id, requests: [request], at: now)
        let jobID = try XCTUnwrap(enqueued.first?.id)

        let firstClaim = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker", leaseDuration: 10, at: now)
        XCTAssertEqual(firstClaim?.id, jobID)
        let retryAt = now.addingTimeInterval(20)
        let pending = try await store.failProcessingJob(
            jobID,
            owner: "worker",
            failure: ProcessingJobFailure(code: "diarization.transient"),
            retryAt: retryAt,
            at: now.addingTimeInterval(1))
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.attempt, 1)
        XCTAssertEqual(pending.notBefore, retryAt)
        let earlyClaim = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker", leaseDuration: 10,
            at: retryAt.addingTimeInterval(-1))
        XCTAssertNil(earlyClaim)

        let secondClaim = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "worker", leaseDuration: 10, at: retryAt)
        XCTAssertEqual(secondClaim?.attempt, 2)
        let failed = try await store.failProcessingJob(
            jobID,
            owner: "worker",
            failure: ProcessingJobFailure(
                code: "diarization.exhausted", message: "Model could not finish."),
            retryAt: retryAt.addingTimeInterval(20),
            at: retryAt.addingTimeInterval(1))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.notBefore)

        let repeated = try await store.enqueueProcessingJobs(
            for: captured.id, requests: [request], at: retryAt.addingTimeInterval(2))
        XCTAssertEqual(repeated.map(\.id), [jobID])
        let attentionDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(attentionDetail.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(attentionDetail.meeting.lastProcessingError, "diarization.exhausted")
    }

    func testCancellationIsOwnerBoundTerminalAndNonFailing() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let request = ProcessingJobRequest(
            kind: .summary, inputFingerprint: "summary:optional")
        let enqueued = try await store.enqueueProcessingJobs(
            for: captured.id, requests: [request], at: now)
        let jobID = try XCTUnwrap(enqueued.first?.id)
        _ = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker-a", leaseDuration: 30, at: now)

        do {
            _ = try await store.cancelProcessingJob(
                jobID,
                owner: "worker-b",
                reason: ProcessingJobFailure(code: "summary.unavailable"),
                at: now.addingTimeInterval(1))
            XCTFail("another worker cannot cancel the owned attempt")
        } catch StorageError.processingJobLeaseLost(let id) {
            XCTAssertEqual(id, jobID)
        }

        let cancelled = try await store.cancelProcessingJob(
            jobID,
            owner: "worker-a",
            reason: ProcessingJobFailure(
                code: "summary.unavailable", message: "No configured provider."),
            at: now.addingTimeInterval(2))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.errorCode, "summary.unavailable")
        XCTAssertEqual(cancelled.errorMessage, "No configured provider.")
        XCTAssertNil(cancelled.leaseOwner)
        XCTAssertEqual(cancelled.finishedAt, now.addingTimeInterval(2))

        let readyDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(readyDetail.meeting.lifecycleState, .ready)
        XCTAssertNil(readyDetail.meeting.lastProcessingError)
        let repeated = try await store.enqueueProcessingJobs(
            for: captured.id, requests: [request], at: now.addingTimeInterval(3))
        XCTAssertEqual(repeated.map(\.id), [jobID])
        XCTAssertEqual(repeated.first?.state, .cancelled)
    }

    func testNextScheduledDateFiltersByCapabilityAndLiveMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let live = meeting()
        let deleted = meeting()
        try await store.save(live)
        try await store.save(deleted)
        let summaryDate = now.addingTimeInterval(30)
        let diarizationDate = now.addingTimeInterval(10)
        _ = try await store.enqueueProcessingJobs(
            for: live.id,
            requests: [
                ProcessingJobRequest(
                    kind: .summary,
                    inputFingerprint: "summary:scheduled",
                    notBefore: summaryDate),
                ProcessingJobRequest(
                    kind: .summary,
                    inputFingerprint: "summary:already-due",
                    notBefore: now.addingTimeInterval(-1)),
                ProcessingJobRequest(
                    kind: .diarization,
                    inputFingerprint: "diarization:scheduled",
                    notBefore: diarizationDate),
            ],
            at: now)
        _ = try await store.enqueueProcessingJobs(
            for: deleted.id,
            requests: [ProcessingJobRequest(
                kind: .summary,
                inputFingerprint: "summary:deleted",
                notBefore: now.addingTimeInterval(1))],
            at: now)
        try await store.delete(deleted.id)

        let summaryWake = try await store.nextScheduledProcessingDate(
            kinds: [.summary], after: now)
        let anyWake = try await store.nextScheduledProcessingDate(
            kinds: [.summary, .diarization], after: now)
        let unsupportedWake = try await store.nextScheduledProcessingDate(
            kinds: [.index], after: now)

        XCTAssertEqual(summaryWake, summaryDate)
        XCTAssertEqual(anyWake, diarizationDate)
        XCTAssertNil(unsupportedWake)
    }

    func testExpiredLeaseRecoveryIsRepeatSafeAndExhaustsAttempts() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        _ = try await store.enqueueProcessingJobs(
            for: captured.id,
            requests: [
                ProcessingJobRequest(
                    kind: .summary, inputFingerprint: "summary-0", maxAttempts: 2),
            ],
            at: now)
        let firstClaimValue = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 10, at: now)
        let jobID = try XCTUnwrap(firstClaimValue?.id)

        let firstRecovery = try await store.recoverExpiredProcessingJobs(
            at: now.addingTimeInterval(11))
        XCTAssertEqual(firstRecovery.map(\.id), [jobID])
        XCTAssertEqual(firstRecovery.first?.state, .pending)
        XCTAssertEqual(firstRecovery.first?.errorCode, "processing.lease.expired")
        let repeatedRecovery = try await store.recoverExpiredProcessingJobs(
            at: now.addingTimeInterval(12))
        XCTAssertTrue(repeatedRecovery.isEmpty)

        let secondClaim = try await store.claimNextProcessingJob(
            kinds: [.summary], owner: "worker", leaseDuration: 10,
            at: now.addingTimeInterval(12))
        XCTAssertEqual(secondClaim?.attempt, 2)
        let exhausted = try await store.recoverExpiredProcessingJobs(
            at: now.addingTimeInterval(23))
        XCTAssertEqual(exhausted.first?.state, .failed)
        XCTAssertEqual(exhausted.first?.errorCode, "processing.lease.exhausted")
        let attentionDetail = try await detail(captured.id, in: store)
        XCTAssertEqual(attentionDetail.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(
            attentionDetail.meeting.lastProcessingError,
            "processing.lease.exhausted")
    }

    func testProcessingJobRecordRejectsCorruptIdentityStateAndLeaseContract() throws {
        let captured = meeting()
        let job = ProcessingJob(
            meetingID: captured.id,
            kind: .summary,
            inputFingerprint: "summary-0",
            createdAt: now)
        var record = ProcessingJobRecord(job)

        record.id = "not-a-uuid"
        XCTAssertThrowsError(try record.job) { error in
            guard case StorageError.invalidPersistedUUID(
                table: "processingJob", column: "id", value: "not-a-uuid") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        record = ProcessingJobRecord(job)
        record.state = "unknown"
        XCTAssertThrowsError(try record.job) { error in
            guard case StorageError.invalidPersistedValue(
                table: "processingJob", column: "state", value: "unknown") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        record = ProcessingJobRecord(job)
        record.state = ProcessingJobState.running.rawValue
        record.attempt = 1
        XCTAssertThrowsError(try record.job) { error in
            guard case StorageError.invalidPersistedValue(
                table: "processingJob", column: "stateContract", value: _) = error
            else { return XCTFail("wrong error: \(error)") }
        }
    }
}
