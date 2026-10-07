import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public func observeAudioImportQueue(offset: Int, limit: Int = 20)
        -> AsyncThrowingStream<AudioImportQueuePage, Error> {
        observedStream(ValueObservation.tracking(
            regions: [Table("meeting"), Table("processingJob"), Table("audioImportInput")],
            fetch: { try Self.fetchAudioImportQueue(offset: offset, limit: limit, in: $0) }))
    }

    public func audioImportQueuePage(offset: Int = 0, limit: Int = 20) async throws -> AudioImportQueuePage {
        try await database.read { try Self.fetchAudioImportQueue(offset: offset, limit: limit, in: $0) }
    }

    private static func fetchAudioImportQueue(offset: Int, limit: Int, in db: Database) throws -> AudioImportQueuePage {
        guard offset >= 0, limit > 0, limit <= 50 else {
            throw StorageError.invalidProcessingJob("invalid import queue page")
        }
        let source = """
            FROM audioImportInput AS input
            JOIN processingJob AS job ON job.id = input.jobID AND job.meetingID = input.meetingID
            JOIN meeting ON meeting.id = input.meetingID
            WHERE meeting.deletedAt IS NULL AND job.kind = 'audio-import'
            """
        let count = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(job.state IN ('pending', 'running')), 0) AS unfinished
            \(source)
            """)
        let entries = try Row.fetchAll(db, sql: """
            SELECT job.*, meeting.title AS meetingTitle,
                   input.meetingID AS importMeetingID, input.jobID AS importJobID,
                   input.inputFingerprint AS importInputFingerprint,
                   input.payloadDigest AS importPayloadDigest, input.payload AS importPayload
            \(source)
            ORDER BY CASE WHEN job.state IN ('pending', 'running') THEN 0 ELSE 1 END,
                     job.createdAt DESC, job.id DESC
            LIMIT ? OFFSET ?
            """, arguments: [limit, offset]).map { row in
            let job = try ProcessingJobRecord(row: row).job
            // The joined input already answers retryability: a retired source cannot be retried.
            let input = AudioImportInputRecord(
                meetingID: row["importMeetingID"], jobID: row["importJobID"],
                inputFingerprint: row["importInputFingerprint"],
                payloadDigest: row["importPayloadDigest"], payload: row["importPayload"])
            let canRetry = (try? input.decoded())?.canResume ?? false
            return AudioImportQueueEntry(title: row["meetingTitle"], job: job, canRetry: canRetry)
        }
        return AudioImportQueuePage(entries: entries, total: count?["total"] ?? 0,
                                    unfinished: count?["unfinished"] ?? 0, offset: offset)
    }
}
