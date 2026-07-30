import CloudKit
import Foundation
import PortavozCore
import StorageKit

public enum CloudMeetingFetchResult: Equatable, Sendable {
    case applied(MeetingSyncRemoteApplyResult)
    case deferred(localGeneration: Int)
    case ignoredOwnDevice
    case ignoredDuplicate
}

enum CloudInitialSeedPreparationResult: Equatable, Sendable {
    case notRequested
    case paused(processedCount: Int)
    case prepared(processedCount: Int)
}

/// Coordinates the deterministic transport state with StorageKit's journal
/// and replay boundary. It does not create a CKContainer or start network work.
public actor CloudMeetingSyncCoordinator {
    private static let initialSeedWorkload = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .librarySync,
        operation: .execute)

    private let meetingStore: MeetingStore
    private let transportStore: CloudMeetingSyncStateStore
    private let localDeviceID: UUID
    private let initialSeedBatchSize: Int
    private let maintenanceGate: DurableMaintenanceGate

    public init(
        meetingStore: MeetingStore,
        transportStore: CloudMeetingSyncStateStore,
        localDeviceID: UUID,
        initialSeedBatchSize: Int = 100,
        maintenanceGate: DurableMaintenanceGate = .unrestricted
    ) {
        precondition(initialSeedBatchSize > 0)
        self.meetingStore = meetingStore
        self.transportStore = transportStore
        self.localDeviceID = localDeviceID
        self.initialSeedBatchSize = initialSeedBatchSize
        self.maintenanceGate = maintenanceGate
    }

    @discardableResult
    public func stagePendingChanges(
        limit: Int = 100,
        at date: Date = Date()
    ) async throws -> [CKRecord.ID] {
        let changes = try await meetingStore.pendingMeetingSyncChanges(limit: limit)
        var recordIDs: [CKRecord.ID] = []
        recordIDs.reserveCapacity(changes.count)
        for change in changes {
            let envelope = try await meetingStore.meetingSyncEnvelope(
                for: change,
                sourceDeviceID: localDeviceID)
            let attempt = try await transportStore.stage(envelope, at: date)
            recordIDs.append(CloudMeetingRecordCodec.recordID(for: attempt.meetingID))
        }
        recordIDs.append(contentsOf: await transportStore.outstandingRecordIDs())
        return Array(Set(recordIDs)).sorted { $0.recordName < $1.recordName }
    }

    public func encodedRecord(
        for recordID: CKRecord.ID,
        at date: Date = Date()
    ) async throws -> CloudMeetingEncodedRecord? {
        try await transportStore.encodedRecord(for: recordID, at: date)
    }

    /// Explicit opt-in writes only durable account-scoped intent. Preparation
    /// runs separately so capture policy can pause before the first storage
    /// read without losing the user's request.
    @discardableResult
    public func requestInitialSeed(at date: Date = Date()) async throws -> Bool {
        try await transportStore.requestInitialSeed(at: date)
    }

    /// Advances the existing-library seed through bounded committed batches.
    /// Storage publishes each batch before the opaque cursor, so replay after
    /// a crash is idempotent and never skips a meeting.
    func prepareInitialSeed(
        at date: Date = Date()
    ) async throws -> CloudInitialSeedPreparationResult {
        var snapshot = await transportStore.currentSnapshot()
        guard snapshot.initialSeedState == .requested else {
            return .notRequested
        }
        if snapshot.initialSeedPreparedAt != nil {
            return shouldProceed(at: .admission)
                ? .prepared(processedCount: 0)
                : .paused(processedCount: 0)
        }
        guard shouldProceed(at: .admission) else {
            return .paused(processedCount: 0)
        }

        var processedCount = 0
        while true {
            let batch = try await meetingStore.markMeetingsForInitialSync(
                after: snapshot.initialSeedCursorMeetingID,
                limit: initialSeedBatchSize)
            processedCount += batch.processedCount
            if let lastMeetingID = batch.lastMeetingID {
                try await transportStore.recordInitialSeedProgress(
                    through: lastMeetingID)
            }
            if batch.isComplete {
                try await transportStore.markInitialSeedPrepared(at: date)
                _ = try await completeInitialSeedIfDrained(at: date)
                return shouldProceed(at: .checkpoint)
                    ? .prepared(processedCount: processedCount)
                    : .paused(processedCount: processedCount)
            }
            guard shouldProceed(at: .checkpoint) else {
                return .paused(processedCount: processedCount)
            }
            snapshot = await transportStore.currentSnapshot()
        }
    }

    @discardableResult
    public func completeInitialSeedIfDrained(at date: Date = Date()) async throws -> Bool {
        let snapshot = await transportStore.currentSnapshot()
        if snapshot.initialSeedState == .complete { return true }
        guard snapshot.initialSeedState == .requested,
              snapshot.initialSeedPreparedAt != nil,
              snapshot.attempts.isEmpty,
              try await meetingStore.pendingMeetingSyncChanges(limit: 1).isEmpty
        else { return false }
        try await transportStore.markInitialSeedComplete(at: date)
        return true
    }

    /// Returns true when a newer exact generation for the same record still
    /// needs admission after CKSyncEngine settles this save callback.
    @discardableResult
    public func handleSavedRecord(_ record: CKRecord) async throws -> Bool {
        let envelope = try await transportStore.envelope(from: record)
        let change = MeetingSyncChange(
            meetingID: envelope.meetingID,
            generation: envelope.generation,
            changedAt: envelope.changedAt,
            isDeleted: Self.isDeletion(envelope))
        try await meetingStore.acknowledgeMeetingSync(change)
        try await transportStore.completeSend(of: envelope, savedRecord: record)
        try await completeInitialSeedIfDrained()
        return await transportStore.hasOutgoingAttempt(for: envelope.meetingID)
    }

    public func handleFetchedRecord(_ record: CKRecord) async throws -> CloudMeetingFetchResult {
        let envelope = try await transportStore.envelope(from: record)
        switch try await transportStore.replayDecision(
            for: envelope,
            localDeviceID: localDeviceID) {
        case .ignoreOwnDevice:
            try await transportStore.rememberRecord(record)
            return .ignoredOwnDevice
        case .ignoreDuplicate:
            try await transportStore.rememberRecord(record)
            return .ignoredDuplicate
        case .ignoreStale:
            return .ignoredDuplicate
        case .apply:
            break
        }

        let result = try await meetingStore.applyRemoteMeetingSyncEnvelope(envelope)
        switch result {
        case .localChangePending(let generation):
            try await transportStore.stageDeferredReplay(envelope, from: record)
            return .deferred(localGeneration: generation)
        case .applied:
            try await transportStore.completeReplay(
                of: envelope,
                from: record,
                discardOutgoing: false)
            return .applied(result)
        case .deletionWon:
            try await transportStore.completeReplay(
                of: envelope,
                from: record,
                discardOutgoing: true)
            return .applied(result)
        }
    }

    @discardableResult
    public func handleFailedRecord(
        _ record: CKRecord,
        error: Error,
        at date: Date = Date()
    ) async throws -> CloudSyncFailureResolution {
        let envelope = try await transportStore.envelope(from: record)
        let failure = CloudSyncFailureClassifier.classify(error)
        if failure.category == .serverConflict,
           let serverRecord = CloudSyncFailureClassifier.serverRecord(from: error) {
            let serverEnvelope = try await transportStore.envelope(from: serverRecord)
            let serverMatchesOutgoing = try Self.samePayload(envelope, serverEnvelope)
            let fetchResult = try await handleFetchedRecord(serverRecord)
            switch fetchResult {
            case .applied(.deletionWon):
                return CloudSyncFailureResolution(
                    category: .serverConflict,
                    shouldRetry: false)
            case .applied(.applied):
                try await transportStore.discardAttempt(for: envelope.meetingID)
                return CloudSyncFailureResolution(
                    category: .serverConflict,
                    shouldRetry: false)
            case .ignoredOwnDevice where serverMatchesOutgoing,
                 .ignoredDuplicate where serverMatchesOutgoing:
                _ = try await handleSavedRecord(serverRecord)
                return CloudSyncFailureResolution(
                    category: .serverConflict,
                    shouldRetry: false)
            case .applied(.localChangePending),
                 .deferred,
                 .ignoredOwnDevice,
                 .ignoredDuplicate:
                break
            }
        }
        try await transportStore.markFailure(
            for: envelope,
            category: failure.category,
            serverRetryAfter: failure.retryAfter,
            at: date)
        return CloudSyncFailureResolution(
            category: failure.category,
            shouldRetry: failure.category != .terminal)
    }

    public func handleFetchedRecordDeletion(_ recordID: CKRecord.ID) async throws {
        // Portavoz deletion is an authenticated encrypted tombstone save. A
        // physical CloudKit deletion has no payload and cannot delete local
        // content; it only invalidates the saved change tag.
        try await transportStore.forgetRecord(recordID)
    }

    private static func isDeletion(_ envelope: MeetingSyncEnvelope) -> Bool {
        if case .delete = envelope.mutation { return true }
        return false
    }

    private func shouldProceed(
        at phase: ResourceGovernorEvaluationPhase
    ) -> Bool {
        maintenanceGate.disposition(
            for: Self.initialSeedWorkload,
            phase: phase) == .proceed
    }

    private static func samePayload(
        _ first: MeetingSyncEnvelope,
        _ second: MeetingSyncEnvelope
    ) throws -> Bool {
        try MeetingSyncEnvelopeCodec.encode(first) == MeetingSyncEnvelopeCodec.encode(second)
    }
}
