import Foundation
import GRDB
import PortavozCore

/// One read-consistent projection of every live row that can travel in a
/// meeting export. Audio bytes remain a filesystem concern.
public struct MeetingExportSnapshot: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        contextItems: [ContextItem],
        companionCards: [CompanionCard]
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.contextItems = contextItems
        self.companionCards = companionCards
    }
}

extension MeetingStore {
    /// Loads the exportable aggregate in one GRDB read so cast, transcript,
    /// newest summary, notes, and Companion content describe one DB moment.
    public func meetingExportSnapshot(
        _ id: MeetingID
    ) async throws -> MeetingExportSnapshot? {
        let key = id.rawValue.uuidString
        return try await database.read { db in
            guard let meeting = try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { return nil }

            let speakers = try SpeakerRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
                .map { try $0.speaker }
            let segments = try SegmentRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { try $0.segment }
            // Released export semantics are strict for the core aggregate but
            // degrade optional summary/note/Companion decode failures to empty.
            let summary = try? Self.mostRecentSummarySnapshot(
                meetingID: id,
                in: db)?.draft
            let contextItems = (try? ContextItemRecord
                .filter(Column("meetingID") == key)
                .filter(Column("deletedAt") == nil)
                .order(Column("timestamp"))
                .fetchAll(db)
                .map { try $0.item }) ?? []
            let companionCards = (try? Self.companionCards(meetingID: id, in: db)) ?? []

            return MeetingExportSnapshot(
                meeting: try meeting.meeting,
                speakers: speakers,
                segments: segments,
                summary: summary,
                contextItems: contextItems,
                companionCards: companionCards)
        }
    }
}
