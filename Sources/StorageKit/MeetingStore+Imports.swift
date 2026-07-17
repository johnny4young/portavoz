import Foundation
import GRDB
import PortavozCore

/// Complete user-authored content carried by one `.portavoz` document.
/// Storage installs every row in one transaction so the Library never sees
/// only part of an imported meeting.
public struct ImportedMeetingBundleSnapshot: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        contextItems: [ContextItem],
        companionCards: [CompanionCard]
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.contextItems = contextItems
        self.companionCards = companionCards
    }
}

extension MeetingStore {
    /// Installs a completed imported meeting, cast, and transcript in one
    /// transaction. A child failure cannot expose a partial library entry.
    public func saveImportedMeeting(
        _ meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) async throws {
        try await saveImportedMeetingBundle(
            ImportedMeetingBundleSnapshot(
                meeting: meeting,
                speakers: speakers,
                segments: segments,
                summary: nil,
                contextItems: [],
                companionCards: []),
            at: Date())
    }

    /// Installs the complete `.portavoz` aggregate as one Unit of Work.
    public func saveImportedMeetingBundle(
        _ snapshot: ImportedMeetingBundleSnapshot,
        at timestamp: Date
    ) async throws {
        try Self.validateImportedMeetingBundle(snapshot)
        try await database.write { db in
            try Self.insertImportedMeetingBundle(snapshot, at: timestamp, in: db)
        }
    }

    private static func validateImportedMeetingBundle(
        _ snapshot: ImportedMeetingBundleSnapshot
    ) throws {
        if let path = snapshot.meeting.audioDirectory {
            try StoredAudioPath.validate(path)
        }
        let meetingID = snapshot.meeting.id
        let speakerIDs = Set(snapshot.speakers.map(\.id))
        guard speakerIDs.count == snapshot.speakers.count,
            snapshot.speakers.allSatisfy({ $0.meetingID == meetingID })
        else {
            throw StorageError.invalidImportedMeeting(
                "speaker IDs must be unique and belong to the imported meeting")
        }
        guard Set(snapshot.segments.map(\.id)).count == snapshot.segments.count,
            snapshot.segments.allSatisfy({ segment in
                segment.meetingID == meetingID
                    && segment.speakerID.map(speakerIDs.contains) ?? true
            })
        else {
            throw StorageError.invalidImportedMeeting(
                "segments must be unique, belong to the meeting, and reference its cast")
        }
        try validateImportedSummary(
            snapshot.summary,
            meetingID: meetingID,
            cast: speakerIDs,
            segments: Set(snapshot.segments.map(\.id)))
        guard Set(snapshot.contextItems.map(\.id)).count == snapshot.contextItems.count,
            snapshot.contextItems.allSatisfy({ $0.meetingID == meetingID })
        else {
            throw StorageError.invalidImportedMeeting(
                "notes must be unique and belong to the imported meeting")
        }
        guard Set(snapshot.companionCards.map(\.id)).count == snapshot.companionCards.count else {
            throw StorageError.invalidImportedMeeting("Companion card IDs must be unique")
        }
    }

    private static func validateImportedSummary(
        _ summary: SummaryDraft?,
        meetingID: MeetingID,
        cast: Set<SpeakerID>,
        segments: Set<UUID>
    ) throws {
        guard let summary else { return }
        guard summary.meetingID == meetingID,
            Set(summary.actionItems.map(\.id)).count == summary.actionItems.count,
            summary.actionItems.allSatisfy({ item in
                item.ownerSpeakerID.map(cast.contains) ?? true
            }),
            summary.claims.count <= 1,
            Set(summary.claims.map(\.id)).count == summary.claims.count,
            summary.claims.allSatisfy({ claim in
                claim.kind == .overview
                    && claim.unavailableEvidenceCount == 0
                    && !claim.evidenceSegmentIDs.isEmpty
                    && Set(claim.evidenceSegmentIDs).count == claim.evidenceSegmentIDs.count
                    && claim.evidenceSegmentIDs.allSatisfy(segments.contains)
            })
        else {
            throw StorageError.invalidImportedMeeting(
                "summary, action items, and evidence must belong to the imported aggregate")
        }
    }

    private static func insertImportedMeetingBundle(
        _ snapshot: ImportedMeetingBundleSnapshot,
        at timestamp: Date,
        in db: Database
    ) throws {
        let meetingKey = snapshot.meeting.id.rawValue.uuidString
        guard try !MeetingRecord.exists(db, key: meetingKey) else {
            throw StorageError.invalidImportedMeeting("meeting ID already exists")
        }
        try MeetingRecord(
            snapshot.meeting,
            createdAt: timestamp,
            updatedAt: timestamp)
            .insert(db)
        for speaker in snapshot.speakers {
            try SpeakerRecord(speaker, createdAt: timestamp, updatedAt: timestamp).insert(db)
        }
        for segment in snapshot.segments {
            try SegmentRecord(segment, createdAt: timestamp, updatedAt: timestamp).insert(db)
        }
        if let summary = snapshot.summary {
            _ = try insertSummarySnapshot(
                summary,
                at: timestamp,
                allowClaimFeedback: true,
                in: db)
        }
        for item in snapshot.contextItems {
            try ContextItemRecord(item, createdAt: timestamp, updatedAt: timestamp).insert(db)
        }
        for card in snapshot.companionCards {
            try CompanionCardRecord(
                card,
                meetingID: snapshot.meeting.id,
                createdAt: timestamp,
                updatedAt: timestamp)
                .insert(db)
        }
    }
}
