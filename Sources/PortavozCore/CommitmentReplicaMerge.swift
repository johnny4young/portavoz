import Foundation

/// Fail-closed conflicts for transport-neutral commitment history. The merge
/// never chooses a replica by wall-clock recency or rewrites append-only truth.
public enum CommitmentReplicaMergeError: Error, Equatable, Sendable {
    case differentCommitment
    case immutableTitleRewrite(CommitmentID)
    case immutableSourceRewrite(CommitmentSourceID)
    case immutableEventRewrite(CommitmentEventID)
    case lifecycleConflict
}

/// Deterministic set-union for two independently advanced commitment replicas.
/// Shared identities must contain byte-equivalent domain values. Disjoint
/// history is admitted only when the combined lifecycle still projects to one
/// valid commitment.
public enum CommitmentReplicaMerge {
    public static func merge(
        local: CommitmentContinuityEnvelope,
        remote: CommitmentContinuityEnvelope
    ) throws -> CommitmentContinuityEnvelope {
        guard local.commitment.id == remote.commitment.id else {
            throw CommitmentReplicaMergeError.differentCommitment
        }
        guard local.commitment.title == remote.commitment.title else {
            throw CommitmentReplicaMergeError.immutableTitleRewrite(local.commitment.id)
        }

        let sources = try mergeSources(local.sources, remote.sources)
        let events = try mergeEvents(local.events, remote.events)
        let commitment: Commitment
        do {
            commitment = try CommitmentContinuityPolicy.projectedCommitment(
                id: local.commitment.id,
                title: local.commitment.title,
                events: events)
            return try CommitmentContinuityEnvelope(
                commitment: commitment,
                sources: sources,
                events: events)
        } catch {
            throw CommitmentReplicaMergeError.lifecycleConflict
        }
    }

    private static func mergeSources(
        _ local: [CommitmentSource],
        _ remote: [CommitmentSource]
    ) throws -> [CommitmentSource] {
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for source in remote {
            if let existing = merged[source.id], existing != source {
                throw CommitmentReplicaMergeError.immutableSourceRewrite(source.id)
            }
            merged[source.id] = source
        }
        return merged.values.sorted(by: CommitmentContinuityPolicy.precedes)
    }

    private static func mergeEvents(
        _ local: [CommitmentEvent],
        _ remote: [CommitmentEvent]
    ) throws -> [CommitmentEvent] {
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for event in remote {
            if let existing = merged[event.id], existing != event {
                throw CommitmentReplicaMergeError.immutableEventRewrite(event.id)
            }
            merged[event.id] = event
        }
        return merged.values.sorted(by: CommitmentContinuityPolicy.precedes)
    }
}
