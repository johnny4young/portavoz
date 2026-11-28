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

    func requestCommitmentRadarSearchReindex() {
        requestSearchReconciliation()
    }

    func loadCommitmentReviewQueue(
        _ request: LoadCommitmentReviewQueueRequest
    ) async throws -> CommitmentReviewQueuePage {
        try await LoadCommitmentReviewQueue(repository: store).execute(request)
    }

    func loadCommitmentDueBoardWork() async throws -> CommitmentDueBoard.Work {
        let radar = LoadCommitmentRadar(repository: store)
        func dated(_ due: CommitmentRadarDueFilter) async throws -> CommitmentRadarPage {
            try await radar.execute(LoadCommitmentRadarRequest(
                due: due,
                itemLimit: CommitmentRadarQuery.maximumItemCount,
                sourceLimitPerItem: 1,
                historyLimitPerItem: 1))
        }
        return try await CommitmentDueBoard.Work(
            overdue: dated(.overdue),
            fromToday: dated(.dueFromToday),
            putOff: LoadUpcomingCommitmentReviews(repository: store).execute())
    }

    func reviewMeetingCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async throws {
        _ = try await makeCommitmentInboxManager().execute(.review(request))
    }

    func confirmReviewedCommitment(
        _ request: ConfirmMeetingCommitmentRequest
    ) async throws {
        _ = try await confirmMeetingDetailCommitment(request)
        // Also wakes the memory graph.
        requestSearchReconciliation()
    }

    func loadCommitmentReviewVoices(
        _ items: [CommitmentReviewQueueItem]
    ) async throws -> CommitmentReviewVoices {
        try await LoadCommitmentReviewVoices(reader: store)(items)
    }

    func recordCommitmentFieldPresentation(
        _ request: RecordCommitmentFieldPresentationRequest
    ) async throws {
        _ = try await RecordCommitmentFieldPresentation(repository: store)
            .execute(request)
    }

    func loadCommitmentFieldQuality() async throws -> CommitmentFieldQualityScorecard {
        try await LoadCommitmentFieldQuality(repository: store).execute(())
    }
}
