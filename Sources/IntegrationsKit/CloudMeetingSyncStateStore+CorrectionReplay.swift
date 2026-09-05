import CloudKit
import Foundation
import PortavozCore
import StorageKit

extension CloudMeetingSyncStateStore {
    public func deferredReplayBlocksOutgoing(for meetingID: MeetingID) -> Bool {
        hasBlockingDeferredReplay(for: meetingID)
    }

    /// Keeps the protected remote payload until the merged local generation
    /// reaches CloudKit, while removing only the fail-closed send fence after
    /// StorageKit proves the correction histories are compatible again.
    public func releaseDeferredReplayBlock(for meetingID: MeetingID) throws {
        let indexes = snapshot.deferredReplays.indices.filter {
            snapshot.deferredReplays[$0].meetingID == meetingID
                && snapshot.deferredReplays[$0].blocksOutgoing
        }
        guard !indexes.isEmpty else { return }
        let obsoleteAttemptFiles = snapshot.attempts
            .filter {
                $0.meetingID == meetingID
                    && $0.phase == .blocked
                    && $0.lastFailure == .serverConflict
            }
            .map(\.payloadFileName)
        try commitSnapshot {
            for index in indexes {
                let replay = snapshot.deferredReplays[index]
                snapshot.deferredReplays[index] = replay.withBlocksOutgoing(false)
            }
            snapshot.attempts.removeAll {
                $0.meetingID == meetingID
                    && $0.phase == .blocked
                    && $0.lastFailure == .serverConflict
            }
        }
        removePayloadFiles(obsoleteAttemptFiles)
    }

    func resolvedExistingAttempt(
        _ prior: CloudSyncAttempt?,
        for envelope: MeetingSyncEnvelope,
        payloadDigest: String,
        at date: Date
    ) throws -> CloudSyncAttempt? {
        guard let prior else { return nil }
        guard prior.sourceDeviceID == envelope.sourceDeviceID else {
            throw CloudMeetingTransportError.generationCollision
        }
        guard envelope.generation >= prior.generation else {
            throw CloudMeetingTransportError.staleGeneration
        }
        guard envelope.generation == prior.generation else { return nil }
        guard prior.payloadSHA256 == payloadDigest else {
            throw CloudMeetingTransportError.generationCollision
        }
        guard prior.phase == .blocked,
              prior.lastFailure == .serverConflict,
              !hasBlockingDeferredReplay(for: envelope.meetingID)
        else { return prior }
        return try reopenAttempt(for: envelope.meetingID, at: date)
    }

    func refreshMatchingDeferredReplay(
        _ prior: CloudSyncDeferredReplay?,
        envelope: MeetingSyncEnvelope,
        payloadDigest: String,
        record: CKRecord,
        blocksOutgoing: Bool
    ) throws -> Bool {
        guard let prior else { return false }
        guard envelope.generation >= prior.generation else {
            throw CloudMeetingTransportError.staleGeneration
        }
        guard envelope.generation == prior.generation else { return false }
        guard payloadDigest == prior.payloadSHA256 else {
            throw CloudMeetingTransportError.generationCollision
        }
        try commitSnapshot {
            if blocksOutgoing, !prior.blocksOutgoing,
               let index = matchingDeferredReplayIndex(for: envelope) {
                snapshot.deferredReplays[index] = prior.withBlocksOutgoing(true)
                blockOutgoingAttempt(for: envelope.meetingID)
            }
            try storeRecordMetadata(record, meetingID: envelope.meetingID)
        }
        return true
    }
}

extension CloudMeetingSyncStateStore {
    func hasBlockingDeferredReplay(for meetingID: MeetingID) -> Bool {
        snapshot.deferredReplays.contains {
            $0.meetingID == meetingID && $0.blocksOutgoing
        }
    }

    func reopenAttempt(
        for meetingID: MeetingID,
        at date: Date
    ) throws -> CloudSyncAttempt {
        var reopened: CloudSyncAttempt?
        try commitSnapshot {
            guard let index = snapshot.attempts.firstIndex(where: {
                $0.meetingID == meetingID
            }) else { return }
            snapshot.attempts[index].phase = .ready
            snapshot.attempts[index].attemptCount = 0
            snapshot.attempts[index].nextRetryAt = date
            snapshot.attempts[index].lastFailure = nil
            reopened = snapshot.attempts[index]
        }
        guard let reopened else {
            throw CloudMeetingTransportError.invalidState(
                "staged attempt disappeared while reopening")
        }
        return reopened
    }

    func matchingDeferredReplayIndex(
        for envelope: MeetingSyncEnvelope
    ) -> Int? {
        snapshot.deferredReplays.firstIndex {
            $0.meetingID == envelope.meetingID
                && $0.sourceDeviceID == envelope.sourceDeviceID
        }
    }

    func blockOutgoingAttempt(for meetingID: MeetingID) {
        guard let index = snapshot.attempts.firstIndex(where: {
            $0.meetingID == meetingID
        }) else { return }
        snapshot.attempts[index].phase = .blocked
        snapshot.attempts[index].attemptCount = max(
            1,
            snapshot.attempts[index].attemptCount)
        snapshot.attempts[index].nextRetryAt = nil
        snapshot.attempts[index].lastFailure = .serverConflict
    }
}

private extension CloudSyncDeferredReplay {
    func withBlocksOutgoing(_ blocksOutgoing: Bool) -> Self {
        CloudSyncDeferredReplay(
            meetingID: meetingID,
            sourceDeviceID: sourceDeviceID,
            generation: generation,
            changedAt: changedAt,
            payloadFileName: payloadFileName,
            payloadSHA256: payloadSHA256,
            payloadByteCount: payloadByteCount,
            blocksOutgoing: blocksOutgoing)
    }
}
