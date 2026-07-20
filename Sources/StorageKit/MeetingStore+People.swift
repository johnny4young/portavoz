import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Exact normalized-alias candidates. A nonempty result requires an
    /// explicit user choice; this method never links or merges anything.
    public func people(matchingAlias alias: String) async throws -> [Person] {
        guard let normalized = PersonAliasNormalizer.normalize(alias) else { return [] }
        return try await database.read { db in
            try PersonRecord.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT person.*
                    FROM person
                    JOIN personAlias ON personAlias.personID = person.id
                    WHERE person.deletedAt IS NULL
                      AND personAlias.deletedAt IS NULL
                      AND personAlias.normalizedAlias = ?
                    ORDER BY person.preferredName COLLATE NOCASE,
                             person.createdAt,
                             person.id
                    """,
                arguments: [normalized])
                .map { try $0.person }
        }
    }

    /// Creates one distinct person and links one live, non-user speaker in a
    /// single transaction. Duplicate aliases across people are deliberate.
    public func createPersonAndLink(
        speakerID: SpeakerID,
        preferredName: String,
        source: PersonAliasSource
    ) async throws -> ConfirmedPersonLink {
        guard let name = PersonAliasNormalizer.displayName(preferredName),
              let normalizedAlias = PersonAliasNormalizer.normalize(name)
        else { throw StorageError.invalidPersonLink("name must not be empty") }

        return try await database.write { db in
            var speaker = try Self.linkableSpeaker(speakerID, in: db)
            guard speaker.personID == nil else {
                throw StorageError.invalidPersonLink("speaker is already linked")
            }
            let now = Date()
            let person = Person(preferredName: name)
            try PersonRecord(person, createdAt: now, updatedAt: now).insert(db)
            try Self.upsertAlias(
                personID: person.id,
                normalizedAlias: normalizedAlias,
                source: source,
                at: now,
                in: db)
            speaker.personID = person.id.rawValue.uuidString
            speaker.displayName = person.preferredName
            speaker.updatedAt = now
            try speaker.update(db)
            return ConfirmedPersonLink(person: person, speaker: try speaker.speaker)
        }
    }

    /// Links one observed speaker to a user-selected existing person and
    /// records the observed alias. No alias lookup result can call this on its
    /// own; the application presents the confirmation boundary first.
    public func linkSpeaker(
        _ speakerID: SpeakerID,
        to personID: PersonID,
        observedAlias: String,
        source: PersonAliasSource
    ) async throws -> ConfirmedPersonLink {
        guard let normalizedAlias = PersonAliasNormalizer.normalize(observedAlias) else {
            throw StorageError.invalidPersonLink("name must not be empty")
        }
        return try await database.write { db in
            var speaker = try Self.linkableSpeaker(speakerID, in: db)
            guard speaker.personID == nil
                    || speaker.personID == personID.rawValue.uuidString
            else { throw StorageError.invalidPersonLink("speaker is already linked") }
            guard let personRecord = try PersonRecord
                .filter(Column("id") == personID.rawValue.uuidString)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { throw StorageError.invalidPersonLink("person is unavailable") }
            let person = try personRecord.person
            let now = Date()
            try Self.upsertAlias(
                personID: personID,
                normalizedAlias: normalizedAlias,
                source: source,
                at: now,
                in: db)
            speaker.personID = personID.rawValue.uuidString
            speaker.displayName = person.preferredName
            speaker.updatedAt = now
            try speaker.update(db)
            return ConfirmedPersonLink(person: person, speaker: try speaker.speaker)
        }
    }
}

private extension MeetingStore {
    static func linkableSpeaker(
        _ id: SpeakerID,
        in db: Database
    ) throws -> SpeakerRecord {
        guard let speaker = try SpeakerRecord.fetchOne(
            db,
            sql: """
                SELECT speaker.*
                FROM speaker
                JOIN meeting ON meeting.id = speaker.meetingID
                WHERE speaker.id = ?
                  AND speaker.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                """,
            arguments: [id.rawValue.uuidString])
        else { throw StorageError.invalidPersonLink("speaker is unavailable") }
        guard !speaker.isMe else {
            throw StorageError.invalidPersonLink("the user's structural speaker cannot be linked")
        }
        return speaker
    }

    static func upsertAlias(
        personID: PersonID,
        normalizedAlias: String,
        source: PersonAliasSource,
        at timestamp: Date,
        in db: Database
    ) throws {
        let personKey = personID.rawValue.uuidString
        if var existing = try PersonAliasRecord
            .filter(Column("personID") == personKey)
            .filter(Column("normalizedAlias") == normalizedAlias)
            .fetchOne(db) {
            existing.source = source.rawValue
            existing.confidence = 1
            existing.updatedAt = timestamp
            existing.deletedAt = nil
            try existing.update(db)
            return
        }
        let alias = PersonAlias(
            personID: personID,
            normalizedAlias: normalizedAlias,
            source: source,
            confidence: 1)
        try PersonAliasRecord(alias, createdAt: timestamp, updatedAt: timestamp).insert(db)
    }
}
