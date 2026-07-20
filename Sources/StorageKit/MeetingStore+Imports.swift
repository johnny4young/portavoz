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
        let segmentIDs = Set(snapshot.segments.map(\.id))
        guard speakerIDs.count == snapshot.speakers.count,
            snapshot.speakers.allSatisfy({ $0.meetingID == meetingID })
        else {
            throw StorageError.invalidImportedMeeting(
                "speaker IDs must be unique and belong to the imported meeting")
        }
        guard segmentIDs.count == snapshot.segments.count,
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
            segments: segmentIDs)
        guard Set(snapshot.contextItems.map(\.id)).count == snapshot.contextItems.count,
            snapshot.contextItems.allSatisfy({ $0.meetingID == meetingID })
        else {
            throw StorageError.invalidImportedMeeting(
                "notes must be unique and belong to the imported meeting")
        }
        let validCompanionEvidence = snapshot.companionCards.allSatisfy {
            validImportedCompanionEvidence(
                $0,
                transcriptRevision: snapshot.meeting.transcriptRevision,
                segmentIDs: segmentIDs)
        }
        guard Set(snapshot.companionCards.map(\.id)).count == snapshot.companionCards.count,
              validCompanionEvidence
        else {
            throw StorageError.invalidImportedMeeting(
                "Companion card IDs and evidence must belong to the imported aggregate")
        }
    }

    private static func validImportedCompanionEvidence(
        _ card: CompanionCard,
        transcriptRevision: Int,
        segmentIDs: Set<UUID>
    ) -> Bool {
        guard let evidence = card.evidence else { return true }
        let questionsAreValid = !evidence.questionSegmentIDs.isEmpty
            && Set(evidence.questionSegmentIDs).count == evidence.questionSegmentIDs.count
        let answersAreValid = Set(evidence.answerSegmentIDs).count
            == evidence.answerSegmentIDs.count
        let revisionMatches = evidence.sourceTranscriptRevision == nil
            || evidence.sourceTranscriptRevision == transcriptRevision
        let allIDs = evidence.questionSegmentIDs + evidence.answerSegmentIDs
        return evidence.cardID == card.id
            && evidence.unavailableQuestionCount == 0
            && evidence.unavailableAnswerCount == 0
            && questionsAreValid
            && answersAreValid
            && revisionMatches
            && allIDs.allSatisfy(segmentIDs.contains)
    }

    private static func validateImportedSummary(
        _ summary: SummaryDraft?,
        meetingID: MeetingID,
        cast: Set<SpeakerID>,
        segments: Set<UUID>
    ) throws {
        guard let summary else { return }
        let actionItemIDs = Set(summary.actionItems.map(\.id))
        guard summary.meetingID == meetingID,
            actionItemIDs.count == summary.actionItems.count,
            summary.actionItems.allSatisfy({ item in
                item.ownerSpeakerID.map(cast.contains) ?? true
            }),
            Set(summary.actionItemEvidence.map(\.id)).count
                == summary.actionItemEvidence.count,
            Set(summary.actionItemEvidence.map(\.actionItemID)).count
                == summary.actionItemEvidence.count,
            summary.actionItemEvidence.allSatisfy({ evidence in
                actionItemIDs.contains(evidence.actionItemID)
                    && evidence.unavailableEvidenceCount == 0
                    && !evidence.evidenceSegmentIDs.isEmpty
                    && Set(evidence.evidenceSegmentIDs).count
                        == evidence.evidenceSegmentIDs.count
                    && evidence.evidenceSegmentIDs.allSatisfy(segments.contains)
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
            try replaceCompanionCardEvidence(
                card.evidence,
                cardID: card.id,
                meetingID: snapshot.meeting.id,
                at: timestamp,
                in: db)
        }
    }
}
