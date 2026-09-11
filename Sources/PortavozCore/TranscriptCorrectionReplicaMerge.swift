import Foundation

/// A correction conflict that cannot be resolved without choosing between two
/// pieces of user-authored transcript truth.
public enum TranscriptCorrectionReplicaMergeError: Error, Equatable, Sendable {
    case immutableRewrite(UUID)
    case divergentTombstone(UUID)
}

/// Deterministic, transport-neutral merge for immutable correction histories.
///
/// Disjoint correction lanes converge by set union. Matching event identities
/// must carry identical immutable material, and a tombstone wins only as the
/// monotonic state transition already defined by `TranscriptCorrectionPolicy`.
/// The final history is validated as one unit, so competing text or structural
/// lanes fail closed instead of silently selecting one device's edit.
public enum TranscriptCorrectionReplicaMerge {
    public static func merge(
        local: [TranscriptCorrectionEvent],
        remote: [TranscriptCorrectionEvent],
        meetingID: MeetingID
    ) throws -> [TranscriptCorrectionEvent] {
        try TranscriptCorrectionPolicy.validateHistory(local, meetingID: meetingID)
        try TranscriptCorrectionPolicy.validateHistory(remote, meetingID: meetingID)

        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for remoteEvent in remote {
            guard let localEvent = merged[remoteEvent.id] else {
                merged[remoteEvent.id] = remoteEvent
                continue
            }
            guard TranscriptCorrectionPolicy.immutableDifference(
                localEvent,
                remoteEvent) == nil
            else {
                throw TranscriptCorrectionReplicaMergeError.immutableRewrite(
                    remoteEvent.id)
            }
            merged[remoteEvent.id] = try mergeMatchingEvent(
                local: localEvent,
                remote: remoteEvent)
        }

        let result = merged.values.sorted(by: TranscriptCorrectionPolicy.precedes)
        try TranscriptCorrectionPolicy.validateHistory(result, meetingID: meetingID)
        return result
    }

    private static func mergeMatchingEvent(
        local: TranscriptCorrectionEvent,
        remote: TranscriptCorrectionEvent
    ) throws -> TranscriptCorrectionEvent {
        switch (local.deletedAt, remote.deletedAt) {
        case (nil, nil):
            do {
                try TranscriptCorrectionPolicy.validateTombstoneTransition(
                    from: local,
                    to: remote)
            } catch {
                throw TranscriptCorrectionReplicaMergeError.divergentTombstone(
                    remote.id)
            }
            return local

        case (nil, .some):
            do {
                try TranscriptCorrectionPolicy.validateTombstoneTransition(
                    from: local,
                    to: remote)
            } catch {
                throw TranscriptCorrectionReplicaMergeError.divergentTombstone(
                    remote.id)
            }
            return remote

        case (.some, nil):
            do {
                try TranscriptCorrectionPolicy.validateTombstoneTransition(
                    from: remote,
                    to: local)
            } catch {
                throw TranscriptCorrectionReplicaMergeError.divergentTombstone(
                    remote.id)
            }
            return local

        case (.some(let localDeletedAt), .some(let remoteDeletedAt)):
            guard TranscriptCorrectionPolicy.samePersistedInstant(
                localDeletedAt,
                remoteDeletedAt),
                TranscriptCorrectionPolicy.samePersistedInstant(
                    local.updatedAt,
                    remote.updatedAt)
            else {
                throw TranscriptCorrectionReplicaMergeError.divergentTombstone(
                    remote.id)
            }
            return local
        }
    }
}
