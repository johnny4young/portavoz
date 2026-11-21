import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Live meetings started inside `interval`, earliest first, each with its
    /// voice strip. A finished meeting's missing strip is stored; a recording
    /// is binned in memory, because each segment drops its row again.
    public func meetingRows(startedIn interval: DateInterval) async throws -> [LibraryMeetingRow] {
        let (meetings, live) = try await database.read { db in
            let meetings = try MeetingRecord
                .filter(Column("deletedAt") == nil)
                .filter(Column("startedAt") >= interval.start && Column("startedAt") < interval.end)
                .order(Column("startedAt").asc, Column("id").asc)
                .fetchAll(db)
                .map { try $0.meeting }
            let recording = meetings.filter { $0.lifecycleState == .recording }.map(\.id)
            return (meetings, Self.computeVoiceColumns(in: db, for: recording))
        }
        let stored = try await voiceColumns(
            for: meetings.filter { $0.lifecycleState != .recording }.map(\.id))
        return meetings.map {
            LibraryMeetingRow(meeting: $0, voiceColumns: live[$0.id] ?? stored[$0.id])
        }
    }
}
