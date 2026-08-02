import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentRadarReading: Sendable {
    func commitmentRadar(
        _ query: CommitmentRadarQuery
    ) async throws -> CommitmentRadarPage
}

extension MeetingStore: CommitmentRadarReading {}

public struct LoadCommitmentRadarRequest: Sendable, Equatable {
    public let owner: CommitmentRadarOwnerFilter
    public let due: CommitmentRadarDueFilter
    public let activity: CommitmentRadarActivityFilter
    public let itemLimit: Int
    public let sourceLimitPerItem: Int
    public let historyLimitPerItem: Int

    public init(
        owner: CommitmentRadarOwnerFilter = .all,
        due: CommitmentRadarDueFilter = .all,
        activity: CommitmentRadarActivityFilter = .all,
        itemLimit: Int = 100,
        sourceLimitPerItem: Int = 3,
        historyLimitPerItem: Int = 8
    ) {
        self.owner = owner
        self.due = due
        self.activity = activity
        self.itemLimit = itemLimit
        self.sourceLimitPerItem = sourceLimitPerItem
        self.historyLimitPerItem = historyLimitPerItem
    }
}

public enum LoadCommitmentRadarError: Error, Sendable, Equatable {
    case invalidCalendar
}

/// Owns calendar-relative Radar semantics. The repository receives concrete
/// date boundaries and performs one bounded snapshot read without per-row
/// Meeting Detail hydration.
public struct LoadCommitmentRadar: ApplicationUseCase {
    private static let dueSoonDays = 7
    private static let newActivityDays = 7

    private let repository: any CommitmentRadarReading
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        repository: any CommitmentRadarReading,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.calendar = calendar
        self.now = now
    }

    public func execute(
        _ request: LoadCommitmentRadarRequest
    ) async throws -> CommitmentRadarPage {
        let dayStart = calendar.startOfDay(for: now())
        guard let dueSoonEnd = calendar.date(
            byAdding: .day,
            value: Self.dueSoonDays,
            to: dayStart),
              let newSince = calendar.date(
                  byAdding: .day,
                  value: -Self.newActivityDays,
                  to: dayStart)
        else { throw LoadCommitmentRadarError.invalidCalendar }

        return try await repository.commitmentRadar(CommitmentRadarQuery(
            owner: request.owner,
            due: request.due,
            activity: request.activity,
            dayStart: dayStart,
            dueSoonEnd: dueSoonEnd,
            newSince: newSince,
            itemLimit: request.itemLimit,
            sourceLimitPerItem: request.sourceLimitPerItem,
            historyLimitPerItem: request.historyLimitPerItem))
    }
}
