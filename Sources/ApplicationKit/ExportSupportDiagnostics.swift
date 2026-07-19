import Foundation
import PortavozCore
import StorageKit

public enum SupportModelReadinessState: String, Codable, Sendable {
    case available
    case unavailable
    case installed
    case notInstalled = "not-installed"
    case loaded
    case notLoaded = "not-loaded"
    case preparing
    case failed
    case configured
    case notConfigured = "not-configured"
}

public struct SupportModelReadiness: Codable, Equatable, Sendable {
    public let capability: String
    public let state: SupportModelReadinessState

    public init(capability: String, state: SupportModelReadinessState) {
        self.capability = capability
        self.state = state
    }
}

public struct SupportDiagnosticsEnvironment: Codable, Equatable, Sendable {
    public let appVersion: String
    public let buildVersion: String
    public let operatingSystem: String
    public let models: [SupportModelReadiness]

    public init(
        appVersion: String,
        buildVersion: String,
        operatingSystem: String,
        models: [SupportModelReadiness]
    ) {
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.operatingSystem = operatingSystem
        self.models = models
    }
}

public struct ExportSupportDiagnosticsRequest: Sendable {
    public let environment: SupportDiagnosticsEnvironment
    public let generatedAt: Date

    public init(
        environment: SupportDiagnosticsEnvironment,
        generatedAt: Date = Date()
    ) {
        self.environment = environment
        self.generatedAt = generatedAt
    }
}

public protocol SupportDiagnosticsStore: Sendable {
    func supportDiagnosticsSnapshot() async throws -> SupportDiagnosticsStorageSnapshot
}

extension MeetingStore: SupportDiagnosticsStore {}

/// Builds one portable JSON support artifact from an already-redacted storage
/// projection. Presentation owns the explicit save action; this use case never
/// chooses a path or sends the result anywhere.
public struct ExportSupportDiagnostics: Sendable {
    private let store: any SupportDiagnosticsStore

    public init(store: any SupportDiagnosticsStore) {
        self.store = store
    }

