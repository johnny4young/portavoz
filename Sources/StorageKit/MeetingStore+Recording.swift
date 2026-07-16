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
    public let companionArtifacts: [CompanionGenerationArtifact]
    public let companionTerminalRuns: [GenerationRun]

    public init(
        meeting: Meeting,
        assets: [AudioAsset],
        speakers: [Speaker],
        segments: [TranscriptSegment],
        contextItems: [ContextItem],
        companionCards: [CompanionCard],
        companionArtifacts: [CompanionGenerationArtifact] = [],
        companionTerminalRuns: [GenerationRun] = []
    ) {
        self.meeting = meeting
        self.assets = assets
        self.speakers = speakers
        self.segments = segments
        self.contextItems = contextItems
        self.companionCards = companionCards
        self.companionArtifacts = companionArtifacts
        self.companionTerminalRuns = companionTerminalRuns
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
    /// pending reservation with its published/missing state, installs the
    /// provisional live content, and optionally admits its initial derived
    /// work in one Unit of Work. No crash can expose a captured transcript
    /// without the durable job that will continue it.
    @discardableResult
    public func installCapturedSnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        enqueue requests: [ProcessingJobRequest] = [],
        at timestamp: Date = Date()
    ) async throws -> [ProcessingJob] {
        try Self.validateCapturedSnapshot(snapshot)
        if !requests.isEmpty {
            try Self.validateProcessingRequests(requests)
        }
        return try await database.write { db in
            let existingRecord = try Self.matchingRecordingShell(for: snapshot, in: db)
            try Self.validateStoredReservations(for: snapshot, in: db)
            try Self.requireUntouchedShell(snapshot.meeting.id, in: db)
            try Self.writeCapturedSnapshot(
                snapshot, replacing: existingRecord, at: timestamp, in: db)
            let jobs = try requests.map {
                try Self.enqueueProcessingRequest(
                    $0,
                    meetingID: snapshot.meeting.id,
                    timestamp: timestamp,
                    in: db)
            }
            if !jobs.isEmpty {
                try Self.reconcileProcessingLifecycle(
                    for: snapshot.meeting.id, at: timestamp, in: db)
            }
            return jobs
        }
    }

    /// Replaces pending capture rows with filesystem evidence recovered after
    /// the captured snapshot was already installed. Identity and ownership are
    /// immutable, and repeating the exact recovery is a no-op.
    public func installRecoveredCaptureAssets(
        _ assets: [AudioAsset],
        for meetingID: MeetingID,
        at timestamp: Date = Date()
    ) async throws {
        guard !assets.isEmpty,
            Set(assets.map(\.id)).count == assets.count,
            Set(assets.map(\.channel)).count == assets.count
        else {
            throw StorageError.invalidRecordingReservation(
                "recovery requires unique assets and channels")
        }
        let key = meetingID.rawValue.uuidString
        try await database.write { db in
            guard
                let meetingRecord = try MeetingRecord
                    .filter(Column("id") == key)
                    .filter(Column("deletedAt") == nil)
                    .fetchOne(db)
            else { throw StorageError.meetingNotFound(meetingID) }
            let meeting = try meetingRecord.meeting
            let isCompletedCapture = meeting.lifecycleState == .captured
                || meeting.lifecycleState == .processing
                || meeting.lifecycleState == .needsAttention
                || meeting.lifecycleState == .ready
            guard isCompletedCapture,
                let directory = meeting.audioDirectory
            else {
                throw StorageError.invalidRecordingReservation(
                    "only a completed live capture can reconcile recovered assets")
            }
            try StoredAudioPath.validate(directory)
            for asset in assets {
                try Self.installRecoveredAsset(
                    asset,
                    meetingID: meetingID,
                    directory: directory,
                    timestamp: timestamp,
                    allowPendingUpdate: meeting.lifecycleState != .ready,
                    in: db)
            }
            try Self.reconcileLifecycleAfterCaptureRecovery(
                meetingID, timestamp: timestamp, in: db)
        }
    }

    /// Repeat-safe lifecycle transition used when launch recovery cannot
    /// resume work automatically. Only incomplete live aggregates may move to
    /// `needsAttention`; a ready meeting is never downgraded by a stale scan.
    @discardableResult
    public func markMeetingNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date? = nil,
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
            let alreadyMarked =
                record.lifecycleState == MeetingLifecycleState.needsAttention.rawValue
                && record.lastProcessingError == errorCode
            if !alreadyMarked {
                record.lifecycleState = MeetingLifecycleState.needsAttention.rawValue
                record.lastProcessingError = errorCode
                record.updatedAt = timestamp
                try record.update(db)
            }
            return try record.meeting
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
        let isUntouchedRecording = meeting.lifecycleState == .recording
            && meeting.lastProcessingError == nil
        let isInterruptedRecording = meeting.lifecycleState == .needsAttention
            && meeting.lastProcessingError?.hasPrefix("capture.") == true
        let completionMatches = isUntouchedRecording
            ? meeting.endedAt == nil
            : snapshot.meeting.endedAt != nil
        guard isUntouchedRecording || isInterruptedRecording,
            completionMatches,
            meeting.language == nil,
            meeting.transcriptRevision == 0,
            meeting.title == snapshot.meeting.title,
            Self.samePersistedDate(
                meeting.startedAt, snapshot.meeting.startedAt),
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
                Self.samePersistedDate(reservation.createdAt, asset.createdAt)
            else {
                throw StorageError.invalidRecordingReservation(
                    "captured asset does not match its pending reservation")
            }
        }
    }

    /// GRDB's default `Date` representation is UTC text with millisecond
    /// precision. A live reservation still holds the original submillisecond
    /// `Date`, so raw equality can reject the same value immediately after it
    /// was persisted. Compare the exact database representations instead: this
    /// accepts only timestamps that encode to the same durable value.
    private static func samePersistedDate(_ lhs: Date, _ rhs: Date) -> Bool {
        lhs.databaseValue == rhs.databaseValue
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
        at timestamp: Date,
        in db: Database
    ) throws {
        let meetingRecord = try MeetingRecord(
            snapshot.meeting,
            createdAt: existingRecord.createdAt,
            updatedAt: timestamp,
            deletedAt: nil)
        try meetingRecord.update(db)
        for asset in snapshot.assets {
            var record = AudioAssetRecord(asset)
            record.updatedAt = timestamp
            try record.update(db)
        }
        for speaker in snapshot.speakers {
            let record = SpeakerRecord(
                speaker, createdAt: timestamp, updatedAt: timestamp)
            try record.insert(db)
        }
        for segment in snapshot.segments {
            let record = SegmentRecord(
                segment, createdAt: timestamp, updatedAt: timestamp)
            try record.insert(db)
        }
        for item in snapshot.contextItems {
            let record = ContextItemRecord(
                item, createdAt: timestamp, updatedAt: timestamp)
            try record.insert(db)
        }
        for run in snapshot.companionTerminalRuns {
            try GenerationRunRecord(run).insert(db)
        }
        for card in snapshot.companionCards {
            let record = CompanionCardRecord(
                card,
                meetingID: snapshot.meeting.id,
                createdAt: timestamp,
                updatedAt: timestamp)
            try record.insert(db)
        }
        for artifact in snapshot.companionArtifacts {
            try GenerationRunRecord(artifact.generationRun).insert(db)
            let record = CompanionCardRecord(
                artifact.card,
                meetingID: snapshot.meeting.id,
                generationRunID: artifact.generationRun.id,
                createdAt: timestamp,
                updatedAt: timestamp)
            try record.insert(db)
        }
    }

    private static func validateCapturedSnapshot(
        _ snapshot: CapturedMeetingSnapshot
    ) throws {
        let meeting = snapshot.meeting
        let isCaptured = meeting.lifecycleState == .captured
            && meeting.lastProcessingError == nil
        let isRecovered = meeting.lifecycleState == .needsAttention
            && (meeting.lastProcessingError == "transcription.empty"
                || meeting.lastProcessingError == "processing.enqueue.failed"
                || meeting.lastProcessingError?.hasPrefix("capture.") == true)
        guard isCaptured || isRecovered,
            let endedAt = meeting.endedAt,
            endedAt >= meeting.startedAt,
            meeting.transcriptRevision == 0,
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

        try validateCapturedCompanionProvenance(snapshot)

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

    private static func installRecoveredAsset(
        _ asset: AudioAsset,
        meetingID: MeetingID,
        directory: String,
        timestamp: Date,
        allowPendingUpdate: Bool,
        in db: Database
    ) throws {
        try StoredAudioPath.validate(asset.relativePath)
        guard asset.meetingID == meetingID,
            asset.role == .capture,
            asset.sourceAssetID == nil,
            asset.supersededAt == nil,
            asset.deletedAt == nil
        else {
            throw StorageError.invalidRecordingReservation(
                "recovered assets must preserve capture ownership")
        }
        if isPublished(asset.healthStatus) {
            try validatePublished(asset, directory: directory)
        } else {
            try validateRecoveredMissing(asset, directory: directory)
        }

        let assetKey = asset.id.rawValue.uuidString
        guard var stored = try AudioAssetRecord.fetchOne(db, key: assetKey),
            stored.meetingID == meetingID.rawValue.uuidString,
            stored.channel == asset.channel.rawValue,
            stored.role == AudioAssetRole.capture.rawValue,
            stored.createdAt == asset.createdAt,
            stored.deletedAt == nil
        else {
            throw StorageError.invalidRecordingReservation(
                "recovered asset does not match its persisted identity")
        }
        if stored.healthStatus != AudioAssetHealthStatus.pending.rawValue {
            guard try recoveryEvidenceMatches(stored, asset: asset) else {
                throw StorageError.invalidRecordingReservation(
                    "recovery cannot replace finalized asset evidence")
            }
            return
        }
        guard allowPendingUpdate else {
            throw StorageError.invalidRecordingReservation(
                "recovery cannot mutate pending evidence on a ready meeting")
        }
        guard stored.relativePath == AudioCapturePath.stagingRelativePath(
            directory: directory, channel: asset.channel),
            stored.container == nil,
            stored.codec == nil,
            stored.sampleRate == nil,
            stored.channelCount == nil,
            stored.durationSeconds == nil,
            stored.byteCount == nil,
            stored.sha256 == nil,
            stored.peakDBFS == nil,
            stored.rmsDBFS == nil,
            stored.sourceAssetID == nil,
            stored.supersededAt == nil
        else {
            throw StorageError.invalidRecordingReservation(
                "only an intact pending reservation can be recovered")
        }
        stored = AudioAssetRecord(asset)
        stored.updatedAt = timestamp
        try stored.update(db)
    }

    private static func validateRecoveredMissing(
        _ asset: AudioAsset,
        directory: String
    ) throws {
        guard asset.healthStatus == .missing,
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
                "a recovered missing asset must remain metadata-free")
        }
    }

    private static func recoveryEvidenceMatches(
        _ stored: AudioAssetRecord,
        asset: AudioAsset
    ) throws -> Bool {
        let persisted = try stored.asset
        return persisted.id == asset.id
            && persisted.meetingID == asset.meetingID
            && persisted.channel == asset.channel
            && persisted.role == asset.role
            && persisted.relativePath == asset.relativePath
            && persisted.container == asset.container
            && persisted.codec == asset.codec
            && persisted.sampleRate == asset.sampleRate
            && persisted.channelCount == asset.channelCount
            && persisted.durationSeconds == asset.durationSeconds
            && persisted.byteCount == asset.byteCount
            && persisted.sha256 == asset.sha256
            && persisted.healthStatus == asset.healthStatus
            && persisted.peakDBFS == asset.peakDBFS
            && persisted.rmsDBFS == asset.rmsDBFS
            && persisted.sourceAssetID == asset.sourceAssetID
            && persisted.createdAt == asset.createdAt
            && persisted.supersededAt == asset.supersededAt
            && persisted.deletedAt == asset.deletedAt
    }

    private static func isCanonicalRecoveryCode(_ value: String) -> Bool {
        let isKnown = value.hasPrefix("capture.")
            || value == "transcription.empty"
            || value == "processing.interrupted"
        return isKnown
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reconcileLifecycleAfterCaptureRecovery(
        _ meetingID: MeetingID,
        timestamp: Date,
        in db: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
        guard var meeting = try MeetingRecord.fetchOne(db, key: key),
            meeting.lifecycleState == MeetingLifecycleState.needsAttention.rawValue,
            meeting.lastProcessingError == "capture.publication.failed"
        else { return }
        let pendingCount = try AudioAssetRecord
            .filter(Column("meetingID") == key)
            .filter(Column("deletedAt") == nil)
            .filter(Column("healthStatus") == AudioAssetHealthStatus.pending.rawValue)
            .fetchCount(db)
        let segmentCount = try SegmentRecord
            .filter(Column("meetingID") == key)
            .filter(Column("deletedAt") == nil)
            .fetchCount(db)
        let blockingJobCount = try ProcessingJobRecord
            .filter(Column("meetingID") == key)
            .filter([
                ProcessingJobState.pending.rawValue,
                ProcessingJobState.running.rawValue,
                ProcessingJobState.failed.rawValue
            ].contains(Column("state")))
            .fetchCount(db)
        guard pendingCount == 0, segmentCount > 0, blockingJobCount == 0 else { return }
        meeting.lifecycleState = MeetingLifecycleState.ready.rawValue
        meeting.lastProcessingError = nil
        meeting.updatedAt = timestamp
        try meeting.update(db)
    }
}
