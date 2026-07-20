import Foundation
import GRDB
import PortavozCore

public struct MeetingMarkdownBackupSnapshot: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let summaryVersion: Int?

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        summaryVersion: Int?
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.summaryVersion = summaryVersion
    }
}

public struct MeetingMarkdownBackupReadFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String

    public init(meetingID: MeetingID?, title: String) {
        self.meetingID = meetingID
        self.title = title
    }
}

public struct MeetingMarkdownBackupSnapshots: Sendable {
    public let meetings: [MeetingMarkdownBackupSnapshot]
    public let failures: [MeetingMarkdownBackupReadFailure]

    public init(
        meetings: [MeetingMarkdownBackupSnapshot],
        failures: [MeetingMarkdownBackupReadFailure]
    ) {
        self.meetings = meetings
        self.failures = failures
    }
}

extension MeetingStore {
    /// Takes one database snapshot for the entire readable backup. A corrupt
    /// aggregate is isolated so healthy meetings still leave the database.
    public func libraryMarkdownBackupSnapshots() async throws
        -> MeetingMarkdownBackupSnapshots {
        try await database.read { database in
            let records = try MeetingRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("startedAt").desc)
                .fetchAll(database)
            var meetings: [MeetingMarkdownBackupSnapshot] = []
            var failures: [MeetingMarkdownBackupReadFailure] = []
            meetings.reserveCapacity(records.count)

            for record in records {
                do {
                    let snapshot = try Self.markdownBackupSnapshot(
                        record: record,
                        in: database)
                    meetings.append(snapshot)
                } catch {
                    failures.append(MeetingMarkdownBackupReadFailure(
                        meetingID: UUID(uuidString: record.id).map {
                            MeetingID(rawValue: $0)
                        },
                        title: record.title))
                }
            }
            return MeetingMarkdownBackupSnapshots(
                meetings: meetings,
                failures: failures)
        }
    }
}

private extension MeetingStore {
    static func markdownBackupSnapshot(
        record: MeetingRecord,
        in database: Database
    ) throws -> MeetingMarkdownBackupSnapshot {
        let meeting = try record.meeting
        guard let core = try fetchMeetingReviewCore(meeting.id, in: database) else {
            throw MeetingMarkdownBackupSnapshotError.missingAggregate
        }
        let summary = try? generalSummarySnapshot(
            meetingID: meeting.id,
            in: database)
        return MeetingMarkdownBackupSnapshot(
            meeting: core.meeting,
            speakers: core.speakers,
            segments: core.segments,
            summary: summary?.draft,
            summaryVersion: summary?.version)
    }

    /// Preserves the released backup's General-recipe selection instead of
    /// silently switching existing exports to a custom or Standup structure.
    static func generalSummarySnapshot(
        meetingID: MeetingID,
        in database: Database
    ) throws -> (draft: SummaryDraft, version: Int)? {
        guard let record = try SummaryRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .filter(Column("recipeID") == Recipe.general.id)
            .filter(Column("deletedAt") == nil)
            .order(Column("version").desc)
            .fetchOne(database)
        else { return nil }
        return try summarySnapshot(record, meetingID: meetingID, in: database)
    }
}

private enum MeetingMarkdownBackupSnapshotError: Error {
    case missingAggregate
}
