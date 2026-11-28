import GRDB
import PortavozCore

extension MeetingStore {
    /// The resident menu bar needs only the newest finished meetings and their
    /// stored voice strips. The one being recorded is drawn live instead, and
    /// transcript, speaker, summary and trash data stay unobserved.
    public func observeMenuBarMeetings(
        limit: Int = 3
    ) -> AsyncThrowingStream<LibraryMeetingRows, Error> {
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
    ) throws -> LibraryMeetingRows {
        let meetings = try MeetingRecord
            .filter(Column("deletedAt") == nil)
            .filter(Column("lifecycleState") != MeetingLifecycleState.recording.rawValue)
            .order(Column("startedAt").desc)
            .limit(max(0, limit))
            .fetchAll(database)
            .map { try $0.meeting }
        // A strip is decoration: without one the row still lists its meeting.
        let stored = try? fetchVoiceColumns(in: database, for: meetings.map(\.id))
        return LibraryMeetingRows(
            rows: meetings.map { LibraryMeetingRow(meeting: $0, voiceColumns: stored?.columns[$0.id]) },
            failures: stored == nil ? 1 : 0,
            uncachedVoiceColumns: stored?.missing ?? [])
    }
}
