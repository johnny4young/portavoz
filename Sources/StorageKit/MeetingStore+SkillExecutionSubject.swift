import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Reads the exact content-free subject captured with one confirmed Skill
    /// execution. Legacy pre-v41 receipts deliberately return nil rather than
    /// deriving authority from an idempotency-key string.
    public func skillExecutionSubject(
        proposalID: UUID
    ) async throws -> SkillSubject? {
        try await database.read { database in
            try Self.skillExecutionSubject(proposalID, in: database)
        }
    }

    static func recordSkillExecutionSubject(
        proposalID: UUID,
        subject: SkillSubject,
        in database: Database
    ) throws -> Bool {
        guard subject.isValid else { return false }
        if let existing = try skillExecutionSubject(proposalID, in: database) {
            return existing == subject
        }

        let columns = executionSubjectColumns(subject)
        try database.execute(
            sql: """
                INSERT INTO skillExecutionSubject (
                    proposalID, subjectKind, meetingID,
                    commitmentID, calendarEventID
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                proposalID.uuidString,
                subject.kind.rawValue,
                columns.meetingID,
                columns.commitmentID,
                columns.calendarEventID
            ])
        return true
    }

    static func skillExecutionSubject(
        _ proposalID: UUID,
        in database: Database
    ) throws -> SkillSubject? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT subjectKind, meetingID, commitmentID, calendarEventID
                FROM skillExecutionSubject
                WHERE proposalID = ?
                """,
            arguments: [proposalID.uuidString])
        else { return nil }
        return try skillExecutionSubject(from: row)
    }

    private static func skillExecutionSubject(
        from row: Row
    ) throws -> SkillSubject {
        let rawKind: String = row["subjectKind"]
        let rawMeetingID: String? = row["meetingID"]
        let rawCommitmentID: String? = row["commitmentID"]
        let calendarEventID: String? = row["calendarEventID"]
        guard let kind = SkillSubject.Kind(rawValue: rawKind) else {
            throw invalidSkillExecutionSubject(rawKind)
        }

        let subject: SkillSubject
        switch kind {
        case .meeting:
            guard let rawMeetingID,
                  let identifier = UUID(uuidString: rawMeetingID),
                  rawCommitmentID == nil,
                  calendarEventID == nil
            else { throw invalidSkillExecutionSubject(rawKind) }
            subject = .meeting(MeetingID(rawValue: identifier))
        case .commitment:
            guard let rawCommitmentID,
                  let identifier = UUID(uuidString: rawCommitmentID),
                  rawMeetingID == nil,
                  calendarEventID == nil
            else { throw invalidSkillExecutionSubject(rawKind) }
            subject = .commitment(CommitmentID(rawValue: identifier))
        case .calendarEvent:
            guard let calendarEventID,
                  UpcomingEvent.isValidIdentity(calendarEventID),
                  rawMeetingID == nil,
                  rawCommitmentID == nil
            else { throw invalidSkillExecutionSubject(rawKind) }
            subject = .calendarEvent(calendarEventID)
        }
        return subject
    }

    private static func executionSubjectColumns(
        _ subject: SkillSubject
    ) -> (meetingID: String?, commitmentID: String?, calendarEventID: String?) {
        switch subject {
        case .meeting(let id):
            (id.rawValue.uuidString, nil, nil)
        case .commitment(let id):
            (nil, id.rawValue.uuidString, nil)
        case .calendarEvent(let id):
            (nil, nil, id)
        }
    }

    private static func invalidSkillExecutionSubject(
        _ value: String
    ) -> StorageError {
        StorageError.invalidPersistedValue(
            table: "skillExecutionSubject",
            column: "subject",
            value: value)
    }
}
