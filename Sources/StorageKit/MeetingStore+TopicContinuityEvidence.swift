import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func loadTopicEvidence(
        for topicID: TopicID,
        in database: Database
    ) throws -> [TopicMeetingEvidence] {
        let records = try topicEvidenceRecords(for: topicID, in: database)
        let meetingIDs = Array(Set(records.map(\.meetingID)))
        let segmentIDs = Array(Set(records.map(\.segmentID)))
        let meetings = Dictionary(
            uniqueKeysWithValues: try MeetingRecord
                .filter(meetingIDs.contains(Column("id")))
                .fetchAll(database)
                .map { ($0.id, $0) })
        let segments = Dictionary(
            uniqueKeysWithValues: try SegmentRecord
                .filter(segmentIDs.contains(Column("id")))
                .fetchAll(database)
                .map { ($0.id, $0) })
        let acceptedSegmentIDs = Set(try String.fetchAll(
            database,
            sql: """
                SELECT segment.id
                FROM segment
                WHERE segment.id IN (\(placeholders(segmentIDs.count)))
                  AND segment.deletedAt IS NULL
                  AND segment.isFinal = 1
                  AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                """,
            arguments: StatementArguments(segmentIDs)))
        return try records
            .sorted {
                topicEvidencePrecedes(
                    $0,
                    $1,
                    meetings: meetings,
                    segments: segments)
            }
            .map { record in
                try record.evidence(availability: topicEvidenceAvailability(
                    record,
                    meeting: meetings[record.meetingID],
                    segment: segments[record.segmentID],
                    acceptedSegmentIDs: acceptedSegmentIDs))
            }
    }

    static func topicEvidenceRecords(
        for topicID: TopicID,
        in database: Database
    ) throws -> [TopicMeetingEvidenceRecord] {
        let topics = try liveTopicRecords(in: database)
        guard topics[topicID.rawValue.uuidString] != nil else {
            throw StorageError.invalidTopicContinuity("topic is unavailable")
        }
        let root = try topicRoot(topicID.rawValue.uuidString, among: topics)
        let familyIDs = try topics.values.compactMap { record -> String? in
            try topicRoot(record.id, among: topics).id == root.id
                ? record.id
                : nil
        }
        return try TopicMeetingEvidenceRecord
            .filter(familyIDs.contains(Column("topicID")))
            .fetchAll(database)
    }

    static func topicEvidencePrecedes(
        _ left: TopicMeetingEvidenceRecord,
        _ right: TopicMeetingEvidenceRecord,
        meetings: [String: MeetingRecord],
        segments: [String: SegmentRecord]
    ) -> Bool {
        let leftMeeting = meetings[left.meetingID]
        let rightMeeting = meetings[right.meetingID]
        if leftMeeting?.startedAt != rightMeeting?.startedAt {
            return (leftMeeting?.startedAt ?? .distantPast)
                < (rightMeeting?.startedAt ?? .distantPast)
        }
        if left.meetingID != right.meetingID { return left.meetingID < right.meetingID }
        let leftSegment = segments[left.segmentID]
        let rightSegment = segments[right.segmentID]
        if leftSegment?.startTime != rightSegment?.startTime {
            return (leftSegment?.startTime ?? 0) < (rightSegment?.startTime ?? 0)
        }
        if left.segmentID != right.segmentID { return left.segmentID < right.segmentID }
        if left.confirmedAt != right.confirmedAt { return left.confirmedAt < right.confirmedAt }
        return left.id < right.id
    }

    static func topicEvidenceAvailability(
        _ evidence: TopicMeetingEvidenceRecord,
        meeting: MeetingRecord?,
        segment: SegmentRecord?,
        acceptedSegmentIDs: Set<String>
    ) -> TopicEvidenceAvailability {
        guard let meeting,
              meeting.deletedAt == nil,
              let segment,
              segment.deletedAt == nil,
              segment.meetingID == evidence.meetingID,
              acceptedSegmentIDs.contains(evidence.segmentID)
        else { return .unavailable }
        return meeting.transcriptRevision == evidence.sourceTranscriptRevision
            ? .current
            : .stale
    }

    static func topicEvidenceAvailability(
        _ evidence: TopicMeetingEvidenceRecord,
        in database: Database
    ) throws -> TopicEvidenceAvailability {
        let meeting = try MeetingRecord.fetchOne(database, key: evidence.meetingID)
        let segment = try SegmentRecord.fetchOne(database, key: evidence.segmentID)
        let accepted = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM segment
                    WHERE segment.id = ?
                      AND segment.deletedAt IS NULL
                      AND segment.isFinal = 1
                      AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                )
                """,
            arguments: [evidence.segmentID]) == true
        return topicEvidenceAvailability(
            evidence,
            meeting: meeting,
            segment: segment,
            acceptedSegmentIDs: accepted ? [evidence.segmentID] : [])
    }

    static func placeholders(_ count: Int) -> String {
        guard count > 0 else { return "NULL" }
        return Array(repeating: "?", count: count).joined(separator: ",")
    }
}
