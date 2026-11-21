import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Who said each open to-do and who owns it, read on demand for the few
    /// rows Today shows: attribution needs the meeting's corrected transcript,
    /// which an observation would rebuild on every caption.
    public func openItemSources(for itemIDs: [UUID]) async throws -> [UUID: OpenItemSource] {
        let ids = Array(Set(itemIDs.map(\.uuidString)))
        guard !ids.isEmpty else { return [:] }
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT actionItem.id, actionItem.meetingID, actionItem.ownerSpeakerID,
                           \(Self.actionItemFirstEvidenceSegmentSQL) AS segmentID,
                           commitment.status AS commitmentStatus, commitment.dueAt AS dueAt
                    FROM actionItem
                    JOIN meeting ON meeting.id = actionItem.meetingID AND meeting.deletedAt IS NULL
                    \(Self.actionItemLatestCommitmentJoinSQL)
                    WHERE actionItem.deletedAt IS NULL
                      AND actionItem.id IN (\(databaseQuestionMarks(count: ids.count)))
                    """,
                arguments: StatementArguments(ids))
            var transcripts: [MeetingID: AttributedTranscript] = [:]
            var speakerIDs: Set<String> = []
            var pending: [PendingSource] = []
            for row in rows {
                let id: UUID = try PersistedIdentity.required(row["id"], table: "actionItem", column: "id")
                let meetingID = MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "actionItem", column: "meetingID"))
                let owner = try PersistedIdentity.optional(
                    row["ownerSpeakerID"], table: "actionItem", column: "ownerSpeakerID"
                ).map(SpeakerID.init(rawValue:))
                var said: (speaker: SpeakerID, start: TimeInterval)?
                if let segment: UUID = try PersistedIdentity.optional(
                    row["segmentID"], table: "summaryActionItemEvidenceSegment", column: "segmentID") {
                    if transcripts[meetingID] == nil {
                        transcripts[meetingID] = try Self.readableTranscript(in: db, for: meetingID)
                    }
                    said = transcripts[meetingID]?.segments[segment].map { ($0.speaker, $0.start) }
                }
                let confirmed = (row["commitmentStatus"] as String?) == CommitmentStatus.confirmed.rawValue
                pending.append(PendingSource(id: id, owner: owner, said: said, due: confirmed ? row["dueAt"] : nil))
                for speaker in [owner, said?.speaker].compactMap(\.self) {
                    speakerIDs.insert(speaker.rawValue.uuidString)
                }
            }
            let voices = try Self.liveVoices(in: db, ids: Array(speakerIDs))
            return Dictionary(uniqueKeysWithValues: pending.map { item in
                let saidBy = item.said.flatMap { voices[$0.speaker] }
                return (item.id, OpenItemSource(
                    saidBy: saidBy,
                    time: saidBy == nil ? nil : item.said.map { max(0, $0.start) },
                    owner: item.owner.flatMap { voices[$0] },
                    dueAt: item.due))
            })
        }
    }

    private struct PendingSource {
        let id: UUID
        let owner: SpeakerID?
        let said: (speaker: SpeakerID, start: TimeInterval)?
        let due: Date?
    }

    private static func liveVoices(in db: Database, ids: [String]) throws -> [SpeakerID: OpenItemSource.Voice] {
        guard !ids.isEmpty else { return [:] }
        var voices: [SpeakerID: OpenItemSource.Voice] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, isMe, label, displayName FROM speaker
                WHERE deletedAt IS NULL AND id IN (\(databaseQuestionMarks(count: ids.count)))
                """,
            arguments: StatementArguments(ids)) {
            let id = SpeakerID(rawValue: try PersistedIdentity.required(row["id"], table: "speaker", column: "id"))
            voices[id] = OpenItemSource.Voice(
                speakerID: id, isMe: row["isMe"], label: row["label"], displayName: row["displayName"])
        }
        return voices
    }
}
