import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Query-specific meeting row used only at the storage composition edge.
    public struct LibraryMeetingRow: Sendable {
        public let meeting: Meeting
        public let voiceMix: [VoiceMixSlice]
    }

    /// One meetings projection may preserve rows when only the degradable
    /// voice-mix query fails.
    public struct LibraryMeetingRows: Sendable {
        public let rows: [LibraryMeetingRow]
        public let failures: Int
    }

    /// The `segment` columns the library list and its voice mix actually read.
    ///
    /// Scoped to columns, not the whole table: a semantic embedding backfill
    /// writes `embedding`/`embeddingFingerprint` on `segment` in batches, and a
    /// whole-table region made every batch commit re-fetch the entire library
    /// and recompute every voice mix — the more of the library was being
    /// indexed, the more often it happened.
    static let librarySegmentRegion = SQLRequest<Row>(sql: """
        SELECT meetingID, speakerID, deletedAt, startTime, endTime FROM segment
        """)

    /// The `segment` columns full-text search reads. `text` is included, so an
    /// edit that changes what FTS indexes still re-runs the query.
    static let searchSegmentRegion = SQLRequest<Row>(sql: """
        SELECT id, meetingID, text, startTime, deletedAt FROM segment
        """)

    /// Derived correction text read by FTS. Semantic publication updates only
    /// the excluded vector columns, so indexing never re-fires Library search.
    static let searchCorrectedTextRegion = SQLRequest<Row>(sql: """
        SELECT segmentID, meetingID, baseTranscriptRevision, text
        FROM segmentCorrectedText
        """)

    static let searchStructuralTextRegion = SQLRequest<Row>(sql: """
        SELECT resultID, meetingID, correctionID, baseTranscriptRevision,
               kind, text, startTime
        FROM transcriptStructuralSearchRow
        """)

    /// Meeting rows and voice mix share one update cadence. No action-item or
    /// trash write can trigger this observation unless the meeting root itself
    /// changes.
    public func observeLibraryMeetings() -> AsyncThrowingStream<LibraryMeetingRows, Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("speaker"), Self.librarySegmentRegion
            ],
            fetch: { database in
                try Self.fetchLibraryMeetingRows(in: database)
            })
        return observedStream(observation)
    }

    /// Open commitments depend only on meeting visibility, immutable summary
    /// selection, and action-item state.
    public func observeLibraryOpenItems(
        limit: Int = 20
    ) -> AsyncThrowingStream<[OpenActionItem], Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("summary"), Table("actionItem")],
            fetch: { database in
                try Self.fetchOpenActionItems(in: database, limit: limit)
            })
        return observedStream(observation)
    }

    /// Recently Deleted is a meeting-root projection and tracks no child table.
    public func observeLibraryTrash() -> AsyncThrowingStream<[DeletedMeeting], Error> {
        let observation = ValueObservation.tracking(
            region: Table("meeting"),
            fetch: { database in
                try Self.fetchDeletedMeetings(in: database)
            })
        return observedStream(observation)
    }

    /// Observes the active full-text query independently from every sidebar
    /// section. Base tables are explicit so FTS shadow-table implementation
    /// details do not become part of the application contract.
    public func observeLibrarySearch(
        _ query: String,
        limit: Int = 20,
        requireAll: Bool = true
    ) -> AsyncThrowingStream<[SearchHit], Error> {
        observeLibrarySearch(
            [query],
            limit: limit,
            requireAllWithinEachQuery: requireAll)
    }

    /// Observes several equivalent queries as one ranked FTS expression.
    /// Terms within each language variant remain ANDed while the variants are
    /// ORed, so "August roadmap" also finds "agosto hoja de ruta" without
    /// matching every transcript that happens to say only "roadmap".
    public func observeLibrarySearch(
        _ queries: [String],
        limit: Int = 20,
        requireAllWithinEachQuery: Bool = true
    ) -> AsyncThrowingStream<[SearchHit], Error> {
        let match = Self.ftsQuery(
            fromAny: queries,
            requireAllWithinEachQuery: requireAllWithinEachQuery)
        guard !match.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.yield([])
                continuation.finish()
            }
        }
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"),
                Self.searchSegmentRegion,
                Self.searchCorrectedTextRegion,
                Self.searchStructuralTextRegion,
                Table("transcriptStructuralSearchSource"),
                Table("transcriptCorrectionSearchState")
            ],
            fetch: { database in
                try Self.fetchSearch(in: database, match: match, limit: limit)
            })
        return observedStream(observation)
    }

    static func ftsQuery(
        fromAny queries: [String],
        requireAllWithinEachQuery: Bool = true
    ) -> String {
        var seen = Set<String>()
        return queries.compactMap { query -> String? in
            let expression = ftsQuery(
                from: query,
                requireAll: requireAllWithinEachQuery)
            guard !expression.isEmpty, seen.insert(expression).inserted else {
                return nil
            }
            return "(\(expression))"
        }.joined(separator: " OR ")
    }
}

private extension MeetingStore {
    static func fetchLibraryMeetingRows(
        in database: Database
    ) throws -> LibraryMeetingRows {
        let meetings = try fetchMeetings(in: database)
        do {
            let mixes = try fetchVoiceMixes(
                in: database,
                for: meetings.map(\.id))
            return LibraryMeetingRows(
                rows: meetings.map {
                    LibraryMeetingRow(
                        meeting: $0,
                        voiceMix: mixes[$0.id] ?? [])
                },
                failures: 0)
        } catch {
            return LibraryMeetingRows(
                rows: meetings.map {
                    LibraryMeetingRow(meeting: $0, voiceMix: [])
                },
                failures: 1)
        }
    }
}
