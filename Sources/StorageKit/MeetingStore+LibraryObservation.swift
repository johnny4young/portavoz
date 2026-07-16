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

    /// Meeting rows and voice mix share one update cadence. No action-item or
    /// trash write can trigger this observation unless the meeting root itself
    /// changes.
    public func observeLibraryMeetings() -> AsyncThrowingStream<LibraryMeetingRows, Error> {
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("speaker"), Table("segment")],
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
        let match = Self.ftsQuery(from: query, requireAll: requireAll)
        guard !match.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.yield([])
                continuation.finish()
            }
        }
        let observation = ValueObservation.tracking(
            regions: [Table("meeting"), Table("segment")],
            fetch: { database in
                try Self.fetchSearch(in: database, match: match, limit: limit)
            })
        return observedStream(observation)
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

extension MeetingStore {
    func observedStream<Reducer>(
        _ observation: ValueObservation<Reducer>
    ) -> AsyncThrowingStream<Reducer.Value, Error>
    where Reducer: ValueReducer, Reducer.Value: Sendable {
        let values = observation.values(
            in: database,
            bufferingPolicy: .bufferingNewest(1))
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
