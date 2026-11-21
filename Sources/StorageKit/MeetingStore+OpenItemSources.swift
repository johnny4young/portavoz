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
            let evidence = try Self.evidenceSegments(in: db, itemIDs: ids)
            var transcripts: [MeetingID: AttributedTranscript] = [:]
            var speakerIDs: Set<String> = []
            var pending: [PendingSource] = []
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT actionItem.id, actionItem.meetingID, actionItem.ownerSpeakerID,
                           commitment.status AS commitmentStatus, commitment.dueAt AS dueAt,
                           commitment.assigneeKind AS assigneeKind,
                           person.id AS personID, person.preferredName AS personName
                    FROM actionItem
                    JOIN meeting ON meeting.id = actionItem.meetingID AND meeting.deletedAt IS NULL
                    \(Self.actionItemLatestCommitmentJoinSQL)
                    LEFT JOIN person ON person.id = commitment.canonicalPersonID AND person.deletedAt IS NULL
                    WHERE actionItem.deletedAt IS NULL
                      AND actionItem.id IN (\(databaseQuestionMarks(count: ids.count)))
                    """,
                arguments: StatementArguments(ids)) {
                let id: UUID = try PersistedIdentity.required(row["id"], table: "actionItem", column: "id")
                let meetingID = MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "actionItem", column: "meetingID"))
                var owner = try PersistedIdentity.optional(
                    row["ownerSpeakerID"], table: "actionItem", column: "ownerSpeakerID"
                ).map(SpeakerID.init(rawValue:))
                var said: (speaker: SpeakerID, start: TimeInterval)?
                if let lines = evidence[id] {
                    if transcripts[meetingID] == nil {
                        transcripts[meetingID] = try Self.readableTranscript(in: db, for: meetingID)
                    }
                    // The first evidence line still in the readable transcript.
                    let segments = transcripts[meetingID]?.segments ?? [:]
                    if let line = lines.first(where: { segments[$0.segment] != nil }),
                       let heard = segments[line.segment] {
                        said = (heard.speaker, heard.start)
                        // The owner was read off the line's speaker before a speaker fix.
                        if owner != nil, owner == line.rawSpeaker { owner = heard.speaker }
                    }
                }
                let confirmed = (row["commitmentStatus"] as String?) == CommitmentStatus.confirmed.rawValue
                pending.append(PendingSource(
                    id: id, owner: owner, assigned: confirmed ? try Self.assignee(of: row) : nil,
                    said: said, due: confirmed ? row["dueAt"] : nil))
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
                    owner: item.ownerVoice(in: voices),
                    dueAt: item.due))
            })
        }
    }

    private struct PendingSource {
        let id: UUID
        let owner: SpeakerID?
        /// A confirmed commitment's assignee wins over the proposal's owner;
        /// `.some(nil)` means it was confirmed unassigned.
        let assigned: OpenItemSource.Voice??
        let said: (speaker: SpeakerID, start: TimeInterval)?
        let due: Date?

        func ownerVoice(in voices: [SpeakerID: OpenItemSource.Voice]) -> OpenItemSource.Voice? {
            if case .some(let assignee) = assigned { return assignee }
            return owner.flatMap { voices[$0] }
        }
    }

    private struct EvidenceLine {
        let segment: UUID
        let rawSpeaker: SpeakerID?
    }

    /// Each item's evidence segments in order, with the speaker stored on each.
    private static func evidenceSegments(in db: Database, itemIDs: [String]) throws -> [UUID: [EvidenceLine]] {
        var lines: [UUID: [EvidenceLine]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT evidence.actionItemID, evidenceSegment.segmentID, segment.speakerID
                FROM summaryActionItemEvidence AS evidence
                JOIN summaryActionItemEvidenceSegment AS evidenceSegment
                  ON evidenceSegment.evidenceID = evidence.id
                LEFT JOIN segment ON segment.id = evidenceSegment.segmentID
                WHERE evidence.actionItemID IN (\(databaseQuestionMarks(count: itemIDs.count)))
                  AND evidenceSegment.segmentID IS NOT NULL
                ORDER BY evidence.actionItemID, evidenceSegment.ordinal
                """,
            arguments: StatementArguments(itemIDs)) {
            let item: UUID = try PersistedIdentity.required(
                row["actionItemID"], table: "summaryActionItemEvidence", column: "actionItemID")
            lines[item, default: []].append(EvidenceLine(
                segment: try PersistedIdentity.required(
                    row["segmentID"], table: "summaryActionItemEvidenceSegment", column: "segmentID"),
                rawSpeaker: try PersistedIdentity.optional(
                    row["speakerID"], table: "segment", column: "speakerID").map(SpeakerID.init(rawValue:))))
        }
        return lines
    }

    private static func assignee(of row: Row) throws -> OpenItemSource.Voice?? {
        switch row["assigneeKind"] as String? {
        case CommitmentAssigneeKind.me.rawValue:
            return .some(OpenItemSource.Voice(speakerID: nil, isMe: true, label: "Me", displayName: nil))
        case CommitmentAssigneeKind.person.rawValue:
            guard let name: String = row["personName"] else { return .some(nil) }
            return .some(OpenItemSource.Voice(
                speakerID: nil, isMe: false, label: name, displayName: name,
                personID: try PersistedIdentity.optional(row["personID"], table: "person", column: "id")
                    .map(PersonID.init(rawValue:))))
        case CommitmentAssigneeKind.unassigned.rawValue:
            return .some(nil)
        default:
            return nil
        }
    }

    private static func liveVoices(in db: Database, ids: [String]) throws -> [SpeakerID: OpenItemSource.Voice] {
        guard !ids.isEmpty else { return [:] }
        var voices: [SpeakerID: OpenItemSource.Voice] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, isMe, label, displayName, personID FROM speaker
                WHERE deletedAt IS NULL AND id IN (\(databaseQuestionMarks(count: ids.count)))
                """,
            arguments: StatementArguments(ids)) {
            let id = SpeakerID(rawValue: try PersistedIdentity.required(row["id"], table: "speaker", column: "id"))
            voices[id] = OpenItemSource.Voice(
                speakerID: id, isMe: row["isMe"], label: row["label"], displayName: row["displayName"],
                personID: try PersistedIdentity.optional(row["personID"], table: "speaker", column: "personID")
                    .map(PersonID.init(rawValue:)))
        }
        return voices
    }
}
