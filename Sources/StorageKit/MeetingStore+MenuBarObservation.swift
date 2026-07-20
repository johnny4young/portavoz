import GRDB
import PortavozCore

extension MeetingStore {
    /// The resident menu bar needs only the newest live meeting roots. It does
    /// not observe transcript, speaker, voice-mix, summary, or trash data.
    public func observeMenuBarMeetings(
        limit: Int = 3
    ) -> AsyncThrowingStream<[Meeting], Error> {
        let observation = ValueObservation.tracking(
            region: Table("meeting"),
            fetch: { database in
                try Self.fetchMenuBarMeetings(in: database, limit: limit)
            })
        return observedStream(observation)
    }
}

private extension MeetingStore {
    static func fetchMenuBarMeetings(
        in database: Database,
        limit: Int
    ) throws -> [Meeting] {
        try MeetingRecord
            .filter(Column("deletedAt") == nil)
            .order(Column("startedAt").desc)
            .limit(max(0, limit))
            .fetchAll(database)
            .map { try $0.meeting }
    }
}
