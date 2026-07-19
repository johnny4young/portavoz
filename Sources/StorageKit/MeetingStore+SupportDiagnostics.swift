import CryptoKit
import Foundation
import GRDB
import PortavozCore

/// Atomic, content-free storage evidence for one support export. The shape
/// deliberately excludes stable database identities, meeting titles,
/// transcript/summary/card text, prompts, raw fingerprints, configuration JSON,
/// metrics JSON, error messages, full URLs, and paths.
public struct SupportDiagnosticsStorageSnapshot: Sendable {
    public let schemaVersion: Int
    public let trackingStartedAt: Date
    public let meetings: [SupportDiagnosticsStoredMeeting]

    public init(
        schemaVersion: Int,
        trackingStartedAt: Date,
        meetings: [SupportDiagnosticsStoredMeeting]
    ) {
        self.schemaVersion = schemaVersion
        self.trackingStartedAt = trackingStartedAt
        self.meetings = meetings
    }
}

public struct SupportDiagnosticsStoredMeeting: Sendable {
    public let referenceDigest: String
    public let lifecycleState: MeetingLifecycleState
    public let transcriptRevision: Int
    public let lastProcessingErrorCode: String?
    public let processingJobs: [SupportDiagnosticsStoredJob]
    public let generationRuns: [SupportDiagnosticsStoredGeneration]
    public let privacyReceipt: SupportDiagnosticsStoredPrivacyReceipt

    public init(
        referenceDigest: String,
        lifecycleState: MeetingLifecycleState,
        transcriptRevision: Int,
        lastProcessingErrorCode: String?,
        processingJobs: [SupportDiagnosticsStoredJob],
        generationRuns: [SupportDiagnosticsStoredGeneration],
        privacyReceipt: SupportDiagnosticsStoredPrivacyReceipt
    ) {
        self.referenceDigest = referenceDigest
        self.lifecycleState = lifecycleState
        self.transcriptRevision = transcriptRevision
        self.lastProcessingErrorCode = lastProcessingErrorCode
        self.processingJobs = processingJobs
        self.generationRuns = generationRuns
        self.privacyReceipt = privacyReceipt
    }
}

public struct SupportDiagnosticsStoredJob: Sendable {
    public let kind: String
    public let inputFingerprintDigest: String
    public let state: ProcessingJobState
    public let progress: Double
    public let attempt: Int
    public let maxAttempts: Int
    public let notBefore: Date?
    public let errorCode: String?
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let updatedAt: Date
}

public struct SupportDiagnosticsStoredGeneration: Sendable {
    public let kind: GenerationRunKind
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?
    public let inputFingerprintDigest: String
    public let outputLanguage: String?
    public let startedAt: Date
    public let finishedAt: Date?
    public let outcome: GenerationRunOutcome?
}

public struct SupportDiagnosticsStoredPrivacyReceipt: Sendable {
    public let coverage: PrivacyReceiptCoverage
    public let status: PrivacyReceiptStatus
    public let syncDisclosure: PrivacyReceiptSyncDisclosure
    public let trackingStartedAt: Date
    public let events: [SupportDiagnosticsStoredEgressEvent]
}

public struct SupportDiagnosticsStoredEgressEvent: Sendable {
    public let operation: DataEgressOperation
    public let destinationScope: DataEgressDestinationScope
    public let destinationHost: String
    public let dataClassification: DataEgressClassification
    public let consentSource: DataEgressConsentSource
    public let providerID: String
    public let modelID: String?
    public let attemptedAt: Date
}

extension MeetingStore {
    /// Reads every support-safe row family in one SQLite snapshot. Fetches are
    /// grouped in memory instead of issuing one query per meeting, so export
    /// cost stays linear as a library grows.
    public func supportDiagnosticsSnapshot() async throws -> SupportDiagnosticsStorageSnapshot {
        try await database.read { db in
            let meetings = try MeetingRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
            guard let trackingStartedAt = try Date.fetchOne(
                db,
                sql: "SELECT trackingStartedAt FROM privacyReceiptCoverage "
                    + "WHERE id = 'meeting-content-egress'")
            else {
                throw StorageError.invalidDataEgressEvent(
                    "privacy receipt coverage boundary is missing")
            }

            let jobsByMeeting = try Dictionary(grouping: ProcessingJobRecord
                .order(Column("createdAt"), Column.rowID)
                .fetchAll(db), by: \.meetingID)
            let runsByMeeting = try Dictionary(grouping: GenerationRunRecord
                .order(Column("startedAt"), Column("rowid"))
                .fetchAll(db), by: \.meetingID)
            let eventsByMeeting = try Dictionary(grouping: DataEgressEventRecord
                .order(Column("attemptedAt"), Column("rowid"))
                .fetchAll(db), by: \.meetingID)
            let syncByMeeting = try Self.fetchSyncDisclosuresByMeeting(in: db)

            let evidence = try meetings.map { record in
                guard let lifecycle = MeetingLifecycleState(rawValue: record.lifecycleState) else {
                    throw StorageError.invalidPersistedValue(
                        table: MeetingRecord.databaseTableName,
                        column: "lifecycleState",
                        value: record.lifecycleState)
                }
                let meetingID = MeetingID(rawValue: try PersistedIdentity.required(
                    record.id,
                    table: MeetingRecord.databaseTableName,
                    column: "id"))
                let jobs = try (jobsByMeeting[record.id] ?? []).map { try $0.job }
                let runs = try (runsByMeeting[record.id] ?? []).map { try $0.run }
                let events = try (eventsByMeeting[record.id] ?? []).map { try $0.event }
                let receipt = PrivacyReceipt(
                    meetingID: meetingID,
                    meetingStoredAt: record.createdAt,
                    trackingStartedAt: trackingStartedAt,
                    generationRuns: runs,
                    egressEvents: events,
                    syncDisclosure: syncByMeeting[record.id] ?? .noCloudCopyRecorded)
                return SupportDiagnosticsStoredMeeting(
                    referenceDigest: supportDigest(meetingID.rawValue.uuidString),
                    lifecycleState: lifecycle,
                    transcriptRevision: record.transcriptRevision,
                    lastProcessingErrorCode: supportSafeCode(record.lastProcessingError),
                    processingJobs: jobs.map(supportJob),
                    generationRuns: runs.map(supportGeneration),
                    privacyReceipt: supportPrivacyReceipt(receipt))
            }

            return SupportDiagnosticsStorageSnapshot(
                schemaVersion: StorageSchema.version,
                trackingStartedAt: trackingStartedAt,
                meetings: evidence)
        }
    }

