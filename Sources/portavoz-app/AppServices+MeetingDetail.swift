import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    func makeMeetingDetailModel(_ meetingID: MeetingID) -> MeetingDetailModel {
        MeetingDetailModel(
            meetingID: meetingID,
            client: self,
            workloadTelemetry: workloadTelemetry)
    }

    func applyMeetingDetailRefine(
        _ request: ApplyRefinedMeetingRequest
    ) async throws -> ApplyRefinedMeetingResult {
        do {
            return try await refineMeeting.apply(request)
        } catch StorageError.staleRefineDraft(_, _, _) {
            throw MeetingDetailRefineApplyError.staleDraft
        }
    }
}

enum MeetingDetailRefineApplyError: Error {
    case staleDraft
}

extension AppServices: MeetingDetailModelClient {
    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate> {
        makeApplicationMeetingReviewStream(MeetingReviewStreams(
            core: store.observeMeetingReviewCore(meetingID),
            summary: store.observeMeetingReviewSummary(meetingID),
            companion: store.observeMeetingReviewCompanionCards(meetingID),
            privacy: store.observeMeetingReviewPrivacyReceipt(meetingID),
            processing: store.observeMeetingReviewProcessingJobs(meetingID),
            notes: store.observeMeetingReviewNotes(meetingID),
            commitments: store.observeCommitmentReviewStates(for: meetingID)))
    }

    func renameMeetingDetailMeeting(_ meeting: Meeting) async throws {
        try await store.save(meeting)
    }

    func renameMeetingDetailSpeaker(_ speaker: Speaker) async throws {
        try await store.save([speaker])
    }

    func correctMeetingDetailTranscript(
        _ request: CorrectMeetingTranscriptRequest
    ) async throws -> CorrectMeetingTranscriptResult {
        try await makeTranscriptEditor().execute(request)
    }

    func restructureMeetingDetailTranscript(
        _ request: RestructureMeetingTranscriptRequest
    ) async throws -> RestructureMeetingTranscriptResult {
        try await makeTranscriptRestructurer().execute(request)
    }

    func findMeetingDetailPeople(matchingAlias alias: String) async throws -> [Person] {
        try await FindCanonicalPeople(store: store).execute(alias)
    }

    func linkMeetingDetailSpeaker(
        _ request: LinkObservedSpeakerRequest
    ) async throws -> ConfirmedPersonLink {
        try await LinkObservedSpeaker(store: store).execute(request)
    }

    func setMeetingDetailActionItem(_ id: UUID, done: Bool) async throws {
        try await store.setActionItem(id, done: done)
    }

    func reviewMeetingDetailCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async throws {
        try await makeCommitmentInboxManager().review(request)
    }

    func setMeetingDetailSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        for claimID: SummaryClaimID,
        meetingID: MeetingID
    ) async throws {
        try await store.setSummaryClaimFeedback(
            feedback,
            for: claimID,
            meetingID: meetingID)
    }

    func confirmMeetingDetailDecision(
        _ request: ConfirmDecisionAboutTopicRequest
    ) async throws -> DecisionAboutTopicOutcome {
        try await ConfirmDecisionAboutTopic(store: store).execute(request)
    }

    func retractMeetingDetailDecisionTopic(
        _ retraction: DecisionTopicLinkRetraction
    ) async throws {
        _ = try await RetractDecisionTopicLink(store: store).execute(retraction)
    }

    func meetingDetailDecisionConfirmations(
        for observationIDs: [SummaryDecisionID]
    ) async throws -> [DecisionObservationConfirmationState] {
        try await store.decisionObservationConfirmations(for: observationIDs)
    }

    func meetingDetailLinkableTopics() async throws -> [LinkableTopic] {
        try await store.linkableTopics()
    }

    func deleteMeetingDetailCompanionCard(_ id: UUID) async throws {
        try await store.deleteCompanionCard(id)
    }

    func deleteMeetingDetail(_ id: MeetingID) async throws {
        try await meetingLifecycle.delete(id)
    }

    func requestMeetingDetailSearchReindex() {
        requestSearchReconciliation()
    }

    func requestMeetingDetailMemoryGraphReindex() {
        requestMemoryGraphReconciliation()
    }

    func retryMeetingDetailProcessing(_ meetingID: MeetingID) async throws {
        let jobs = try await store.retryFailedProcessingJobs(for: meetingID)
        guard !jobs.isEmpty else { return }
        kickPostCaptureProcessing()
    }
}

