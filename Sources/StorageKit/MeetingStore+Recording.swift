import Foundation
import GRDB
import PortavozCore

/// The first durable post-capture projection. Every member is installed in
/// one SQLite transaction so Library/Detail never observe a meeting without
/// its matching assets and live meeting content.
public struct CapturedMeetingSnapshot: Sendable {
    public let meeting: Meeting
    public let assets: [AudioAsset]
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]

    public init(
        meeting: Meeting,
        assets: [AudioAsset],
        speakers: [Speaker],
        segments: [TranscriptSegment],
        contextItems: [ContextItem],
        companionCards: [CompanionCard]
    ) {
        self.meeting = meeting
        self.assets = assets
        self.speakers = speakers
        self.segments = segments
        self.contextItems = contextItems
        self.companionCards = companionCards
    }
}

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

    /// Advances an untouched recording shell to `captured`, replaces every
    /// pending reservation with its published/missing state, and installs the
    /// provisional live cast, transcript, notes, and Companion cards as one
    /// Unit of Work. Later diarization may atomically replace the cast.
    public func installCapturedSnapshot(_ snapshot: CapturedMeetingSnapshot) async throws {
        try Self.validateCapturedSnapshot(snapshot)
        try await database.write { db in
            let existingRecord = try Self.matchingRecordingShell(for: snapshot, in: db)
            try Self.validateStoredReservations(for: snapshot, in: db)
            try Self.requireUntouchedShell(snapshot.meeting.id, in: db)
            try Self.writeCapturedSnapshot(snapshot, replacing: existingRecord, in: db)
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
            let expectedPath = AudioCapturePath.stagingRelativePath(
                directory: directory, channel: asset.channel)
            guard asset.relativePath == expectedPath else {
                throw StorageError.invalidRecordingReservation(
                    "asset path must match its reserved capture channel")
            }
        }
    }

    private static func matchingRecordingShell(
        for snapshot: CapturedMeetingSnapshot,
        in db: Database
    ) throws -> MeetingRecord {
        let key = snapshot.meeting.id.rawValue.uuidString
        guard
            let record = try MeetingRecord.fetchOne(db, key: key),
            record.deletedAt == nil
        else { throw StorageError.meetingNotFound(snapshot.meeting.id) }
        let meeting = try record.meeting
        guard meeting.lifecycleState == .recording,
            meeting.endedAt == nil,
            meeting.language == nil,
            meeting.transcriptRevision == 0,
            meeting.lastProcessingError == nil,
            meeting.title == snapshot.meeting.title,
            meeting.startedAt == snapshot.meeting.startedAt,
            meeting.audioDirectory == snapshot.meeting.audioDirectory,
            meeting.retention == snapshot.meeting.retention,
            meeting.visibility == snapshot.meeting.visibility
        else {
            throw StorageError.invalidRecordingReservation(
                "captured snapshot does not match its recording shell")
        }
        return record
    }

    private static func validateStoredReservations(
        for snapshot: CapturedMeetingSnapshot,
        in db: Database
    ) throws {
        let key = snapshot.meeting.id.rawValue.uuidString
        let reservations = try AudioAssetRecord
            .filter(Column("meetingID") == key)
            .filter(Column("deletedAt") == nil)
            .fetchAll(db)
        guard Set(reservations.map(\.id)) == Set(snapshot.assets.map {
            $0.id.rawValue.uuidString
        }) else {
            throw StorageError.invalidRecordingReservation(
                "captured assets must exactly match reserved asset IDs")
        }
        let byID = Dictionary(uniqueKeysWithValues: reservations.map { ($0.id, $0) })
        for asset in snapshot.assets {
            guard let reservation = byID[asset.id.rawValue.uuidString],
                reservation.channel == asset.channel.rawValue,
                reservation.role == AudioAssetRole.capture.rawValue,
                reservation.healthStatus == AudioAssetHealthStatus.pending.rawValue,
                reservation.relativePath == AudioCapturePath.stagingRelativePath(
                    directory: snapshot.meeting.audioDirectory ?? "",
                    channel: asset.channel),
                reservation.createdAt == asset.createdAt
            else {
                throw StorageError.invalidRecordingReservation(
                    "captured asset does not match its pending reservation")
            }
        }
    }

    private static func requireUntouchedShell(
        _ meetingID: MeetingID,
        in db: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
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
                "captured snapshot can only install into an untouched shell")
        }
    }

    private static func writeCapturedSnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        replacing existingRecord: MeetingRecord,
        in db: Database
    ) throws {
        let now = Date()
        let meetingRecord = try MeetingRecord(
            snapshot.meeting,
            createdAt: existingRecord.createdAt,
            updatedAt: now,
            deletedAt: nil)
        try meetingRecord.update(db)
        for asset in snapshot.assets {
            var record = AudioAssetRecord(asset)
            record.updatedAt = now
            try record.update(db)
        }
        for speaker in snapshot.speakers {
            let record = SpeakerRecord(speaker, createdAt: now, updatedAt: now)
            try record.insert(db)
        }
        for segment in snapshot.segments {
            let record = SegmentRecord(segment, createdAt: now, updatedAt: now)
            try record.insert(db)
        }
        for item in snapshot.contextItems {
            let record = ContextItemRecord(item, createdAt: now, updatedAt: now)
            try record.insert(db)
        }
        for card in snapshot.companionCards {
            let record = CompanionCardRecord(
                card,
                meetingID: snapshot.meeting.id,
                createdAt: now,
                updatedAt: now)
            try record.insert(db)
        }
    }

    private static func validateCapturedSnapshot(
        _ snapshot: CapturedMeetingSnapshot
    ) throws {
        let meeting = snapshot.meeting
        guard meeting.lifecycleState == .captured,
            let endedAt = meeting.endedAt,
            endedAt >= meeting.startedAt,
            meeting.transcriptRevision == 0,
            meeting.lastProcessingError == nil,
            let directory = meeting.audioDirectory
        else {
            throw StorageError.invalidRecordingReservation(
                "captured snapshot requires a completed captured meeting")
        }
        try StoredAudioPath.validate(directory)
        guard !snapshot.assets.isEmpty,
            Set(snapshot.assets.map(\.channel)).count == snapshot.assets.count,
            snapshot.assets.contains(where: { Self.isPublished($0.healthStatus) })
        else {
            throw StorageError.invalidRecordingReservation(
                "captured snapshot requires unique assets and one published channel")
        }

        try validateCapturedContent(snapshot)

        for asset in snapshot.assets {
            try StoredAudioPath.validate(asset.relativePath)
            guard asset.meetingID == meeting.id,
                asset.role == .capture,
                asset.sourceAssetID == nil,
                asset.supersededAt == nil,
                asset.deletedAt == nil
            else {
                throw StorageError.invalidRecordingReservation(
                    "captured assets must preserve reservation ownership")
            }
            if isPublished(asset.healthStatus) {
                try validatePublished(asset, directory: directory)
            } else {
                guard asset.healthStatus == .pending || asset.healthStatus == .missing,
                    asset.relativePath == AudioCapturePath.stagingRelativePath(
                        directory: directory, channel: asset.channel),
                    asset.container == nil,
                    asset.codec == nil,
                    asset.sampleRate == nil,
                    asset.channelCount == nil,
                    asset.durationSeconds == nil,
                    asset.byteCount == nil,
                    asset.sha256 == nil,
                    asset.peakDBFS == nil,
                    asset.rmsDBFS == nil
                else {
                    throw StorageError.invalidRecordingReservation(
                        "unpublished assets must remain metadata-free staging rows")
                }
            }
        }
    }

    private static func validateCapturedContent(
        _ snapshot: CapturedMeetingSnapshot
    ) throws {
        let speakerIDs = Set(snapshot.speakers.map(\.id))
        guard snapshot.speakers.allSatisfy({ $0.meetingID == snapshot.meeting.id }),
            snapshot.segments.allSatisfy({ segment in
                segment.meetingID == snapshot.meeting.id
                    && segment.speakerID.map(speakerIDs.contains) ?? true
            }),
            snapshot.contextItems.allSatisfy({ $0.meetingID == snapshot.meeting.id })
        else {
            throw StorageError.invalidRecordingReservation(
                "captured content must belong to the meeting and its cast")
        }
    }

    private static func validatePublished(_ asset: AudioAsset, directory: String) throws {
        guard asset.relativePath == AudioCapturePath.publishedRelativePath(
            directory: directory, channel: asset.channel),
            asset.container == "caf",
            asset.codec == "pcm-s16le",
            let sampleRate = asset.sampleRate,
            sampleRate.isFinite,
            sampleRate > 0,
            let channelCount = asset.channelCount,
            channelCount == 1,
            let duration = asset.durationSeconds,
            duration.isFinite,
            duration > 0,
            let byteCount = asset.byteCount,
            byteCount > 0,
            let checksum = asset.sha256,
            checksum.count == 64,
            checksum.allSatisfy({ character in
                ("0"..."9").contains(String(character))
                    || ("a"..."f").contains(String(character))
            }),
            let peak = asset.peakDBFS,
            peak.isFinite,
            let rms = asset.rmsDBFS,
            rms.isFinite
        else {
            throw StorageError.invalidRecordingReservation(
                "published assets require complete validated CAF metadata")
        }
    }

    private static func isPublished(_ health: AudioAssetHealthStatus) -> Bool {
        health == .healthy || health == .silent || health == .clipped
    }
}
