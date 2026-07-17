import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    func makeMeetingDetailModel(_ meetingID: MeetingID) -> MeetingDetailModel {
        MeetingDetailModel(meetingID: meetingID, client: self)
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
        makeApplicationMeetingReviewStream(
            core: store.observeMeetingReviewCore(meetingID),
            summary: store.observeMeetingReviewSummary(meetingID),
            companion: store.observeMeetingReviewCompanionCards(meetingID),
            privacy: store.observeMeetingReviewPrivacyReceipt(meetingID),
            processing: store.observeMeetingReviewProcessingJobs(meetingID))
    }

    func renameMeetingDetailMeeting(_ meeting: Meeting) async throws {
        try await store.save(meeting)
    }

    func renameMeetingDetailSpeaker(_ speaker: Speaker) async throws {
        try await store.save([speaker])
    }

    func setMeetingDetailActionItem(_ id: UUID, done: Bool) async throws {
        try await store.setActionItem(id, done: done)
    }

    func deleteMeetingDetailCompanionCard(_ id: UUID) async throws {
        try await store.deleteCompanionCard(id)
    }

    func deleteMeetingDetail(_ id: MeetingID) async throws {
        try await meetingLifecycle.delete(id)
    }

    func requestMeetingDetailSearchReindex() {
        requestSpotlightReindex()
    }

    func retryMeetingDetailProcessing(_ meetingID: MeetingID) async throws {
        let jobs = try await store.retryFailedProcessingJobs(for: meetingID)
        guard !jobs.isEmpty else { return }
        kickPostCaptureProcessing()
    }
}

private func makeApplicationMeetingReviewStream(
    core: AsyncThrowingStream<MeetingStore.MeetingReviewCore?, Error>,
    summary: AsyncThrowingStream<(draft: SummaryDraft, version: Int)?, Error>,
    companion: AsyncThrowingStream<[CompanionCard], Error>,
    privacy: AsyncThrowingStream<PrivacyReceipt?, Error>,
    processing: AsyncThrowingStream<[ProcessingJob], Error>
) -> AsyncStream<MeetingReviewUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await forwardMeetingReview(core, to: continuation, section: .core) {
                        .core($0.map(makeApplicationMeetingReviewCore))
                    }
                }
                group.addTask {
                    await forwardMeetingReview(summary, to: continuation, section: .summary) {
                        .summary($0.map {
                            MeetingReviewSummary(draft: $0.draft, version: $0.version)
                        })
                    }
                }
                group.addTask {
                    await forwardMeetingReview(companion, to: continuation, section: .companion) {
                        .companionCards($0)
                    }
                }
                group.addTask {
                    await forwardMeetingReview(privacy, to: continuation, section: .privacy) {
                        .privacyReceipt($0)
                    }
                }
                group.addTask {
                    await forwardMeetingReview(
                        processing, to: continuation, section: .processing
                    ) {
                        .processingJobs($0)
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
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
        segments: core.segments)
}
