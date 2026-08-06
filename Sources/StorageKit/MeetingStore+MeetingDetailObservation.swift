import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Storage-edge projection mapped into ApplicationKit by the app adapter.
    public struct MeetingReviewCore: Sendable {
        public let meeting: Meeting
        public let speakers: [Speaker]
        public let segments: [TranscriptSegment]
        public let corrections: [TranscriptCorrectionEvent]
        public let correctionRevision: TranscriptCorrectionRevision
        public let isRefinedTranscript: Bool
    }

    public struct MeetingReviewSummarySnapshot: Sendable {
        public let draft: SummaryDraft
        public let version: Int
        public let correctionSource: TranscriptCorrectionArtifactSource
    }

    public struct MeetingReviewCompanionSnapshot: Sendable {
        public let cards: [CompanionCard]
        public let correctionSources: [UUID: TranscriptCorrectionArtifactSource]
    }

    /// Transcript/cast observation for one meeting. Summary and Companion
    /// writes cannot invalidate this projection.
    public func observeMeetingReviewCore(
        _ id: MeetingID
    ) -> AsyncThrowingStream<MeetingReviewCore?, Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("speaker"), Table("segment"),
                Table("transcriptCorrection"), Table("transcriptCorrectionTarget"),
                Table("transcriptCorrectionPayload"), Table("transcriptCorrectionPart")
            ],
            fetch: { database -> MeetingReviewCore? in
                try Self.fetchMeetingReviewCore(id, in: database)
            })
        return observedStream(observation)
    }

    /// Newest immutable summary across recipes, including current action-item
    /// state. Transcript and Companion writes cannot invalidate it.
    public func observeMeetingReviewSummary(
        _ id: MeetingID
    ) -> AsyncThrowingStream<MeetingReviewSummarySnapshot?, Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("summary"), Table("actionItem"),
                Table("summaryClaim"), Table("summaryClaimSegment"),
                Table("summaryClaimFeedback"), Table("summaryDecisionEvidence"),
                Table("summaryDecisionEvidenceSegment"), Table("summaryActionItemEvidence"),
                Table("summaryActionItemEvidenceSegment"), Table("generationRun")
            ],
            fetch: { database in
                try Self.fetchMeetingReviewSummary(id, in: database)
            })
        return observedStream(observation)
    }

    /// The user's notes (raw context items + the enhanced document) refresh
    /// independently: a notes failure degrades only its own section, never
    /// the transcript root.
    public func observeMeetingReviewNotes(
        _ id: MeetingID
    ) -> AsyncThrowingStream<(items: [ContextItem], enhanced: EnhancedNote?), Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("contextItem"), Table("enhancedNote")
            ],
            fetch: { database in
                try Self.fetchMeetingReviewNotes(id, in: database)
            })
        return observedStream(observation)
    }

    /// Persisted Companion evidence is independent from cast and summary
    /// reads, so deleting a card refreshes only the right-rail projection.
    public func observeMeetingReviewCompanionCards(
        _ id: MeetingID
    ) -> AsyncThrowingStream<MeetingReviewCompanionSnapshot, Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("companionCard"),
                Table("companionCardEvidence"), Table("companionCardEvidenceSegment"),
                Table("generationRun")
            ],
            fetch: { database in
                try Self.fetchMeetingReviewCompanionCards(id, in: database)
            })
        return observedStream(observation)
    }

    /// Content-free generation and egress evidence updates independently from
    /// transcript, summary, and Companion product content.
    public func observeMeetingReviewPrivacyReceipt(
        _ id: MeetingID
    ) -> AsyncThrowingStream<PrivacyReceipt?, Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("generationRun"),
                Table("dataEgressEvent"), Table("privacyReceiptCoverage")
            ],
            fetch: { database in
                try Self.fetchPrivacyReceipt(for: id, in: database)
            })
        return observedStream(observation)
    }

    /// Durable work and its stable failure codes update independently from
    /// product content so Meeting Detail can show recovery without reloading
    /// a large transcript or summary.
    public func observeMeetingReviewProcessingJobs(
        _ id: MeetingID
    ) -> AsyncThrowingStream<[ProcessingJob], Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("processingJob")],
            fetch: { database -> [ProcessingJob] in
                guard try Self.liveMeetingExists(id, in: database) else { return [] }
                return try ProcessingJobRecord
                    .filter(Column("meetingID") == id.rawValue.uuidString)
                    .order(Column("createdAt"), Column.rowID)
                    .fetchAll(database)
                    .map { try $0.job }
            })
        return observedStream(observation)
    }
}