    public func execute(_ request: ExportSupportDiagnosticsRequest) async throws -> Data {
        let snapshot = try await store.supportDiagnosticsSnapshot()
        let report = SupportDiagnosticsReport(
            generatedAt: request.generatedAt,
            environment: request.environment,
            snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

public struct SupportDiagnosticsReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let generatedAt: Date
    public let environment: SupportDiagnosticsEnvironment
    public let storage: Storage
    public let meetings: [Meeting]

    public struct Storage: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let privacyTrackingStartedAt: Date
        public let meetingCount: Int
    }

    public struct Meeting: Codable, Equatable, Sendable {
        public let reference: String
        public let lifecycleState: String
        public let transcriptRevision: Int
        public let lastProcessingError: String?
        public let processingJobs: [ProcessingJobEvidence]
        public let generationRuns: [GenerationEvidence]
        public let privacyReceipt: PrivacyEvidence
    }

    public struct ProcessingJobEvidence: Codable, Equatable, Sendable {
        public let kind: String
        public let inputFingerprintDigest: String
        public let state: String
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

    public struct GenerationEvidence: Codable, Equatable, Sendable {
        public let kind: String
        public let providerID: String
        public let modelID: String
        public let modelRevision: String?
        public let inputFingerprintDigest: String
        public let outputLanguage: String?
        public let startedAt: Date
        public let finishedAt: Date?
        public let outcome: String?
    }

    public struct PrivacyEvidence: Codable, Equatable, Sendable {
        public let status: String
        public let coverage: String
        public let syncDisclosure: String
        public let trackingStartedAt: Date
        public let events: [EgressEvidence]
    }

    public struct EgressEvidence: Codable, Equatable, Sendable {
        public let operation: String
        public let destinationScope: String
        public let destinationHost: String
        public let dataClassification: String
        public let consentSource: String
        public let providerID: String
        public let modelID: String?
        public let attemptedAt: Date
    }

    init(
        generatedAt: Date,
        environment: SupportDiagnosticsEnvironment,
        snapshot: SupportDiagnosticsStorageSnapshot
    ) {
        formatVersion = 1
        self.generatedAt = generatedAt
        self.environment = Self.safe(environment)
        storage = Storage(
            schemaVersion: snapshot.schemaVersion,
            privacyTrackingStartedAt: snapshot.trackingStartedAt,
            meetingCount: snapshot.meetings.count)
        meetings = snapshot.meetings.map(Self.meetingEvidence)
    }
}

private extension SupportDiagnosticsReport {
    static func meetingEvidence(_ meeting: SupportDiagnosticsStoredMeeting) -> Meeting {
        Meeting(
            reference: "meeting-\(meeting.referenceDigest.prefix(12))",
            lifecycleState: meeting.lifecycleState.rawValue,
            transcriptRevision: meeting.transcriptRevision,
            lastProcessingError: meeting.lastProcessingErrorCode.flatMap(safeCode),
            processingJobs: meeting.processingJobs.map { job in
                ProcessingJobEvidence(
                    kind: safeCode(job.kind) ?? "unknown",
                    inputFingerprintDigest: job.inputFingerprintDigest,
                    state: job.state.rawValue,
                    progress: job.progress,
                    attempt: job.attempt,
                    maxAttempts: job.maxAttempts,
                    notBefore: job.notBefore,
                    errorCode: job.errorCode.flatMap(safeCode),
                    createdAt: job.createdAt,
                    startedAt: job.startedAt,
                    finishedAt: job.finishedAt,
                    updatedAt: job.updatedAt)
            },
            generationRuns: meeting.generationRuns.map { run in
                GenerationEvidence(
                    kind: run.kind.rawValue,
                    providerID: safeLabel(run.providerID),
                    modelID: safeLabel(run.modelID),
                    modelRevision: run.modelRevision.map(safeLabel),
                    inputFingerprintDigest: run.inputFingerprintDigest,
                    outputLanguage: run.outputLanguage,
                    startedAt: run.startedAt,
                    finishedAt: run.finishedAt,
                    outcome: run.outcome?.rawValue)
            },
            privacyReceipt: privacyEvidence(meeting.privacyReceipt))
    }

    static func privacyEvidence(
        _ receipt: SupportDiagnosticsStoredPrivacyReceipt
    ) -> PrivacyEvidence {
        let coverage: String
        switch receipt.coverage {
        case .complete: coverage = "complete"
        case .since: coverage = "partial-history"
        }
        let status: String
        switch receipt.status {
        case .allContentStayedOnDevice:
            status = receipt.syncDisclosure == .acknowledgedByPrivateCloud
                ? "all-tracked-processing-stayed-on-device"
                : "all-content-stayed-on-device"
        case .noRemoteTransferRecorded: status = "no-remote-transfer-recorded"
        case .remoteTransferAttempted: status = "remote-transfer-attempted"
        }
        return PrivacyEvidence(
            status: status,
            coverage: coverage,
            syncDisclosure: receipt.syncDisclosure.rawValue,
            trackingStartedAt: receipt.trackingStartedAt,
            events: receipt.events.map { event in
                EgressEvidence(
                    operation: event.operation.rawValue,
                    destinationScope: event.destinationScope.rawValue,
                    destinationHost: safeHost(event.destinationHost),
                    dataClassification: event.dataClassification.rawValue,
                    consentSource: event.consentSource.rawValue,
                    providerID: safeHost(event.providerID),
                    modelID: event.modelID.map(safeLabel),
                    attemptedAt: event.attemptedAt)
            })
    }

    static func safe(
        _ environment: SupportDiagnosticsEnvironment
    ) -> SupportDiagnosticsEnvironment {
        SupportDiagnosticsEnvironment(
            appVersion: safeLabel(environment.appVersion),
            buildVersion: safeLabel(environment.buildVersion),
            operatingSystem: safeLabel(environment.operatingSystem),
            models: environment.models.map {
                SupportModelReadiness(
                    capability: safeLabel($0.capability),
                    state: $0.state)
            })
    }

    static func safeCode(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard !value.isEmpty, value.count <= 120,
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return value
    }

    static func safeHost(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard !value.isEmpty, value.count <= 253,
              !value.contains("/"), !value.contains("@"),
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return "redacted" }
        return value.lowercased()
    }

    static func safeLabel(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-+()")
        guard !value.isEmpty, value.count <= 160,
              !value.contains("://"), !value.contains("\\"),
              !value.hasPrefix("/"), !value.contains("../"),
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return "redacted" }
        return value
    }
}
