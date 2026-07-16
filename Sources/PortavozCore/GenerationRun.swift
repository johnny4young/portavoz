import Foundation

/// Generated-artifact family recorded by the shared schema-v6 provenance
/// envelope. Add a case only when that artifact type adopts provenance.
public enum GenerationRunKind: String, Codable, Sendable {
    case summary
}

public enum GenerationRunOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// Privacy-safe provenance for one model operation. JSON payloads contain
/// configuration and aggregate metrics only, never transcript or output text.
public struct GenerationRun: Codable, Equatable, Sendable, Identifiable {
    public let id: GenerationRunID
    public let meetingID: MeetingID
    public let kind: GenerationRunKind
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?
    public let inputFingerprint: String
    public let configJSON: String
    public let outputLanguage: String?
    public let startedAt: Date
    public let finishedAt: Date?
    public let outcome: GenerationRunOutcome?
    public let metricsJSON: String?

    public init(
        id: GenerationRunID = GenerationRunID(),
        meetingID: MeetingID,
        kind: GenerationRunKind,
        providerID: String,
        modelID: String,
        modelRevision: String? = nil,
        inputFingerprint: String,
        configJSON: String,
        outputLanguage: String? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        outcome: GenerationRunOutcome? = nil,
        metricsJSON: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.inputFingerprint = inputFingerprint
        self.configJSON = configJSON
        self.outputLanguage = outputLanguage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.metricsJSON = metricsJSON
    }
}
