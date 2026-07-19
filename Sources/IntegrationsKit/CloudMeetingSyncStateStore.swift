import CloudKit
import Foundation
import PortavozCore
import StorageKit

/// Crash-safe local transport state. Meeting content lives only in protected
/// payload files; the JSON snapshot contains account policy, generations,
/// digests, retry clocks, replay cursors, and CKRecord/CKSyncEngine metadata.
public actor CloudMeetingSyncStateStore {
    private static let stateFileName = "transport-state.json"
    private static let payloadDirectoryName = "payloads"

    private let payloadDirectory: URL
    private let stateFileURL: URL
    private let codec: CloudMeetingRecordCodec
    private let retryPolicy: CloudSyncRetryPolicy
    private var snapshot: CloudMeetingSyncSnapshot

    public init(
        rootDirectory: URL,
        codec: CloudMeetingRecordCodec = CloudMeetingRecordCodec(),
        retryPolicy: CloudSyncRetryPolicy = CloudSyncRetryPolicy()
    ) throws {
        let rootDirectory = rootDirectory.standardizedFileURL
        payloadDirectory = rootDirectory
            .appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        stateFileURL = rootDirectory.appendingPathComponent(Self.stateFileName)
        self.codec = codec
        self.retryPolicy = retryPolicy

        try Self.prepareDirectory(rootDirectory)
        try Self.prepareDirectory(payloadDirectory)
        snapshot = try Self.loadSnapshot(from: stateFileURL)
        try Self.validate(snapshot, payloadDirectory: payloadDirectory)
        try Self.removeOrphanedPayloads(
            in: payloadDirectory,
            referencedBy: snapshot.attempts.map(\.payloadFileName)
                + snapshot.deferredReplays.map(\.payloadFileName))
    }

    public func currentSnapshot() -> CloudMeetingSyncSnapshot {
        snapshot
    }

    public static func accountFingerprint(forCloudRecordName recordName: String) -> String {
        MeetingSyncEnvelopeCodec.sha256(Data(recordName.utf8))
    }

    public func updateAccount(
        status: CloudSyncAccountStatus,
        fingerprint: String?
    ) throws {
        if status == .available, fingerprint?.isEmpty != false {
            throw CloudMeetingTransportError.invalidState(
                "available account requires a fingerprint")
        }
        let availableFingerprint = status == .available ? fingerprint : nil
        let switchesAccount = availableFingerprint != nil
            && snapshot.accountScopeFingerprint != nil
            && snapshot.accountScopeFingerprint != availableFingerprint
        let deferredFiles = switchesAccount
            ? snapshot.deferredReplays.map(\.payloadFileName)
            : []
        try commitSnapshot {
            if switchesAccount {
                snapshot.engineStateData = nil
                snapshot.recordMetadata = []
                snapshot.replayCursors = []
                snapshot.deferredReplays = []
                snapshot.consentedAccountFingerprint = nil
                snapshot.consentGrantedAt = nil
                snapshot.initialSeedRequestedAt = nil
                snapshot.initialSeedCompletedAt = nil
                snapshot.initialSeedAccountFingerprint = nil
            }
            snapshot.accountStatus = status
            snapshot.currentAccountFingerprint = availableFingerprint
            if let availableFingerprint {
                snapshot.accountScopeFingerprint = availableFingerprint
            }
        }
        removePayloadFiles(deferredFiles)
    }

    /// Consent is account-scoped. A switch to another iCloud account pauses
    /// transport until the user explicitly grants consent for that account.
    public func grantConsent(forAccountFingerprint fingerprint: String, at date: Date) throws {
        guard snapshot.accountStatus == .available,
              snapshot.currentAccountFingerprint == fingerprint
        else {
            throw CloudMeetingTransportError.accountUnavailable
        }
        try commitSnapshot {
            snapshot.consentedAccountFingerprint = fingerprint
            snapshot.consentGrantedAt = date
        }
    }

    public func revokeConsent() throws {
        try commitSnapshot {
            snapshot.consentedAccountFingerprint = nil
            snapshot.consentGrantedAt = nil
        }
    }

    public func requestInitialSeed(at date: Date) throws {
        try requireReadyTransport()
        try commitSnapshot {
            snapshot.initialSeedRequestedAt = date
            snapshot.initialSeedCompletedAt = nil
            snapshot.initialSeedAccountFingerprint = snapshot.currentAccountFingerprint
        }
    }

    public func markInitialSeedComplete(at date: Date) throws {
        try requireReadyTransport()
        guard snapshot.initialSeedState == .requested else {
            throw CloudMeetingTransportError.invalidState(
                "initial seed must be explicitly requested")
        }
        try commitSnapshot {
            snapshot.initialSeedCompletedAt = date
        }
    }

    @discardableResult
    public func stage(
        _ envelope: MeetingSyncEnvelope,
        at date: Date
    ) throws -> CloudSyncAttempt {
        try requireReadyTransport()
        guard envelope.generation > 0 else {
            throw CloudMeetingTransportError.invalidState(
                "outgoing generation must be positive")
        }
        let payload = try MeetingSyncEnvelopeCodec.encode(envelope)
        let digest = MeetingSyncEnvelopeCodec.sha256(payload)
        let prior = snapshot.attempts.first { $0.meetingID == envelope.meetingID }
        if let prior {
            guard prior.sourceDeviceID == envelope.sourceDeviceID else {
                throw CloudMeetingTransportError.generationCollision
            }
            if envelope.generation < prior.generation {
                throw CloudMeetingTransportError.staleGeneration
            }
            if envelope.generation == prior.generation {
                guard prior.payloadSHA256 == digest else {
                    throw CloudMeetingTransportError.generationCollision
                }
                return prior
            }
        }

        let fileName = Self.payloadFileName(for: envelope)
        let fileURL = payloadDirectory.appendingPathComponent(fileName)
        try CloudSyncProtectedFile.write(payload, to: fileURL)
        let attempt = CloudSyncAttempt(
            meetingID: envelope.meetingID,
            sourceDeviceID: envelope.sourceDeviceID,
            generation: envelope.generation,
            changedAt: envelope.changedAt,
            payloadFileName: fileName,
            payloadSHA256: digest,
            payloadByteCount: payload.count,
            phase: .ready,
            attemptCount: 0,
            nextRetryAt: date,
            lastFailure: nil)
        let previousSnapshot = snapshot
        snapshot.attempts.removeAll { $0.meetingID == envelope.meetingID }
        snapshot.attempts.append(attempt)
        sortSnapshotCollections()
        do {
            try persistSnapshot()
        } catch {
            snapshot = previousSnapshot
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        if let prior, prior.payloadFileName != fileName {
            try? FileManager.default.removeItem(
                at: payloadDirectory.appendingPathComponent(prior.payloadFileName))
        }
        return attempt
    }

    public func readyRecordIDs(at date: Date) -> [CKRecord.ID] {
        guard snapshot.isTransportReady else { return [] }
        return snapshot.attempts
            .filter { attempt in
                attempt.phase != .blocked && (attempt.nextRetryAt ?? .distantPast) <= date
            }
            .map { CloudMeetingRecordCodec.recordID(for: $0.meetingID) }
    }

    public func hasOutgoingAttempt(for meetingID: MeetingID) -> Bool {
        snapshot.attempts.contains { $0.meetingID == meetingID }
    }

    /// Reconstructs CKSyncEngine pending state after a restart or a local
    /// persistence failure, including attempts whose journal generation was
    /// already acknowledged by a successful server save.
    public func outstandingRecordIDs() -> [CKRecord.ID] {
        snapshot.attempts.map { CloudMeetingRecordCodec.recordID(for: $0.meetingID) }
    }

    public func encodedRecord(
        for recordID: CKRecord.ID,
        at date: Date
    ) throws -> CloudMeetingEncodedRecord? {
        try requireReadyTransport()
        guard let meetingID = Self.meetingID(for: recordID),
              let attempt = snapshot.attempts.first(where: { $0.meetingID == meetingID })
        else { return nil }
        guard attempt.phase != .blocked,
              (attempt.nextRetryAt ?? .distantPast) <= date
        else { return nil }
        let existingRecord = try existingRecord(for: meetingID)
        return try codec.encodeStagedPayload(
            at: payloadDirectory.appendingPathComponent(attempt.payloadFileName),
            expectedSHA256: attempt.payloadSHA256,
            existingRecord: existingRecord)
    }

    public func envelope(from record: CKRecord) throws -> MeetingSyncEnvelope {
        try codec.decode(record)
    }

    /// Removes only the exact generation CloudKit returned. A newer staged
    /// generation survives a late success for its predecessor.
    @discardableResult
    public func completeSend(
        of envelope: MeetingSyncEnvelope,
        savedRecord: CKRecord
    ) throws -> Bool {
        let index = matchingAttemptIndex(for: envelope)
        let payloadFileName = index.map { snapshot.attempts[$0].payloadFileName }
        let deferredFiles = index == nil
            ? []
            : snapshot.deferredReplays
                .filter { $0.meetingID == envelope.meetingID }
                .map(\.payloadFileName)
        try commitSnapshot {
            try storeRecordMetadata(savedRecord, meetingID: envelope.meetingID)
            if let currentIndex = matchingAttemptIndex(for: envelope) {
                snapshot.attempts.remove(at: currentIndex)
                snapshot.deferredReplays.removeAll {
                    $0.meetingID == envelope.meetingID
                }
            }
        }
        if let payloadFileName {
            try? FileManager.default.removeItem(
                at: payloadDirectory.appendingPathComponent(payloadFileName))
        }
        removePayloadFiles(deferredFiles)
        return index != nil
    }

    public func markFailure(
        for envelope: MeetingSyncEnvelope,
        category: CloudSyncFailureCategory,
        serverRetryAfter: TimeInterval?,
        at date: Date
    ) throws {
        guard let index = matchingAttemptIndex(for: envelope) else { return }
        try commitSnapshot {
            snapshot.attempts[index].attemptCount += 1
            snapshot.attempts[index].lastFailure = category
            if category == .terminal {
                snapshot.attempts[index].phase = .blocked
                snapshot.attempts[index].nextRetryAt = nil
            } else {
                snapshot.attempts[index].phase = .retryWaiting
                let delay = retryPolicy.delay(
                    afterAttempt: snapshot.attempts[index].attemptCount,
                    serverRetryAfter: serverRetryAfter)
                snapshot.attempts[index].nextRetryAt = date.addingTimeInterval(delay)
            }
        }
    }

    public func discardAttempt(for meetingID: MeetingID) throws {
        guard let index = snapshot.attempts.firstIndex(where: { $0.meetingID == meetingID }) else {
            return
        }
        let fileName = snapshot.attempts[index].payloadFileName
        try commitSnapshot {
            snapshot.attempts.remove(at: index)
        }
        try? FileManager.default.removeItem(
            at: payloadDirectory.appendingPathComponent(fileName))
    }

    /// One explicit user retry makes delayed and terminal attempts eligible
    /// now without discarding their exact generation or audit counters.
    @discardableResult
    public func retryPendingAttempts(at date: Date) throws -> Int {
        let indexes = snapshot.attempts.indices.filter {
            snapshot.attempts[$0].phase != .ready
        }
        guard !indexes.isEmpty else { return 0 }
        try commitSnapshot {
            for index in indexes {
                snapshot.attempts[index].phase = .ready
                snapshot.attempts[index].nextRetryAt = date
                snapshot.attempts[index].lastFailure = nil
            }
        }
        return indexes.count
    }

    /// Removes only this Mac's CloudKit transport state. It does not touch
    /// StorageKit meetings or any encrypted records already present in iCloud.
    public func removeThisDeviceState() throws {
        let payloadFiles = snapshot.attempts.map(\.payloadFileName)
            + snapshot.deferredReplays.map(\.payloadFileName)
        try commitSnapshot {
            snapshot = CloudMeetingSyncSnapshot()
        }
        removePayloadFiles(payloadFiles)
    }
}

extension CloudMeetingSyncStateStore {
    public func replayDecision(
        for envelope: MeetingSyncEnvelope,
        localDeviceID: UUID
    ) throws -> CloudSyncReplayDecision {
        if envelope.sourceDeviceID == localDeviceID { return .ignoreOwnDevice }
        let digest = MeetingSyncEnvelopeCodec.sha256(
            try MeetingSyncEnvelopeCodec.encode(envelope))
        var latestGeneration = 0
        var latestDigest: String?
        if let cursor = replayCursor(for: envelope) {
            latestGeneration = cursor.generation
            latestDigest = cursor.payloadSHA256
        }
        if let deferred = snapshot.deferredReplays.first(where: {
            $0.meetingID == envelope.meetingID
                && $0.sourceDeviceID == envelope.sourceDeviceID
        }) {
            if deferred.generation == latestGeneration,
               let latestDigest,
               deferred.payloadSHA256 != latestDigest {
                throw CloudMeetingTransportError.generationCollision
            }
            if deferred.generation > latestGeneration {
                latestGeneration = deferred.generation
                latestDigest = deferred.payloadSHA256
            }
        }
        guard latestGeneration > 0 else { return .apply }
        if envelope.generation < latestGeneration { return .ignoreStale }
        if envelope.generation == latestGeneration {
            guard digest == latestDigest else {
                throw CloudMeetingTransportError.generationCollision
            }
            return .ignoreDuplicate
        }
        return .apply
    }

    /// Persists a fetched live envelope that StorageKit deferred behind local
    /// unsent work. CKSyncEngine may checkpoint the fetch event immediately;
    /// this protected copy prevents that remote state from disappearing on a
    /// crash before the local attempt reaches a terminal outcome.
    public func stageDeferredReplay(
        _ envelope: MeetingSyncEnvelope,
        from record: CKRecord
    ) throws {
        let decoded = try codec.decode(record)
        let decodedPayload = try MeetingSyncEnvelopeCodec.encode(decoded)
        let payload = try MeetingSyncEnvelopeCodec.encode(envelope)
        guard decodedPayload == payload else {
            throw CloudMeetingTransportError.payloadCorrupted
        }
        let digest = MeetingSyncEnvelopeCodec.sha256(payload)
        if let prior = snapshot.deferredReplays.first(where: {
            $0.meetingID == envelope.meetingID
                && $0.sourceDeviceID == envelope.sourceDeviceID
        }) {
            if envelope.generation < prior.generation {
                throw CloudMeetingTransportError.staleGeneration
            }
            if envelope.generation == prior.generation {
                guard digest == prior.payloadSHA256 else {
                    throw CloudMeetingTransportError.generationCollision
                }
                try commitSnapshot {
                    try storeRecordMetadata(record, meetingID: envelope.meetingID)
                }
                return
            }
        }
        let fileName = Self.deferredPayloadFileName(for: envelope)
        let fileURL = payloadDirectory.appendingPathComponent(fileName)
        let priorFiles = snapshot.deferredReplays
            .filter { $0.meetingID == envelope.meetingID }
            .map(\.payloadFileName)
        try CloudSyncProtectedFile.write(payload, to: fileURL)
        do {
            try commitSnapshot {
                snapshot.deferredReplays.removeAll {
                    $0.meetingID == envelope.meetingID
                }
                snapshot.deferredReplays.append(CloudSyncDeferredReplay(
                    meetingID: envelope.meetingID,
                    sourceDeviceID: envelope.sourceDeviceID,
                    generation: envelope.generation,
                    changedAt: envelope.changedAt,
                    payloadFileName: fileName,
                    payloadSHA256: digest,
                    payloadByteCount: payload.count))
                try storeRecordMetadata(record, meetingID: envelope.meetingID)
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        removePayloadFiles(priorFiles.filter { $0 != fileName })
    }

    public func deferredEnvelope(for meetingID: MeetingID) throws -> MeetingSyncEnvelope? {
        guard let replay = snapshot.deferredReplays.first(where: {
            $0.meetingID == meetingID
        }) else { return nil }
        let payload = try Data(
            contentsOf: payloadDirectory.appendingPathComponent(replay.payloadFileName),
            options: [.mappedIfSafe])
        guard payload.count == replay.payloadByteCount,
              MeetingSyncEnvelopeCodec.sha256(payload) == replay.payloadSHA256
        else {
            throw CloudMeetingTransportError.payloadCorrupted
        }
        return try MeetingSyncEnvelopeCodec.decode(payload)
    }

    public func discardDeferredReplay(for meetingID: MeetingID) throws {
        let files = snapshot.deferredReplays
            .filter { $0.meetingID == meetingID }
            .map(\.payloadFileName)
        guard !files.isEmpty else { return }
        try commitSnapshot {
            snapshot.deferredReplays.removeAll { $0.meetingID == meetingID }
        }
        removePayloadFiles(files)
    }

    public func markReplayApplied(_ envelope: MeetingSyncEnvelope) throws {
        try commitSnapshot {
            try setReplayCursor(envelope)
        }
    }

    public func completeReplay(
        of envelope: MeetingSyncEnvelope,
        from record: CKRecord,
        discardOutgoing: Bool
    ) throws {
        let discardedFileName = discardOutgoing
            ? snapshot.attempts.first(where: { $0.meetingID == envelope.meetingID })?
                .payloadFileName
            : nil
        let deferredFiles = snapshot.deferredReplays
            .filter { $0.meetingID == envelope.meetingID }
            .map(\.payloadFileName)
        try commitSnapshot {
            try setReplayCursor(envelope)
            try storeRecordMetadata(record, meetingID: envelope.meetingID)
            snapshot.deferredReplays.removeAll {
                $0.meetingID == envelope.meetingID
            }
            if discardOutgoing {
                snapshot.attempts.removeAll { $0.meetingID == envelope.meetingID }
            }
        }
        if let discardedFileName {
            try? FileManager.default.removeItem(
                at: payloadDirectory.appendingPathComponent(discardedFileName))
        }
        removePayloadFiles(deferredFiles)
    }

    public func rememberRecord(_ record: CKRecord) throws {
        guard let meetingID = Self.meetingID(for: record.recordID) else { return }
        try commitSnapshot {
            try storeRecordMetadata(record, meetingID: meetingID)
        }
    }

    public func forgetRecord(_ recordID: CKRecord.ID) throws {
        guard let meetingID = Self.meetingID(for: recordID) else { return }
        try commitSnapshot {
            snapshot.recordMetadata.removeAll { $0.meetingID == meetingID }
        }
    }

    public func persistEngineState(_ state: CKSyncEngine.State.Serialization) throws {
        let encoded = try Self.encoder().encode(state)
        try commitSnapshot {
            snapshot.engineStateData = encoded
        }
    }

    public func restoredEngineState() throws -> CKSyncEngine.State.Serialization? {
        guard let data = snapshot.engineStateData else { return nil }
        return try Self.decoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}

private extension CloudMeetingSyncStateStore {
    func commitSnapshot(_ mutation: () throws -> Void) throws {
        let previous = snapshot
        do {
            try mutation()
            try persistSnapshot()
        } catch {
            snapshot = previous
            throw error
        }
    }

    func removePayloadFiles(_ fileNames: [String]) {
        for fileName in fileNames {
            try? FileManager.default.removeItem(
                at: payloadDirectory.appendingPathComponent(fileName))
        }
    }

    func requireReadyTransport() throws {
        guard snapshot.consentedAccountFingerprint != nil else {
            throw CloudMeetingTransportError.consentRequired
        }
        guard snapshot.isTransportReady else {
            throw CloudMeetingTransportError.accountUnavailable
        }
    }

    func matchingAttemptIndex(for envelope: MeetingSyncEnvelope) -> Int? {
        snapshot.attempts.firstIndex {
            $0.meetingID == envelope.meetingID
                && $0.sourceDeviceID == envelope.sourceDeviceID
                && $0.generation == envelope.generation
        }
    }

    func replayCursor(for envelope: MeetingSyncEnvelope) -> CloudSyncReplayCursor? {
        snapshot.replayCursors.first {
            $0.meetingID == envelope.meetingID
                && $0.sourceDeviceID == envelope.sourceDeviceID
        }
    }

    func setReplayCursor(_ envelope: MeetingSyncEnvelope) throws {
        let digest = MeetingSyncEnvelopeCodec.sha256(
            try MeetingSyncEnvelopeCodec.encode(envelope))
        snapshot.replayCursors.removeAll {
            $0.meetingID == envelope.meetingID
                && $0.sourceDeviceID == envelope.sourceDeviceID
        }
        snapshot.replayCursors.append(CloudSyncReplayCursor(
            meetingID: envelope.meetingID,
            sourceDeviceID: envelope.sourceDeviceID,
            generation: envelope.generation,
            payloadSHA256: digest))
    }

    func existingRecord(for meetingID: MeetingID) throws -> CKRecord? {
        guard let metadata = snapshot.recordMetadata.first(where: {
            $0.meetingID == meetingID
        }) else { return nil }
        let record = try CloudRecordSystemFieldsCodec.decode(metadata.systemFields)
        guard record.recordType == CloudMeetingRecordCodec.recordType,
              record.recordID == CloudMeetingRecordCodec.recordID(for: meetingID)
        else {
            throw CloudMeetingTransportError.invalidState(
                "record metadata has the wrong identity")
        }
        return record
    }

    func storeRecordMetadata(_ record: CKRecord, meetingID: MeetingID) throws {
        guard record.recordType == CloudMeetingRecordCodec.recordType,
              record.recordID == CloudMeetingRecordCodec.recordID(for: meetingID)
        else {
            throw CloudMeetingTransportError.invalidState(
                "saved record has the wrong identity")
        }
        snapshot.recordMetadata.removeAll { $0.meetingID == meetingID }
        snapshot.recordMetadata.append(CloudSyncRecordMetadata(
            meetingID: meetingID,
            systemFields: CloudRecordSystemFieldsCodec.encode(record)))
        sortSnapshotCollections()
    }

    func persistSnapshot() throws {
        sortSnapshotCollections()
        try Self.validate(snapshot, payloadDirectory: payloadDirectory)
        try CloudSyncProtectedFile.write(Self.encoder().encode(snapshot), to: stateFileURL)
    }

    func sortSnapshotCollections() {
        snapshot.attempts.sort { $0.meetingID.rawValue.uuidString < $1.meetingID.rawValue.uuidString }
        snapshot.deferredReplays.sort {
            $0.meetingID.rawValue.uuidString < $1.meetingID.rawValue.uuidString
        }
        snapshot.replayCursors.sort {
            let left = "\($0.meetingID.rawValue.uuidString).\($0.sourceDeviceID.uuidString)"
            let right = "\($1.meetingID.rawValue.uuidString).\($1.sourceDeviceID.uuidString)"
            return left < right
        }
        snapshot.recordMetadata.sort {
            $0.meetingID.rawValue.uuidString < $1.meetingID.rawValue.uuidString
        }
    }

}
