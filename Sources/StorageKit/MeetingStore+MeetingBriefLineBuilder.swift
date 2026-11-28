import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    struct AttributedTranscript {
        /// Live speakers with attributed speech, most talkative first.
        var speakers: [SpeakerID] = []
        var spoken: [SpeakerID: [MeetingBriefLines.Spoken]] = [:]
        /// Who an accepted segment reads as, and when it starts.
        var segments: [UUID: (speaker: SpeakerID, start: TimeInterval)] = [:]
        /// Who each readable line reads as, split parts by their own ID.
        var lines: [UUID: SpeakerID] = [:]
    }

    /// The lines a rebuild stores, per person, chosen by `MeetingBriefLines.select`.
    static func buildMeetingBriefLines(
        in db: Database, for meetingID: MeetingID
    ) throws -> [(speakerID: SpeakerID, lines: [MeetingBriefLines.Line])] {
        let transcript = try readableTranscript(in: db, for: meetingID)
        guard !transcript.speakers.isEmpty else { return [] }
        var tracked = try commitmentLines(in: db, for: meetingID, transcript: transcript)
        for (speaker, questions) in try questionLines(in: db, for: meetingID, transcript: transcript) {
            tracked[speaker, default: []] += questions
        }
        return MeetingBriefLines.select(
            speakers: transcript.speakers, tracked: tracked, spoken: transcript.spoken)
    }

    /// Accepted segments of live speakers with the effective corrections
    /// applied, the attribution the voice strip draws.
    static func readableTranscript(
        in db: Database, for meetingID: MeetingID
    ) throws -> AttributedTranscript {
        let key = meetingID.rawValue.uuidString
        guard let revision = try Int.fetchOne(
            db, sql: "SELECT transcriptRevision FROM meeting WHERE id = ? AND deletedAt IS NULL",
            arguments: [key])
        else { return AttributedTranscript() }
        let history = try fetchTranscriptCorrectionHistory(meetingID: meetingID, in: db)
        let corrections = try TranscriptCorrectionPolicy.effectiveCorrections(
            in: history, meetingID: meetingID, baseTranscriptRevision: revision)
        let replacements = Dictionary(
            SegmentCorrectedTextProjection.activeReplacements(
                history: history, meetingID: meetingID, baseTranscriptRevision: revision
            ).map { ($0.segmentID, $0.text) },
            uniquingKeysWith: { first, _ in first })
        var texts: [UUID: String] = [:]
        var accepted: [VoiceColumns.Line] = []
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, speakerID, text, startTime, endTime FROM segment
                WHERE deletedAt IS NULL AND isFinal = 1 AND meetingID = ?
                """,
            arguments: [key]) {
            let id = try PersistedIdentity.required(row["id"], table: "segment", column: "id")
            let speaker = try PersistedIdentity.optional(
                row["speakerID"], table: "segment", column: "speakerID")
            texts[id] = replacements[id] ?? row["text"]
            accepted.append(VoiceColumns.Line(
                id: id, speaker: speaker.map(SpeakerID.init(rawValue:)),
                start: row["startTime"], end: row["endTime"]))
        }
        let live = Set(try String.fetchAll(
            db, sql: "SELECT id FROM speaker WHERE deletedAt IS NULL AND meetingID = ?",
            arguments: [key]).compactMap(UUID.init(uuidString:)))
        var transcript = AttributedTranscript()
        var talk: [SpeakerID: (seconds: TimeInterval, firstHeard: TimeInterval)] = [:]
        let attributed = VoiceColumns.attributedLines(lines: accepted, corrections: corrections)
            .filter { live.contains($0.speaker.rawValue) && $0.start.isFinite }
            .sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        for line in attributed {
            let seconds = line.end.isFinite && line.end > line.start ? line.end - line.start : 0
            let known = talk[line.speaker]
            talk[line.speaker] = ((known?.seconds ?? 0) + seconds, known?.firstHeard ?? line.start)
            transcript.spoken[line.speaker, default: []].append(MeetingBriefLines.Spoken(
                segmentID: line.segmentID,
                text: line.partText ?? texts[line.id] ?? "", start: line.start))
            transcript.lines[line.id] = line.speaker
            if let segment = line.segmentID, transcript.segments[segment] == nil {
                transcript.segments[segment] = (line.speaker, line.start)
            }
        }
        transcript.speakers = talk
            .sorted { first, second in
                (second.value.seconds, first.value.firstHeard, first.key.rawValue.uuidString)
                    < (first.value.seconds, second.value.firstHeard, second.key.rawValue.uuidString)
            }
            .map(\.key)
        return transcript
    }

    /// Owned action items of each recipe's latest live snapshot, the rule open
    /// items use. A confirmed commitment's status wins over the checkbox.
    private static func commitmentLines(
        in db: Database, for meetingID: MeetingID, transcript: AttributedTranscript
    ) throws -> [SpeakerID: [MeetingBriefLines.Line]] {
        let rows = try ownedActionItemRows(in: db, for: meetingID)
        func ownerID(of row: Row) throws -> SpeakerID {
            SpeakerID(rawValue: try PersistedIdentity.required(
                row["ownerSpeakerID"], table: "actionItem", column: "ownerSpeakerID"))
        }
        func trimmedText(of row: Row) -> String {
            (row["text"] as String).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines: [SpeakerID: [MeetingBriefLines.Line]] = [:]
        // A dismissed item stays hidden when another recipe repeats it.
        var seen: [SpeakerID: Set<String>] = [:]
        for row in rows where (row["commitmentStatus"] as String?) == CommitmentStatus.dismissed.rawValue {
            seen[try ownerID(of: row), default: []].insert(MeetingBriefLines.foldedKey(trimmedText(of: row)))
        }
        for row in rows {
            let owner = try ownerID(of: row)
            let text = trimmedText(of: row)
            let status: MeetingBriefLines.Status
            switch try (row["commitmentStatus"] as String?).map(commitmentStatus) {
            case .dismissed: continue
            case .done: status = .closed
            case .confirmed: status = .open(due: row["dueAt"])
            case nil: status = row["isDone"] ? .closed : .open(due: nil)
            }
            // Two recipes can state the same item.
            guard !text.isEmpty,
                  seen[owner, default: []].insert(MeetingBriefLines.foldedKey(text)).inserted
            else { continue }
            let segment = try PersistedIdentity.optional(
                row["segmentID"], table: "summaryActionItemEvidenceSegment", column: "segmentID")
            let evidence = segment.flatMap { id in transcript.segments[id].map { (id: id, start: $0.start) } }
            lines[owner, default: []].append(MeetingBriefLines.Line(
                kind: .commitment, text: text, segmentID: evidence?.id,
                time: max(0, evidence?.start ?? 0), status: status))
        }
        return lines.mapValues(MeetingBriefLines.pendingFirst)
    }

    /// Joins `commitment` to the live commitment an action item most recently fed.
    static let actionItemLatestCommitmentJoinSQL = """
        LEFT JOIN commitment ON commitment.id = (
            SELECT source.commitmentID FROM commitmentSource AS source
            JOIN commitment AS confirmed
              ON confirmed.id = source.commitmentID AND confirmed.deletedAt IS NULL
            WHERE source.actionItemID = actionItem.id
            ORDER BY source.firstSeenAt DESC, source.id LIMIT 1)
        """

    private static func ownedActionItemRows(in db: Database, for meetingID: MeetingID) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT actionItem.text, actionItem.ownerSpeakerID, actionItem.isDone,
                       (SELECT evidenceSegment.segmentID
                        FROM summaryActionItemEvidence AS evidence
                        JOIN summaryActionItemEvidenceSegment AS evidenceSegment
                          ON evidenceSegment.evidenceID = evidence.id
                        WHERE evidence.actionItemID = actionItem.id
                          AND evidenceSegment.segmentID IS NOT NULL
                        ORDER BY evidenceSegment.ordinal LIMIT 1) AS segmentID,
                       commitment.status AS commitmentStatus, commitment.dueAt AS dueAt
                FROM actionItem
                JOIN summary ON summary.id = actionItem.summaryID AND summary.deletedAt IS NULL
                \(actionItemLatestCommitmentJoinSQL)
                WHERE actionItem.meetingID = ? AND actionItem.deletedAt IS NULL
                  AND actionItem.ownerSpeakerID IS NOT NULL
                  AND summary.version = (
                      SELECT MAX(version) FROM summary latest
                      WHERE latest.meetingID = summary.meetingID
                        AND latest.recipeID = summary.recipeID
                        AND latest.deletedAt IS NULL)
                ORDER BY actionItem.createdAt, actionItem.rowid
                """,
            arguments: [meetingID.rawValue.uuidString])
    }

    private static func questionLines(
        in db: Database, for meetingID: MeetingID, transcript: AttributedTranscript
    ) throws -> [SpeakerID: [MeetingBriefLines.Line]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT text, status, primarySegmentID FROM meetingQuestion
                WHERE sourceMeetingID = ? AND deletedAt IS NULL AND status IN ('open', 'resolved')
                ORDER BY openedAt, id
                """,
            arguments: [meetingID.rawValue.uuidString])
        var lines: [SpeakerID: [MeetingBriefLines.Line]] = [:]
        for row in rows {
            let segment = try PersistedIdentity.required(
                row["primarySegmentID"], table: "meetingQuestion", column: "primarySegmentID")
            guard let asked = transcript.segments[segment] else { continue }
            lines[asked.speaker, default: []].append(MeetingBriefLines.Line(
                kind: .question, text: row["text"], segmentID: segment, time: max(0, asked.start),
                status: try questionStatus(row["status"]) == .open ? .unresolved : .closed))
        }
        return lines.mapValues(MeetingBriefLines.pendingFirst)
    }

    private static func commitmentStatus(_ raw: String) throws -> CommitmentStatus {
        guard let status = CommitmentStatus(rawValue: raw) else {
            throw StorageError.invalidPersistedValue(table: "commitment", column: "status", value: raw)
        }
        return status
    }

    private static func questionStatus(_ raw: String) throws -> MeetingQuestionStatus {
        guard let status = MeetingQuestionStatus(rawValue: raw) else {
            throw StorageError.invalidPersistedValue(table: "meetingQuestion", column: "status", value: raw)
        }
        return status
    }
}
