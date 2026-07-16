import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    func makeMeetingDetailModel(_ meetingID: MeetingID) -> MeetingDetailModel {
        MeetingDetailModel(meetingID: meetingID, client: self)
    }
}

extension AppServices: MeetingDetailModelClient {
    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate> {
        makeApplicationMeetingReviewStream(
            core: store.observeMeetingReviewCore(meetingID),
            summary: store.observeMeetingReviewSummary(meetingID),
            companion: store.observeMeetingReviewCompanionCards(meetingID))
    }
}

private func makeApplicationMeetingReviewStream(
    core: AsyncThrowingStream<MeetingStore.MeetingReviewCore?, Error>,
    summary: AsyncThrowingStream<(draft: SummaryDraft, version: Int)?, Error>,
    companion: AsyncThrowingStream<[CompanionCard], Error>
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
