import Foundation
import GRDB
import PortavozCore

extension MeetingStore: DataEgressEventRecorder {
    /// Persists the content-free attempt before the gateway can hand meeting
    /// material to URLSession. Missing or unknown meetings fail closed.
    public func recordDataEgressEvent(_ event: DataEgressEvent) async throws {
        try await database.write { db in
            try Self.validateDataEgressEvent(event)
            guard let meetingID = event.meetingID else {
                try Self.insertGlobalDataEgressEvent(event, in: db)
                return
            }
            guard try MeetingRecord.exists(
                db, key: meetingID.rawValue.uuidString)
            else { throw StorageError.meetingNotFound(meetingID) }
            try DataEgressEventRecord(event, meetingID: meetingID).insert(db)
        }
    }

    /// Cross-library receipts are intentionally separate from per-meeting
    /// receipts: one multi-meeting Ask must not make the first citation look
    /// like the sole material sent to the selected local engine.
    public func globalDataEgressEvents() async throws -> [DataEgressEvent] {
        try await database.read { database in
            try GlobalDataEgressEventRecord
                .order(Column("attemptedAt"), Column("rowid"))
                .fetchAll(database)
                .map { try $0.event }
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
            egressEvents: try fetchDataEgressEvents(for: meetingID, in: db),
            syncDisclosure: try fetchSyncDisclosure(for: meetingID, in: db))
    }

    /// The journal is the meeting database's own content-free record of sync
    /// standing: an acknowledged generation means the private cloud database
    /// confirmed storing this meeting's text at least once. Disabling sync
    /// keeps journal rows intact on purpose — an acknowledged upload happened,
    /// and the receipt keeps saying so.
    static func fetchSyncDisclosure(
        for meetingID: MeetingID,
        in db: Database
    ) throws -> PrivacyReceiptSyncDisclosure {
        let acknowledged = try Int.fetchOne(
            db,
            sql: "SELECT acknowledgedGeneration FROM meetingSyncState WHERE meetingID = ?",
            arguments: [meetingID.rawValue.uuidString])
        return syncDisclosure(acknowledgedGeneration: acknowledged ?? 0)
    }

    static func syncDisclosure(acknowledgedGeneration: Int) -> PrivacyReceiptSyncDisclosure {
        acknowledgedGeneration > 0
            ? .acknowledgedByPrivateCloud
            : .noCloudCopyRecorded
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

    private static func insertGlobalDataEgressEvent(
        _ event: DataEgressEvent,
        in database: Database
    ) throws {
        guard event.operation == .askAnswerGeneration,
              event.destinationScope == .localDevice,
              event.dataClassification == .meetingAnswerMaterial,
              event.consentSource == .summaryEngineSettings,
              let modelID = event.modelID?.trimmingCharacters(
                  in: .whitespacesAndNewlines),
              !modelID.isEmpty
        else {
            throw StorageError.invalidDataEgressEvent(
                "global receipts require bounded local Ask metadata")
        }
        try GlobalDataEgressEventRecord(event, modelID: modelID)
            .insert(database)
    }
}
