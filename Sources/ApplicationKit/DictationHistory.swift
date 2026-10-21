import Foundation
import PortavozCore
import StorageKit

public protocol DictationHistoryStore: Sendable {
    func dictationHistoryPolicy() async throws -> DictationHistoryPolicy
    func setDictationHistoryPolicy(
        isEnabled: Bool, keepsOriginal: Bool, retentionDays: Int, at now: Date
    ) async throws -> DictationHistoryPolicy
    func recordDictation(
        _ record: DictationRecord, admittedGeneration: Int, at now: Date
    ) async throws -> DictationRecordOutcome
    func dictationRecords(
        matching filter: DictationRecordFilter, before cursor: DictationRecord?, limit: Int
    ) async throws -> [DictationRecord]
    func dictationApplications() async throws -> [String]
    func deleteDictationRecord(_ id: DictationRecordID) async throws -> Bool
    func deleteAllDictationRecords() async throws -> Int
    func purgeExpiredDictationRecords(at now: Date) async throws -> Int
}

extension MeetingStore: DictationHistoryStore {}

public struct LoadDictationHistoryPolicy: ApplicationUseCase {
    private let store: any DictationHistoryStore

    public init(store: any DictationHistoryStore) {
        self.store = store
    }

    public func execute(_ request: Void) async throws -> DictationHistoryPolicy {
        try await store.dictationHistoryPolicy()
    }
}

public struct UpdateDictationHistoryPolicy: ApplicationUseCase {
    public struct Request: Sendable {
        public let isEnabled: Bool
        public let keepsOriginal: Bool
        public let retentionDays: Int

        public init(isEnabled: Bool, keepsOriginal: Bool, retentionDays: Int) {
            self.isEnabled = isEnabled
            self.keepsOriginal = keepsOriginal
            self.retentionDays = retentionDays
        }
    }

    private let store: any DictationHistoryStore
    private let now: @Sendable () -> Date

    public init(store: any DictationHistoryStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func execute(_ request: Request) async throws -> DictationHistoryPolicy {
        try await store.setDictationHistoryPolicy(
            isEnabled: request.isEnabled, keepsOriginal: request.keepsOriginal,
            retentionDays: request.retentionDays, at: now())
    }
}

/// Writes only with the consent generation captured when the dictation started.
public struct RecordDictation: ApplicationUseCase {
    public struct Request: Sendable {
        public let record: DictationRecord
        public let admittedGeneration: Int

        public init(record: DictationRecord, admittedGeneration: Int) {
            self.record = record
            self.admittedGeneration = admittedGeneration
        }
    }

    private let store: any DictationHistoryStore
    private let now: @Sendable () -> Date

    public init(store: any DictationHistoryStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func execute(_ request: Request) async throws -> DictationRecordOutcome {
        try await store.recordDictation(
            request.record, admittedGeneration: request.admittedGeneration, at: now())
    }
}

public struct ListDictations: ApplicationUseCase {
    public static let pageSize = 50

    public struct Request: Sendable {
        public let filter: DictationRecordFilter
        /// The last row already shown; nil for the newest page.
        public let after: DictationRecord?

        public init(filter: DictationRecordFilter = .all, after: DictationRecord? = nil) {
            self.filter = filter
            self.after = after
        }
    }

    private let store: any DictationHistoryStore

    public init(store: any DictationHistoryStore) {
        self.store = store
    }

    public func execute(_ request: Request) async throws -> [DictationRecord] {
        try await store.dictationRecords(matching: request.filter, before: request.after, limit: Self.pageSize)
    }
}

public struct ListDictationApplications: ApplicationUseCase {
    private let store: any DictationHistoryStore

    public init(store: any DictationHistoryStore) {
        self.store = store
    }

    public func execute(_ request: Void) async throws -> [String] {
        try await store.dictationApplications()
    }
}

public struct DeleteDictation: ApplicationUseCase {
    private let store: any DictationHistoryStore

    public init(store: any DictationHistoryStore) {
        self.store = store
    }

    public func execute(_ request: DictationRecordID) async throws -> Bool {
        try await store.deleteDictationRecord(request)
    }
}

public struct DeleteAllDictations: ApplicationUseCase {
    private let store: any DictationHistoryStore

    public init(store: any DictationHistoryStore) {
        self.store = store
    }

    public func execute(_ request: Void) async throws -> Int {
        try await store.deleteAllDictationRecords()
    }
}

public struct PurgeExpiredDictations: ApplicationUseCase {
    private let store: any DictationHistoryStore
    private let now: @Sendable () -> Date

    public init(store: any DictationHistoryStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func execute(_ request: Void) async throws -> Int {
        try await store.purgeExpiredDictationRecords(at: now())
    }
}
