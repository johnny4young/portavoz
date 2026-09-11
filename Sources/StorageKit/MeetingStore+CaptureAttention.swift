import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Repeat-safe lifecycle transition used when launch recovery cannot
    /// resume work automatically. Only incomplete live aggregates may move to
    /// `needsAttention`; a ready meeting is never downgraded by a stale scan.
    @discardableResult
    public func markMeetingNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date? = nil,
        captureReport: CaptureReport? = nil,
        at timestamp: Date = Date()
    ) async throws -> Meeting {
        guard Self.isCanonicalRecoveryCode(errorCode) else {
            throw StorageError.invalidRecordingReservation(
                "recovery error code must be canonical and non-empty")
        }
        let key = meetingID.rawValue.uuidString
        return try await database.write { db in
            guard var record = try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { throw StorageError.meetingNotFound(meetingID) }
            guard record.lifecycleState == MeetingLifecycleState.recording.rawValue
                || record.lifecycleState == MeetingLifecycleState.captured.rawValue
                || record.lifecycleState == MeetingLifecycleState.processing.rawValue
                || record.lifecycleState == MeetingLifecycleState.needsAttention.rawValue
            else {
                throw StorageError.invalidRecordingReservation(
                    "a ready meeting cannot be downgraded by launch recovery")
            }
            if record.lifecycleState == MeetingLifecycleState.recording.rawValue {
                let recoveredEnd = max(endedAt ?? record.startedAt, record.startedAt)
                record.endedAt = record.endedAt ?? recoveredEnd
            }
            let reportData = try captureReport.map(MeetingRecord.encodeCaptureReport)
            let alreadyMarked =
                record.lifecycleState == MeetingLifecycleState.needsAttention.rawValue
                && record.lastProcessingError == errorCode
                && (reportData == nil || record.captureReport == reportData)
            if !alreadyMarked {
                record.lifecycleState = MeetingLifecycleState.needsAttention.rawValue
                record.lastProcessingError = errorCode
                if let reportData { record.captureReport = reportData }
                record.updatedAt = timestamp
                try record.update(db)
            }
            return try record.meeting
        }
    }

    private static func isCanonicalRecoveryCode(_ value: String) -> Bool {
        let isKnown = value.hasPrefix("capture.")
            || value == "transcription.empty"
            || value == "processing.interrupted"
        return isKnown
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
