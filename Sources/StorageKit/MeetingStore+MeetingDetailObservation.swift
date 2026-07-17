import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Storage-edge projection mapped into ApplicationKit by the app adapter.
    public struct MeetingReviewCore: Sendable {
        public let meeting: Meeting
        public let speakers: [Speaker]
        public let segments: [TranscriptSegment]
    }

    /// Transcript/cast observation for one meeting. Summary and Companion
    /// writes cannot invalidate this projection.
    public func observeMeetingReviewCore(
        _ id: MeetingID
    ) -> AsyncThrowingStream<MeetingReviewCore?, Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("speaker"), Table("segment")],
            fetch: { database -> MeetingReviewCore? in
                try Self.fetchMeetingReviewCore(id, in: database)
            })
        return observedStream(observation)
    }

    /// Newest immutable summary across recipes, including current action-item
    /// state. Transcript and Companion writes cannot invalidate it.
    public func observeMeetingReviewSummary(
        _ id: MeetingID
    ) -> AsyncThrowingStream<(draft: SummaryDraft, version: Int)?, Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("summary"), Table("actionItem")],
            fetch: { database in
                try Self.fetchMeetingReviewSummary(id, in: database)
            })
        return observedStream(observation)
    }

    /// Persisted Companion evidence is independent from cast and summary
    /// reads, so deleting a card refreshes only the right-rail projection.
    public func observeMeetingReviewCompanionCards(
        _ id: MeetingID
    ) -> AsyncThrowingStream<[CompanionCard], Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("companionCard")],
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
                    .order(Column("createdAt"), Column("id"))
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
        let segments = try SegmentRecord
            .filter(Column("meetingID") == key)
            .filter(Column("deletedAt") == nil)
            .order(Column("startTime"))
            .fetchAll(database)
            .map { try $0.segment }
        return MeetingReviewCore(
            meeting: try meetingRecord.meeting,
            speakers: speakers,
            segments: segments)
    }

    static func fetchMeetingReviewSummary(
        _ id: MeetingID,
        in database: Database
    ) throws -> (draft: SummaryDraft, version: Int)? {
        guard try liveMeetingExists(id, in: database) else { return nil }
        return try mostRecentSummarySnapshot(meetingID: id, in: database)
    }

    static func fetchMeetingReviewCompanionCards(
        _ id: MeetingID,
        in database: Database
    ) throws -> [CompanionCard] {
        guard try liveMeetingExists(id, in: database) else { return [] }
        return try CompanionCardRecord
            .filter(Column("meetingID") == id.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .order(Column("askedAt"))
            .fetchAll(database)
            .map { try $0.card }
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