    private static func fetchSyncDisclosuresByMeeting(
        in db: Database
    ) throws -> [String: PrivacyReceiptSyncDisclosure] {
        try Dictionary(
            uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: "SELECT meetingID, acknowledgedGeneration FROM meetingSyncState")
            .map { row -> (String, PrivacyReceiptSyncDisclosure) in
                (row["meetingID"],
                 syncDisclosure(acknowledgedGeneration: row["acknowledgedGeneration"]))
            })
    }
}

private func supportJob(_ job: ProcessingJob) -> SupportDiagnosticsStoredJob {
    SupportDiagnosticsStoredJob(
        kind: supportSafeCode(job.kind.rawValue) ?? "unknown",
        inputFingerprintDigest: supportDigest(job.inputFingerprint),
        state: job.state,
        progress: job.progress,
        attempt: job.attempt,
        maxAttempts: job.maxAttempts,
        notBefore: job.notBefore,
        errorCode: supportSafeCode(job.errorCode),
        createdAt: job.createdAt,
        startedAt: job.startedAt,
        finishedAt: job.finishedAt,
        updatedAt: job.updatedAt)
}

private func supportGeneration(_ run: GenerationRun) -> SupportDiagnosticsStoredGeneration {
    SupportDiagnosticsStoredGeneration(
        kind: run.kind,
        providerID: supportSafeLabel(run.providerID),
        modelID: supportSafeLabel(run.modelID),
        modelRevision: run.modelRevision.map(supportSafeLabel),
        inputFingerprintDigest: supportDigest(run.inputFingerprint),
        outputLanguage: supportSafeLanguage(run.outputLanguage),
        startedAt: run.startedAt,
        finishedAt: run.finishedAt,
        outcome: run.outcome)
}

private func supportPrivacyReceipt(
    _ receipt: PrivacyReceipt
) -> SupportDiagnosticsStoredPrivacyReceipt {
    SupportDiagnosticsStoredPrivacyReceipt(
        coverage: receipt.coverage,
        status: receipt.status,
        syncDisclosure: receipt.syncDisclosure,
        trackingStartedAt: receipt.trackingStartedAt,
        events: receipt.egressEvents.map { event in
            SupportDiagnosticsStoredEgressEvent(
                operation: event.operation,
                destinationScope: event.destinationScope,
                destinationHost: supportSafeHost(event.destinationHost),
                dataClassification: event.dataClassification,
                consentSource: event.consentSource,
                providerID: supportSafeHost(event.providerID),
                modelID: event.modelID.map(supportSafeLabel),
                attemptedAt: event.attemptedAt)
        })
}

private func supportDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func supportSafeCode(_ value: String?) -> String? {
    guard let value else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
    guard !value.isEmpty, value.count <= 120,
          value.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    return value
}

private func supportSafeLanguage(_ value: String?) -> String? {
    guard let value else { return nil }
    let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-")
    guard !value.isEmpty, value.count <= 24,
          value.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    return value
}

private func supportSafeHost(_ value: String) -> String {
    let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
    guard !value.isEmpty, value.count <= 253,
          !value.contains("/"), !value.contains("@"),
          value.unicodeScalars.allSatisfy(allowed.contains)
    else { return "redacted-\(supportDigest(value).prefix(12))" }
    return value.lowercased()
}

private func supportSafeLabel(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-+()")
    guard !value.isEmpty, value.count <= 160,
          !value.contains("://"), !value.contains("\\"),
          !value.hasPrefix("/"), !value.contains("../"),
          value.unicodeScalars.allSatisfy(allowed.contains)
    else { return "redacted-\(supportDigest(value).prefix(12))" }
    return value
}
