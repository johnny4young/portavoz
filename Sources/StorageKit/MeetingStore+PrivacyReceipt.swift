import Foundation
import GRDB
import PortavozCore

extension MeetingStore: DataEgressEventRecorder {
    /// Persists the content-free attempt before the gateway can hand meeting
    /// material to URLSession. Missing or unknown meetings fail closed.
    public func recordDataEgressEvent(_ event: DataEgressEvent) async throws {
        try await database.write { db in
            guard let meetingID = event.meetingID else {
                throw StorageError.invalidDataEgressEvent(
                    "a durable receipt requires a meeting identity")
            }
            guard try MeetingRecord.exists(
                db, key: meetingID.rawValue.uuidString)
            else { throw StorageError.meetingNotFound(meetingID) }
            try Self.validateDataEgressEvent(event)
            try DataEgressEventRecord(event, meetingID: meetingID).insert(db)
        }
    }

    public func dataEgressEvents(
        for meetingID: MeetingID
    ) async throws -> [DataEgressEvent] {
        try await database.read { db in
            try Self.fetchDataEgressEvents(for: meetingID, in: db)
        }
    }

    public func privacyReceipt(
        for meetingID: MeetingID
    ) async throws -> PrivacyReceipt? {
        try await database.read { db in
            try Self.fetchPrivacyReceipt(for: meetingID, in: db)
        }
    }

    static func fetchPrivacyReceipt(
        for meetingID: MeetingID,
        in db: Database
    ) throws -> PrivacyReceipt? {
        guard let meeting = try MeetingRecord
            .filter(Column("id") == meetingID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db)
        else { return nil }
        guard let trackingStartedAt = try Date.fetchOne(
            db,
            sql: "SELECT trackingStartedAt FROM privacyReceiptCoverage "
                + "WHERE id = 'meeting-content-egress'")
        else {
            throw StorageError.invalidDataEgressEvent(
                "privacy receipt coverage boundary is missing")
        }
        let runs = try GenerationRunRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .order(Column("startedAt"), Column("rowid"))
            .fetchAll(db)
            .map { try $0.run }
        return PrivacyReceipt(
            meetingID: meetingID,
            meetingStoredAt: meeting.createdAt,
            trackingStartedAt: trackingStartedAt,
            generationRuns: runs,
            egressEvents: try fetchDataEgressEvents(for: meetingID, in: db))
    }

    private static func fetchDataEgressEvents(
        for meetingID: MeetingID,
        in db: Database
    ) throws -> [DataEgressEvent] {
        try DataEgressEventRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .order(Column("attemptedAt"), Column("rowid"))
            .fetchAll(db)
            .map { try $0.event }
    }

    private static func validateDataEgressEvent(_ event: DataEgressEvent) throws {
        let required = [event.destinationHost, event.providerID]
        guard required.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw StorageError.invalidDataEgressEvent(
                "destination or provider identity is blank")
        }
        guard event.destinationHost.caseInsensitiveCompare(event.providerID) == .orderedSame else {
            throw StorageError.invalidDataEgressEvent(
                "provider identity does not match the destination host")
        }
        guard event.destinationScope == DataEgressDestination.scope(
            forHost: event.destinationHost)
        else {
            throw StorageError.invalidDataEgressEvent(
                "destination scope does not match the destination host")
        }
    }
}
