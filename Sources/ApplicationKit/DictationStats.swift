import Foundation
import PortavozCore
import StorageKit

/// Dictation statistics: aggregates only, behind their own consent.
public protocol DictationStatsStore: Sendable {
    func dictationStatsEnabled() async throws -> Bool
    func setDictationStatsEnabled(_ isEnabled: Bool) async throws
    func recordDictationStats(_ sample: DictationStatsSample, at now: Date, calendar: Calendar) async throws -> Bool
    func dictationStatsSummary(days: [String]) async throws -> DictationStatsSummary
    func deleteDictationStats() async throws
}

extension MeetingStore: DictationStatsStore {}

public struct LoadDictationStatsConsent: ApplicationUseCase {
    private let store: any DictationStatsStore

    public init(store: any DictationStatsStore) {
        self.store = store
    }

    public func execute(_ request: Void) async throws -> Bool {
        try await store.dictationStatsEnabled()
    }
}

public struct UpdateDictationStatsConsent: ApplicationUseCase {
    private let store: any DictationStatsStore

    public init(store: any DictationStatsStore) {
        self.store = store
    }

    public func execute(_ request: Bool) async throws -> Bool {
        try await store.setDictationStatsEnabled(request)
        return try await store.dictationStatsEnabled()
    }
}

public struct RecordDictationStats: ApplicationUseCase {
    private let store: any DictationStatsStore
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        store: any DictationStatsStore, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    public func execute(_ request: DictationStatsSample) async throws -> Bool {
        try await store.recordDictationStats(request, at: now(), calendar: calendar)
    }
}

/// The last `days` days ending today, oldest first.
public struct LoadDictationStatsSummary: ApplicationUseCase {
    private let store: any DictationStatsStore
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        store: any DictationStatsStore, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    public func execute(_ request: Int) async throws -> DictationStatsSummary {
        try await store.dictationStatsSummary(
            days: DictationStatsCalendar.days(endingAt: now(), count: min(max(request, 1), 366), calendar: calendar))
    }
}

public struct DeleteDictationStats: ApplicationUseCase {
    private let store: any DictationStatsStore

    public init(store: any DictationStatsStore) {
        self.store = store
    }

    public func execute(_ request: Void) async throws {
        try await store.deleteDictationStats()
    }
}
