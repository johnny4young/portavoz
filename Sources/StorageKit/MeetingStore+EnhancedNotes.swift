import Foundation
import GRDB
import PortavozCore

// The enhanced version of the user's own notes (NOTES-001/D135): one row
// per meeting, replaced in place on regenerate, with generation provenance
// committed in the same transaction as the artifact.
extension MeetingStore {
    /// The current enhanced note, or nil when none was generated (or it
    /// was tombstoned).
    public func enhancedNote(for meetingID: MeetingID) async throws -> EnhancedNote? {
        try await database.read { db in
            try EnhancedNoteRecord
                .filter(Column("meetingID") == meetingID.rawValue.uuidString)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
                .map { try $0.note() }
        }
    }

    /// Atomically installs one successful generation envelope and the
    /// enhanced note it produced — either both commit or neither does, so
    /// provenance can never point at missing output. Regenerating replaces
    /// the previous note in place while preserving its `createdAt`.
    public func saveEnhancedNote(
        _ note: EnhancedNote,
        generationRun: GenerationRun
    ) async throws {
        try await database.write { db in
            try Self.validateTerminalGenerationRun(generationRun)
            guard generationRun.outcome == .succeeded else {
                throw StorageError.invalidGenerationRun(
                    "the atomic enhanced-note overload requires a succeeded run")
            }
            let meetingKey = note.meetingID.rawValue.uuidString
            guard try MeetingRecord.exists(db, key: meetingKey) else {
                throw StorageError.meetingNotFound(note.meetingID)
            }
            let run = GenerationRunRecord(generationRun)
            try run.insert(db)
            let now = generationRun.finishedAt ?? generationRun.startedAt
            if var existing = try EnhancedNoteRecord
                .filter(Column("meetingID") == meetingKey)
                .fetchOne(db) {
                // Explicit update, never ON CONFLICT REPLACE: a replace
                // would silently reset createdAt and orphan nothing visibly.
                existing.markdown = note.markdown
                existing.language = note.language
                existing.inputFingerprint = note.inputFingerprint
                existing.generationRunID = generationRun.id.rawValue.uuidString
                existing.updatedAt = now
                existing.deletedAt = nil
                try existing.update(db)
            } else {
                try EnhancedNoteRecord(
                    note,
                    generationRunID: generationRun.id.rawValue.uuidString,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }
    }

    /// Tombstones the enhanced note without touching the raw context items.
    public func deleteEnhancedNote(for meetingID: MeetingID) async throws {
        try await database.write { db in
            if var record = try EnhancedNoteRecord
                .filter(Column("meetingID") == meetingID.rawValue.uuidString)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db) {
                record.deletedAt = Date()
                record.updatedAt = Date()
                try record.update(db)
            }
        }
    }
}

struct EnhancedNoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "enhancedNote"

    var id: String
    var meetingID: String
    var markdown: String
    var language: String
    var inputFingerprint: String
    var generationRunID: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        _ note: EnhancedNote,
        generationRunID: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = note.id.uuidString
        self.meetingID = note.meetingID.rawValue.uuidString
        self.markdown = note.markdown
        self.language = note.language
        self.inputFingerprint = note.inputFingerprint
        self.generationRunID = generationRunID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    func note() throws -> EnhancedNote {
        guard let noteID = UUID(uuidString: id) else {
            throw StorageError.invalidPersistedUUID(
                table: Self.databaseTableName, column: "id", value: id)
        }
        guard let meetingUUID = UUID(uuidString: meetingID) else {
            throw StorageError.invalidPersistedUUID(
                table: Self.databaseTableName, column: "meetingID", value: meetingID)
        }
        return EnhancedNote(
            id: noteID,
            meetingID: MeetingID(rawValue: meetingUUID),
            markdown: markdown,
            language: language,
            inputFingerprint: inputFingerprint,
            createdAt: createdAt)
    }
}