private struct MeetingReviewStreams: Sendable {
    let core: AsyncThrowingStream<MeetingStore.MeetingReviewCore?, Error>
    let summary: AsyncThrowingStream<MeetingStore.MeetingReviewSummarySnapshot?, Error>
    let companion: AsyncThrowingStream<MeetingStore.MeetingReviewCompanionSnapshot, Error>
    let privacy: AsyncThrowingStream<PrivacyReceipt?, Error>
    let processing: AsyncThrowingStream<[ProcessingJob], Error>
    let notes: AsyncThrowingStream<(items: [ContextItem], enhanced: EnhancedNote?), Error>
    let commitments: AsyncThrowingStream<[CommitmentReviewState], Error>
}

private func makeApplicationMeetingReviewStream(
    _ streams: MeetingReviewStreams
) -> AsyncStream<MeetingReviewUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                addMeetingContentReviewTasks(
                    streams,
                    to: &group,
                    continuation: continuation)
                addMeetingSupportReviewTasks(
                    streams,
                    to: &group,
                    continuation: continuation)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func addMeetingContentReviewTasks(
    _ streams: MeetingReviewStreams,
    to group: inout TaskGroup<Void>,
    continuation: AsyncStream<MeetingReviewUpdate>.Continuation
) {
    group.addTask {
        await forwardMeetingReview(
            streams.core,
            to: continuation,
            section: .core
        ) {
            .core($0.map(makeApplicationMeetingReviewCore))
        }
    }
    group.addTask {
        await forwardMeetingReview(
            streams.summary,
            to: continuation,
            section: .summary
        ) {
            .summary($0.map {
                MeetingReviewSummary(
                    draft: $0.draft,
                    version: $0.version,
                    correctionSource: $0.correctionSource)
            })
        }
    }
    group.addTask {
        await forwardMeetingReview(
            streams.companion,
            to: continuation,
            section: .companion
        ) {
            .companionCards(
                $0.cards,
                correctionSources: $0.correctionSources)
        }
    }
}

private func addMeetingSupportReviewTasks(
    _ streams: MeetingReviewStreams,
    to group: inout TaskGroup<Void>,
    continuation: AsyncStream<MeetingReviewUpdate>.Continuation
) {
    group.addTask {
        await forwardMeetingReview(
            streams.privacy,
            to: continuation,
            section: .privacy
        ) {
            .privacyReceipt($0)
        }
    }
    group.addTask {
        await forwardMeetingReview(
            streams.processing,
            to: continuation,
            section: .processing
        ) {
            .processingJobs($0)
        }
    }
    group.addTask {
        await forwardMeetingReview(
            streams.notes,
            to: continuation,
            section: .notes
        ) {
            .notes(MeetingReviewNotes(
                contextItems: $0.items, enhanced: $0.enhanced))
        }
    }
    group.addTask {
        await forwardMeetingReview(
            streams.commitments,
            to: continuation,
            section: .commitments
        ) {
            .commitmentReviewStates($0)
        }
    }
}

private func forwardMeetingReview<Input: Sendable>(
    _ stream: AsyncThrowingStream<Input, Error>,
    to continuation: AsyncStream<MeetingReviewUpdate>.Continuation,
    section: MeetingReviewSection,
    transform: @escaping @Sendable (Input) -> MeetingReviewUpdate
) async {
    do {
        for try await value in stream {
            continuation.yield(transform(value))
        }
    } catch is CancellationError {
        // Parent cancellation ends the complete merged stream.
    } catch {
        continuation.yield(.failed(section))
    }
}

private func makeApplicationMeetingReviewCore(
    _ core: MeetingStore.MeetingReviewCore
) -> MeetingReviewCore {
    MeetingReviewCore(
        meeting: core.meeting,
        speakers: core.speakers,
        segments: core.segments,
        corrections: core.corrections,
        correctionRevision: core.correctionRevision,
        isRefinedTranscript: core.isRefinedTranscript)
}

private extension AppServices {
    func makeTranscriptEditor() -> CorrectMeetingTranscript {
        CorrectMeetingTranscript(
            repository: AppTranscriptCorrectionRepository(store: store),
            sourceDeviceID: Self.persistentMeetingSyncDeviceID())
    }

    func makeTranscriptRestructurer() -> RestructureMeetingTranscript {
        RestructureMeetingTranscript(
            repository: AppTranscriptCorrectionRepository(store: store),
            sourceDeviceID: Self.persistentMeetingSyncDeviceID())
    }
}

private struct AppTranscriptCorrectionRepository: TranscriptCorrectionRepository {
    let store: MeetingStore

    func transcriptCorrectionHistory(
        for meetingID: MeetingID
    ) async throws -> [TranscriptCorrectionEvent] {
        try await store.transcriptCorrectionHistory(for: meetingID)
    }

    func appendTranscriptCorrections(
        _ events: [TranscriptCorrectionEvent]
    ) async throws -> [TranscriptCorrectionEvent] {
        try await store.appendTranscriptCorrections(events)
    }
}