extension MeetingStore {
    static func fetchMeetingReviewCore(
        _ id: MeetingID,
        in database: Database
    ) throws -> MeetingReviewCore? {
        let key = id.rawValue.uuidString
        guard let meetingRecord = try MeetingRecord
            .filter(Column("id") == key)
            .filter(Column("deletedAt") == nil)
            .fetchOne(database)
        else { return nil }

        let speakers = try SpeakerRecord
            .filter(Column("meetingID") == key)
            .filter(Column("deletedAt") == nil)
            .fetchAll(database)
            .map { try $0.speaker }
        // Total order (TranscriptSegmentOrder): summary and Apuntador operation
        // fingerprints hash this projection, so a start-time-only sort would
        // let tied rows resolve differently between two reads of unchanged
        // material and supersede work that was fenced against it.
        let segmentRecords = try SegmentRecord
            .filter(Column("meetingID") == key)
            .filter(Column("deletedAt") == nil)
            .order(Column("startTime"), Column("id"))
            .fetchAll(database)
        let segments = try segmentRecords.map { try $0.segment }
        let meeting = try meetingRecord.meeting
        let corrections = try fetchTranscriptCorrectionHistory(
            meetingID: id,
            in: database)
        return MeetingReviewCore(
            meeting: meeting,
            speakers: speakers,
            segments: segments,
            corrections: corrections,
            correctionRevision: try TranscriptCorrectionRevision.current(
                meetingID: id,
                baseTranscriptRevision: meeting.transcriptRevision,
                history: corrections),
            isRefinedTranscript: segmentRecords.contains {
                $0.generationRunID != nil
            })
    }

    static func fetchMeetingReviewSummary(
        _ id: MeetingID,
        in database: Database
    ) throws -> MeetingReviewSummarySnapshot? {
        guard try liveMeetingExists(id, in: database) else { return nil }
        guard let record = try SummaryRecord
            .filter(Column("meetingID") == id.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt").desc, Column("rowid").desc)
            .fetchOne(database)
        else { return nil }
        let snapshot = try summarySnapshot(record, meetingID: id, in: database)
        let source = try record.generationRunID
            .flatMap { try GenerationRunRecord.fetchOne(database, key: $0) }
            .map { try $0.run.transcriptCorrectionSource }
            ?? .legacyAccepted
        return MeetingReviewSummarySnapshot(
            draft: snapshot.draft,
            version: snapshot.version,
            correctionSource: source)
    }

    static func fetchMeetingReviewCompanionCards(
        _ id: MeetingID,
        in database: Database
    ) throws -> MeetingReviewCompanionSnapshot {
        guard try liveMeetingExists(id, in: database) else {
            return MeetingReviewCompanionSnapshot(cards: [], correctionSources: [:])
        }
        let records = try CompanionCardRecord
            .filter(Column("meetingID") == id.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .order(Column("askedAt"), Column("createdAt"))
            .fetchAll(database)
        let cards = try records.map { record in
            let card = try record.card
            return try card.withEvidence(companionCardEvidence(cardID: card.id, in: database))
        }
        var sources: [UUID: TranscriptCorrectionArtifactSource] = [:]
        for record in records {
            guard let cardID = UUID(uuidString: record.id),
                  let runID = record.generationRunID,
                  let run = try GenerationRunRecord.fetchOne(database, key: runID)
            else { continue }
            sources[cardID] = try run.run.transcriptCorrectionSource
        }
        return MeetingReviewCompanionSnapshot(cards: cards, correctionSources: sources)
    }

    static func fetchMeetingReviewNotes(
        _ id: MeetingID,
        in database: Database
    ) throws -> (items: [ContextItem], enhanced: EnhancedNote?) {
        guard try liveMeetingExists(id, in: database) else { return ([], nil) }
        // The section is the user's NOTES: links, objectives, and code
        // snippets have their own surfaces and stay out of it.
        let items = try ContextItemRecord
            .filter(Column("meetingID") == id.rawValue.uuidString)
            .filter(Column("kind") == ContextItem.Kind.note.rawValue)
            .filter(Column("deletedAt") == nil)
            .order(Column("timestamp"))
            .fetchAll(database)
            .map { try $0.item }
        let enhanced = try EnhancedNoteRecord
            .filter(Column("meetingID") == id.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchOne(database)
            .map { try $0.note() }
        return (items, enhanced)
    }

    private static func liveMeetingExists(
        _ id: MeetingID,
        in database: Database
    ) throws -> Bool {
        try MeetingRecord
            .filter(Column("id") == id.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchCount(database) > 0
    }
}
