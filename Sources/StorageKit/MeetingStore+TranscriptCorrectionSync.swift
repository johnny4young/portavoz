import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Unions correction history received while this Mac still has an unsent
    /// live meeting generation. Other aggregate fields remain local-wins.
    /// Any incompatible correction lane throws before a row is changed.
    static func mergeRemoteTranscriptCorrectionHistory(
        _ remoteEvents: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        in database: Database
    ) throws -> Bool {
        let key = meetingID.rawValue.uuidString
        guard let meeting = try MeetingRecord.fetchOne(database, key: key),
              meeting.deletedAt == nil
        else { throw StorageError.meetingNotFound(meetingID) }

        let localEvents = try fetchTranscriptCorrectionHistory(
            meetingID: meetingID,
            in: database)
        let canonicalRemote = remoteEvents.map(canonicalCorrectionForReplicaMerge)
        let merged = try TranscriptCorrectionReplicaMerge.merge(
            local: localEvents,
            remote: canonicalRemote,
            meetingID: meetingID)
        guard merged != localEvents else { return false }

        let previousProjection = try transcriptCorrectionRevision(
            meetingID: meetingID,
            in: database)
        try applyReplicaCorrectionMerge(
            merged,
            replacing: localEvents,
            meetingID: meetingID,
            acceptedRevision: meeting.transcriptRevision,
            in: database)
        let currentProjection = try transcriptCorrectionRevision(
            meetingID: meetingID,
            in: database)
        try invalidateAcceptedOnlyDerivedWork(
            meetingID: meetingID,
            previous: previousProjection,
            current: currentProjection,
            at: merged.map(\.updatedAt).max() ?? Date(),
            in: database)
        try refreshTranscriptCorrectionSearchProjection(
            meetingID: meetingID,
            in: database)
        return true
    }

    private static func applyReplicaCorrectionMerge(
        _ merged: [TranscriptCorrectionEvent],
        replacing localEvents: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        acceptedRevision: Int,
        in database: Database
    ) throws {
        let localByID = Dictionary(uniqueKeysWithValues: localEvents.map { ($0.id, $0) })
        for event in merged {
            if let local = localByID[event.id] {
                try applyReplicaTombstone(event, to: local, in: database)
            } else {
                if event.baseTranscriptRevision == acceptedRevision {
                    try validateReplicaCorrectionAgainstAcceptedTranscript(
                        event,
                        in: database)
                }
                try insertTranscriptCorrection(event, in: database)
            }
        }
        let persisted = try fetchTranscriptCorrectionHistory(
            meetingID: meetingID,
            in: database)
        guard persisted == merged else {
            throw StorageError.invalidTranscriptCorrection(
                "merged correction history did not round-trip exactly")
        }
    }

    private static func applyReplicaTombstone(
        _ event: TranscriptCorrectionEvent,
        to local: TranscriptCorrectionEvent,
        in database: Database
    ) throws {
        guard !sameCorrectionForReplicaMerge(local, event),
              local.deletedAt == nil,
              let deletedAt = event.deletedAt
        else { return }
        try database.execute(
            sql: """
                UPDATE transcriptCorrection
                   SET deletedAt = ?, updatedAt = ?
                 WHERE id = ? AND deletedAt IS NULL
                """,
            arguments: [deletedAt, event.updatedAt, event.id.uuidString])
    }
}
