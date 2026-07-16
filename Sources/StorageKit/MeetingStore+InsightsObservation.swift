import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Meeting chronology and durations depend only on the live meeting root.
    public func observeInsightsMeetings() -> AsyncThrowingStream<[Meeting], Error> {
        let observation = ValueObservation.tracking(
            region: Table("meeting"),
            fetch: { database in
                try Self.fetchMeetings(in: database)
            })
        return observedStream(observation)
    }

    /// Confirmed participants and commitment totals react only to their
    /// meeting, speaker, summary, and action-item inputs.
    public func observeInsightsFacts(
        topLimit: Int = 8
    ) -> AsyncThrowingStream<LibraryFacts, Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("speaker"), Table("summary"), Table("actionItem")
            ],
            fetch: { database in
                try Self.fetchLibraryFacts(in: database, topLimit: topLimit)
            })
        return observedStream(observation)
    }

    /// Talk balance reacts to attributed speech and confirmed speaker names,
    /// never to summaries or action-item edits.
    public func observeInsightsVoiceBalance(
        topLimit: Int = 6
    ) -> AsyncThrowingStream<VoiceBalance, Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("speaker"), Table("segment")],
            fetch: { database in
                try Self.fetchVoiceBalance(in: database, topLimit: topLimit)
            })
        return observedStream(observation)
    }

    /// The finding evidence is bounded to the 60 newest live meetings in the
    /// active scope. Scope changes create a new observation; unrelated writes
    /// outside these four tables cannot wake it.
    public func observeInsightsFindingInputs(
        in interval: DateInterval,
        limit: Int = 60
    ) -> AsyncThrowingStream<[MeetingID: FindingInput], Error> {
        let observation = ValueObservation.tracking(
            regions: [
                Table("meeting"), Table("segment"), Table("summary"), Table("actionItem")
            ],
            fetch: { database in
                let keys = try String.fetchAll(
                    database,
                    sql: """
                        SELECT id
                        FROM meeting
                        WHERE deletedAt IS NULL
                          AND startedAt >= ?
                          AND startedAt < ?
                        ORDER BY startedAt DESC
                        LIMIT ?
                        """,
                    arguments: [interval.start, interval.end, limit])
                return try Self.fetchFindingInputs(
                    in: database,
                    meetingKeys: keys)
            })
        return observedStream(observation)
    }
}
