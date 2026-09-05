import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentReviewQueueReading: Sendable {
    func commitmentReviewQueue(
        _ query: CommitmentReviewQueueQuery
    ) async throws -> CommitmentReviewQueuePage
}

extension MeetingStore: CommitmentReviewQueueReading {}

public struct LoadCommitmentReviewQueueRequest: Sendable, Equatable {
    public let scope: CommitmentReviewQueueScope
    public let itemLimit: Int
    public let evidenceLimitPerItem: Int

    public init(
        scope: CommitmentReviewQueueScope = .library,
        itemLimit: Int = 50,
        evidenceLimitPerItem: Int = 3
    ) {
        self.scope = scope
        self.itemLimit = itemLimit
        self.evidenceLimitPerItem = evidenceLimitPerItem
    }
}

/// Samples review time once and loads a bounded queue without hydrating
/// Meeting Detail once per candidate.
public struct LoadCommitmentReviewQueue: ApplicationUseCase {
    private let repository: any CommitmentReviewQueueReading
    private let now: @Sendable () -> Date

    public init(
        repository: any CommitmentReviewQueueReading,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    public func execute(
        _ request: LoadCommitmentReviewQueueRequest
    ) async throws -> CommitmentReviewQueuePage {
        try await repository.commitmentReviewQueue(CommitmentReviewQueueQuery(
            scope: request.scope,
            reviewAt: now(),
            itemLimit: request.itemLimit,
            evidenceLimitPerItem: request.evidenceLimitPerItem))
    }
}
