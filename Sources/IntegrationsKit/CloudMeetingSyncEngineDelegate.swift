import CloudKit
import Foundation

public enum CloudMeetingDelegateFailure: String, Equatable, Sendable {
    case statePersistence
    case accountTransition
    case recordPreparation
    case fetchedRecord
    case sentRecord
    case deletedRecord
}

/// Thin CKSyncEngine adapter. It persists Apple's opaque state immediately and
/// forwards content to the deterministic coordinator; no conflict rule lives
/// in the callback switch.
public actor CloudMeetingSyncEngineDelegate: CKSyncEngineDelegate {
    private let coordinator: CloudMeetingSyncCoordinator
    private let transportStore: CloudMeetingSyncStateStore
    private var latestFailure: CloudMeetingDelegateFailure?

    public init(
        coordinator: CloudMeetingSyncCoordinator,
        transportStore: CloudMeetingSyncStateStore
    ) {
        self.coordinator = coordinator
        self.transportStore = transportStore
    }

    public func lastFailure() -> CloudMeetingDelegateFailure? {
        latestFailure
    }

    public func clearLastFailure() {
        latestFailure = nil
    }

    public func restoredEngineState() async throws -> CKSyncEngine.State.Serialization? {
        try await transportStore.restoredEngineState()
    }

    public func grantConsent(
        for currentUser: CKRecord.ID,
        at date: Date = Date()
    ) async throws {
        let fingerprint = CloudMeetingSyncStateStore.accountFingerprint(
            forCloudRecordName: currentUser.recordName)
        try await transportStore.grantConsent(
            forAccountFingerprint: fingerprint,
            at: date)
    }

    @discardableResult
    public func requestInitialSeed(at date: Date = Date()) async throws -> Int {
        try await coordinator.requestInitialSeed(at: date)
    }

    /// Explicitly stages StorageKit's current pending generations and admits
    /// only those exact record IDs into CKSyncEngine's state.
    @discardableResult
    public func preparePendingChanges(
        in syncEngine: CKSyncEngine,
        limit: Int = 100,
        at date: Date = Date()
    ) async throws -> Int {
        let recordIDs = try await coordinator.stagePendingChanges(limit: limit, at: date)
        let zone = CKRecordZone(zoneID: CloudMeetingRecordCodec.zoneID)
        let zoneChange = CKSyncEngine.PendingDatabaseChange.saveZone(zone)
        if !syncEngine.state.pendingDatabaseChanges.contains(zoneChange) {
            syncEngine.state.add(pendingDatabaseChanges: [zoneChange])
        }
        let pending = Set(syncEngine.state.pendingRecordZoneChanges)
        let changes = recordIDs
            .map(CKSyncEngine.PendingRecordZoneChange.saveRecord)
            .filter { !pending.contains($0) }
        syncEngine.state.add(pendingRecordZoneChanges: changes)
        return recordIDs.count
    }

    public func updateAccountStatus(
        _ status: CKAccountStatus,
        currentUser: CKRecord.ID?
    ) async throws {
        switch status {
        case .available:
            guard let currentUser else {
                throw CloudMeetingTransportError.invalidState(
                    "available CloudKit account requires a current user")
            }
            try await setAvailableAccount(currentUser)
        case .noAccount:
            try await transportStore.updateAccount(status: .signedOut, fingerprint: nil)
        case .restricted:
            try await transportStore.updateAccount(status: .restricted, fingerprint: nil)
        case .couldNotDetermine, .temporarilyUnavailable:
            try await transportStore.updateAccount(
                status: .temporarilyUnavailable,
                fingerprint: nil)
        @unknown default:
            try await transportStore.updateAccount(status: .unknown, fingerprint: nil)
        }
    }

    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .stateUpdate(let update):
            do {
                try await transportStore.persistEngineState(update.stateSerialization)
            } catch {
                latestFailure = .statePersistence
            }
        case .accountChange(let change):
            await handleAccountChange(change)
        case .fetchedRecordZoneChanges(let changes):
            await handleFetchedChanges(changes)
        case .sentRecordZoneChanges(let changes):
            await handleSentChanges(changes, syncEngine: syncEngine)
        case .fetchedDatabaseChanges,
             .sentDatabaseChanges,
             .willFetchChanges,
             .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges,
             .didFetchChanges,
             .willSendChanges,
             .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let ready = Set(await transportStore.readyRecordIDs(at: Date()))
        let pendingIDs: [CKRecord.ID] = syncEngine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            guard context.options.scope.contains(change),
                  case .saveRecord(let recordID) = change,
                  ready.contains(recordID)
            else { return nil }
            return recordID
        }
        var records: [CKRecord] = []
        records.reserveCapacity(pendingIDs.count)
        for recordID in pendingIDs {
            do {
                if let encoded = try await coordinator.encodedRecord(for: recordID) {
                    records.append(encoded.record)
                }
            } catch {
                latestFailure = .recordPreparation
            }
        }
        guard !records.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: records,
            atomicByZone: false)
    }
}

private extension CloudMeetingSyncEngineDelegate {
    func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        do {
            switch change.changeType {
            case .signIn(let currentUser):
                try await setAvailableAccount(currentUser)
            case .signOut:
                try await transportStore.updateAccount(
                    status: .signedOut,
                    fingerprint: nil)
            case .switchAccounts(_, let currentUser):
                try await setAvailableAccount(currentUser)
            @unknown default:
                try await transportStore.updateAccount(
                    status: .unknown,
                    fingerprint: nil)
            }
        } catch {
            latestFailure = .accountTransition
        }
    }

    func setAvailableAccount(_ currentUser: CKRecord.ID) async throws {
        let fingerprint = CloudMeetingSyncStateStore.accountFingerprint(
            forCloudRecordName: currentUser.recordName)
        try await transportStore.updateAccount(
            status: .available,
            fingerprint: fingerprint)
    }

    func handleFetchedChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async {
        for modification in changes.modifications {
            do {
                _ = try await coordinator.handleFetchedRecord(modification.record)
            } catch {
                latestFailure = .fetchedRecord
            }
        }
        for deletion in changes.deletions {
            do {
                try await coordinator.handleFetchedRecordDeletion(deletion.recordID)
            } catch {
                latestFailure = .deletedRecord
            }
        }
    }

    func handleSentChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        for record in changes.savedRecords {
            do {
                let shouldRemainPending = try await coordinator.handleSavedRecord(record)
                if shouldRemainPending {
                    syncEngine.state.add(pendingRecordZoneChanges: [
                        .saveRecord(record.recordID)
                    ])
                }
            } catch {
                latestFailure = .sentRecord
                syncEngine.state.add(pendingRecordZoneChanges: [
                    .saveRecord(record.recordID)
                ])
            }
        }
        for failure in changes.failedRecordSaves {
            do {
                let resolution = try await coordinator.handleFailedRecord(
                    failure.record,
                    error: failure.error)
                let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(
                    failure.record.recordID)
                if resolution.shouldRetry {
                    syncEngine.state.add(pendingRecordZoneChanges: [change])
                } else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [change])
                }
            } catch {
                latestFailure = .sentRecord
                syncEngine.state.add(pendingRecordZoneChanges: [
                    .saveRecord(failure.record.recordID)
                ])
            }
        }
    }
}
