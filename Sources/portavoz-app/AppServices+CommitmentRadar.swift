import ApplicationKit
import PortavozCore

extension AppServices {
    func makeCommitmentRadarModel() -> CommitmentRadarModel {
        CommitmentRadarModel(client: self)
    }
}

extension AppServices: CommitmentRadarModelClient {
    func loadCommitmentRadar(
        _ request: LoadCommitmentRadarRequest
    ) async throws -> CommitmentRadarPage {
        try await LoadCommitmentRadar(repository: store).execute(request)
    }

    func mutateCommitmentRadar(
        _ request: ManageCommitmentRadarRequest
    ) async throws {
        _ = try await ManageCommitmentRadar(repository: store).execute(request)
        commitmentReminders.kick()
    }

    func loadCommitmentReviewQueue(
        _ request: LoadCommitmentReviewQueueRequest
    ) async throws -> CommitmentReviewQueuePage {
        try await LoadCommitmentReviewQueue(repository: store).execute(request)
    }

    func reviewMeetingCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async throws {
        _ = try await makeCommitmentInboxManager().execute(.review(request))
    }
}
