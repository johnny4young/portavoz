import Foundation
import GRDB
import PortavozCore

/// The complete, storage-owned search document for one live meeting.
/// Platform adapters decide how to publish it; StorageKit keeps SQL and
/// newest-summary semantics out of the app shell.
public struct SpotlightDocument: Sendable, Equatable {
    public let meetingID: MeetingID
    public let title: String
    public let startedAt: Date
    public let contentDescription: String

    public init(
        meetingID: MeetingID,
        title: String,
        startedAt: Date,
        contentDescription: String
    ) {
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.contentDescription = contentDescription
    }
}

/// Lightweight canonical person material published through the native
/// App-Entity Spotlight surface on supported macOS versions.
public struct SpotlightPersonDocument: Sendable, Equatable {
    public let personID: PersonID
    public let preferredName: String

    public init(personID: PersonID, preferredName: String) {
        self.personID = personID
        self.preferredName = preferredName
    }
}

/// Lightweight confirmed commitment material published through the native
/// App-Entity Spotlight surface on supported macOS versions.
public struct SpotlightCommitmentDocument: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let title: String
    public let dueAt: Date?

    public init(commitmentID: CommitmentID, title: String, dueAt: Date?) {
        self.commitmentID = commitmentID
        self.title = title
        self.dueAt = dueAt
    }
}

/// One transactionally consistent search projection. Meetings retain the
/// released capped summary/transcript body; people and commitments add only
/// the narrow fields already exposed by their App Entities.
public struct SpotlightIndexSnapshot: Sendable, Equatable {
    public let meetings: [SpotlightDocument]
    public let people: [SpotlightPersonDocument]
    public let commitments: [SpotlightCommitmentDocument]

    public init(
        meetings: [SpotlightDocument],
        people: [SpotlightPersonDocument],
        commitments: [SpotlightCommitmentDocument]
    ) {
        self.meetings = meetings
        self.people = people
        self.commitments = commitments
    }
}

extension MeetingStore {
    /// Projects every live meeting for Spotlight from one consistent SQLite
    /// snapshot. The query scans each relevant table once instead of loading
    /// a full cast/transcript and then another summary snapshot per meeting.
    public func spotlightDocuments() async throws -> [SpotlightDocument] {
        try await database.read { db in
            try Self.spotlightDocuments(in: db)
        }
    }

    /// Projects every search surface inside one SQLite read transaction so a
    /// mutation cannot publish a meeting generation beside stale entity rows.
    public func spotlightIndexSnapshot() async throws -> SpotlightIndexSnapshot {
        try await database.read { db in
            SpotlightIndexSnapshot(
                meetings: try Self.spotlightDocuments(in: db),
                people: try SpotlightPersonDocumentRow.fetchAll(
                    db,
                    sql: """
                        SELECT id, preferredName
                        FROM person
                        WHERE deletedAt IS NULL
                        ORDER BY preferredName COLLATE NOCASE, createdAt, id
                        """)
                    .map { try $0.document },
                commitments: try SpotlightCommitmentDocumentRow.fetchAll(
                    db,
                    sql: """
                        SELECT id, title, dueAt
                        FROM commitment
                        WHERE deletedAt IS NULL
                          AND status != 'dismissed'
                        ORDER BY updatedAt DESC, id
                        """)
                    .map { try $0.document })
        }
    }
}

private extension MeetingStore {
    static func spotlightDocuments(in database: Database) throws -> [SpotlightDocument] {
        let rows = try SpotlightDocumentRow.fetchAll(
            database,
            sql: """
                WITH rankedSummary AS (
                    SELECT meetingID, markdown,
                           ROW_NUMBER() OVER (
                               PARTITION BY meetingID
                               ORDER BY createdAt DESC, rowid DESC
                           ) AS summaryRank
                    FROM summary
                    WHERE deletedAt IS NULL
                ),
                rankedSegment AS (
                    SELECT meetingID, text, startTime, rowid,
                           ROW_NUMBER() OVER (
                               PARTITION BY meetingID
                               ORDER BY startTime, rowid
                           ) AS segmentRank
                    FROM segment
                    WHERE deletedAt IS NULL
                ),
                firstTranscript AS (
                    SELECT meetingID, GROUP_CONCAT(text, ' ') AS transcript
                    FROM (
                        SELECT meetingID, text, startTime, rowid
                        FROM rankedSegment
                        WHERE segmentRank <= 40
                        ORDER BY meetingID, startTime, rowid
                    )
                    GROUP BY meetingID
                )
                SELECT meeting.id,
                       meeting.title,
                       meeting.startedAt,
                       rankedSummary.markdown AS summaryMarkdown,
                       firstTranscript.transcript AS transcript
                FROM meeting
                LEFT JOIN rankedSummary
                  ON rankedSummary.meetingID = meeting.id
                 AND rankedSummary.summaryRank = 1
                LEFT JOIN firstTranscript
                  ON firstTranscript.meetingID = meeting.id
                WHERE meeting.deletedAt IS NULL
                ORDER BY meeting.startedAt DESC, meeting.id
                """)
        return try rows.map { try $0.document }
    }
}

private struct SpotlightDocumentRow: FetchableRecord, Decodable {
    let id: String
    let title: String
    let startedAt: Date
    let summaryMarkdown: String?
    let transcript: String?

    var document: SpotlightDocument {
        get throws {
            // A live meeting always contributes transcript text to the old
            // projection, even when that text is empty. Preserve that shape.
            let body = [summaryMarkdown, transcript ?? ""]
                .compactMap { $0 }
                .joined(separator: "\n")
            return SpotlightDocument(
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    id, table: MeetingRecord.databaseTableName, column: "id")),
                title: title,
                startedAt: startedAt,
                contentDescription: String(body.prefix(4_000)))
        }
    }
}

private struct SpotlightPersonDocumentRow: FetchableRecord, Decodable {
    let id: String
    let preferredName: String

    var document: SpotlightPersonDocument {
        get throws {
            SpotlightPersonDocument(
                personID: PersonID(rawValue: try PersistedIdentity.required(
                    id, table: PersonRecord.databaseTableName, column: "id")),
                preferredName: preferredName)
        }
    }
}

private struct SpotlightCommitmentDocumentRow: FetchableRecord, Decodable {
    let id: String
    let title: String
    let dueAt: Date?

    var document: SpotlightCommitmentDocument {
        get throws {
            SpotlightCommitmentDocument(
                commitmentID: CommitmentID(rawValue: try PersistedIdentity.required(
                    id, table: CommitmentRecord.databaseTableName, column: "id")),
                title: title,
                dueAt: dueAt)
        }
    }
}
