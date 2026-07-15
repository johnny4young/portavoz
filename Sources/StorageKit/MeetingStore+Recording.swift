import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Atomically installs the discoverable aggregate shell and every pending
    /// source asset before privacy-sensitive capture starts.
    public func beginRecording(_ meeting: Meeting, assets: [AudioAsset]) async throws {
        try Self.validateRecordingReservation(meeting, assets: assets)
        try await database.write { db in
            let key = meeting.id.rawValue.uuidString
            guard try !MeetingRecord.exists(db, key: key) else {
                throw StorageError.invalidRecordingReservation(
                    "meeting \(key) already exists")
            }
            let now = Date()
            let meetingRecord = try MeetingRecord(
                meeting, createdAt: now, updatedAt: now)
            try meetingRecord.insert(db)
            for asset in assets {
                let record = AudioAssetRecord(asset)
                try record.insert(db)
            }
        }
    }

    /// Pending and finalized assets for a live meeting. The live-root check
    /// keeps tombstoned meetings out of normal product projections (Band 0).
    public func audioAssets(for meetingID: MeetingID) async throws -> [AudioAsset] {
        let key = meetingID.rawValue.uuidString
        return try await database.read { db in
            guard
                try MeetingRecord
                    .filter(Column("id") == key)
                    .filter(Column("deletedAt") == nil)
                    .fetchCount(db) > 0
            else { return [] }
            return try AudioAssetRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(Column("channel"), Column("createdAt"))
                .fetchAll(db)
                .map { try $0.asset }
        }
    }

    /// Rolls back a reservation that never became a user meeting. Hard delete
    /// is intentionally limited to a `recording` shell with no persisted user
    /// or generated content; normal meetings continue to use tombstones (D4).
    @discardableResult
    public func discardUnstartedRecording(_ meetingID: MeetingID) async throws -> Bool {
        let key = meetingID.rawValue.uuidString
        return try await database.write { db in
            guard
                let meeting = try MeetingRecord.fetchOne(db, key: key),
                meeting.lifecycleState == MeetingLifecycleState.recording.rawValue
            else { return false }
            let hasContent = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT id FROM speaker WHERE meetingID = ?
                        UNION ALL SELECT id FROM segment WHERE meetingID = ?
                        UNION ALL SELECT id FROM summary WHERE meetingID = ?
                        UNION ALL SELECT id FROM contextItem WHERE meetingID = ?
                        UNION ALL SELECT id FROM companionCard WHERE meetingID = ?
                    )
                    """,
                arguments: [key, key, key, key, key]) ?? false
            guard !hasContent else {
                throw StorageError.invalidRecordingReservation(
                    "a shell with persisted content cannot be discarded")
            }
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [key])
            return db.changesCount > 0
        }
    }

    private static func validateRecordingReservation(
        _ meeting: Meeting,
        assets: [AudioAsset]
    ) throws {
        guard meeting.lifecycleState == .recording else {
            throw StorageError.invalidRecordingReservation(
                "meeting lifecycle must be recording")
        }
        guard meeting.endedAt == nil,
            meeting.language == nil,
            meeting.transcriptRevision == 0,
            meeting.lastProcessingError == nil
        else {
            throw StorageError.invalidRecordingReservation(
                "a new shell cannot contain completion or processing state")
        }
        guard let directory = meeting.audioDirectory else {
            throw StorageError.invalidRecordingReservation(
                "a recording shell requires an audio directory")
        }
        try StoredAudioPath.validate(directory)
        guard !assets.isEmpty else {
            throw StorageError.invalidRecordingReservation(
                "at least one capture asset is required")
        }
        guard Set(assets.map(\.channel)).count == assets.count else {
            throw StorageError.invalidRecordingReservation(
                "capture channels must be unique")
        }
        for asset in assets {
            try StoredAudioPath.validate(asset.relativePath)
            guard asset.meetingID == meeting.id else {
                throw StorageError.invalidRecordingReservation(
                    "every asset must belong to the shell")
            }
            guard asset.role == .capture, asset.healthStatus == .pending else {
                throw StorageError.invalidRecordingReservation(
                    "new capture assets must use capture/pending state")
            }
            guard asset.container == nil,
                asset.codec == nil,
                asset.sampleRate == nil,
                asset.channelCount == nil,
                asset.durationSeconds == nil,
                asset.byteCount == nil,
                asset.sha256 == nil,
                asset.peakDBFS == nil,
                asset.rmsDBFS == nil,
                asset.sourceAssetID == nil,
                asset.supersededAt == nil,
                asset.deletedAt == nil
            else {
                throw StorageError.invalidRecordingReservation(
                    "pending capture assets cannot contain finalized metadata or lineage")
            }
            let expectedPath = "\(directory)/\(asset.channel.rawValue).caf"
            guard asset.relativePath == expectedPath else {
                throw StorageError.invalidRecordingReservation(
                    "asset path must match its reserved capture channel")
            }
        }
    }
}
