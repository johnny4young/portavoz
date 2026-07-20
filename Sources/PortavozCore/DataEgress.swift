import Foundation

/// Whether an outbound destination is provably loopback or may leave the Mac.
/// Unknown and private-network hosts are conservatively remote.
public enum DataEgressDestinationScope: String, Codable, Sendable {
    case localDevice = "local-device"
    case remote
}

public struct DataEgressDestination: Equatable, Sendable {
    public let url: URL
    public let scope: DataEgressDestinationScope

    public init(url: URL) {
        self.url = url
        scope = url.host.map(Self.scope(forHost:)) ?? .remote
    }

    /// Shared conservative host classifier for request validation and durable
    /// receipt validation. Unknown and private-network hosts remain remote.
    public static func scope(forHost rawHost: String) -> DataEgressDestinationScope {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return .localDevice
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ octet in
                  guard let value = Int(octet) else { return false }
                  return value >= 0 && value <= 255
              }),
              octets.first == "127"
        else { return .remote }
        return .localDevice
    }
}

public enum DataEgressOperation: String, Codable, Sendable {
    case companionKnowledgeAnswer = "companion-knowledge-answer"
    case summaryGeneration = "summary-generation"
    case publishGitHubGist = "publish-github-gist"
    case createGitHubIssue = "create-github-issue"
    case createLinearIssue = "create-linear-issue"
}

public enum DataEgressClassification: String, Codable, Sendable {
    /// Only the classified participant question, never transcript context.
    case meetingQuestionOnly = "meeting-question-only"
    /// Formatted transcript, speaker labels, user notes, glossary, and recipe
    /// instructions required to generate one summary.
    case meetingSummaryMaterial = "meeting-summary-material"
    /// A rendered meeting document selected for explicit publication.
    case meetingExportDocument = "meeting-export-document"
    /// One meeting-derived action item plus its attribution context.
    case meetingActionItem = "meeting-action-item"
}

public enum DataEgressConsentSource: String, Codable, Sendable {
    /// The persisted Companion BYOK opt-in in Settings.
    case companionBYOKSettings = "companion-byok-settings"
    /// A caller directly constructed a Companion client with a gateway.
    case explicitCompanionClient = "explicit-companion-client"
    /// The user selected the configured summary engine in app Settings.
    case summaryEngineSettings = "summary-engine-settings"
    /// A caller explicitly constructed an external summary provider.
    case explicitSummaryProvider = "explicit-summary-provider"
    /// The user explicitly confirmed or invoked GitHub Gist publication.
    case explicitGistPublish = "explicit-gist-publish"
    /// The user explicitly invoked GitHub Issue publication.
    case explicitGitHubIssuePublish = "explicit-github-issue-publish"
    /// The user explicitly invoked Linear Issue publication.
    case explicitLinearIssuePublish = "explicit-linear-issue-publish"
}

public struct DataEgressProviderDisclosure: Equatable, Sendable {
    public let providerID: String
    public let modelID: String?

    public init(providerID: String, modelID: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// Content-free policy metadata for one outbound operation. The payload is
/// carried separately so policy, diagnostics, and future receipts never create
/// a second copy of meeting material.
public struct DataEgressRequest: Equatable, Sendable {
    public let operation: DataEgressOperation
    public let destination: DataEgressDestination
    public let dataClassification: DataEgressClassification
    public let meetingID: MeetingID?
    public let consentSource: DataEgressConsentSource
    public let providerDisclosure: DataEgressProviderDisclosure

    public init(
        operation: DataEgressOperation,
        destination: DataEgressDestination,
        dataClassification: DataEgressClassification,
        meetingID: MeetingID?,
        consentSource: DataEgressConsentSource,
        providerDisclosure: DataEgressProviderDisclosure
    ) {
        self.operation = operation
        self.destination = destination
        self.dataClassification = dataClassification
        self.meetingID = meetingID
        self.consentSource = consentSource
        self.providerDisclosure = providerDisclosure
    }
}

public struct DataEgressResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

/// Immutable, content-free evidence that one validated transfer was handed to
/// the network boundary. It deliberately stores a host instead of the full URL
/// so paths, queries, and fragments can never copy meeting-derived material
/// into diagnostics.
public struct DataEgressEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: DataEgressEventID
    public let meetingID: MeetingID?
    public let operation: DataEgressOperation
    public let destinationScope: DataEgressDestinationScope
    public let destinationHost: String
    public let dataClassification: DataEgressClassification
    public let consentSource: DataEgressConsentSource
    public let providerID: String
    public let modelID: String?
    public let attemptedAt: Date

    public init(
        id: DataEgressEventID = DataEgressEventID(),
        meetingID: MeetingID?,
        operation: DataEgressOperation,
        destinationScope: DataEgressDestinationScope,
        destinationHost: String,
        dataClassification: DataEgressClassification,
        consentSource: DataEgressConsentSource,
        providerID: String,
        modelID: String?,
        attemptedAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.operation = operation
        self.destinationScope = destinationScope
        self.destinationHost = destinationHost
        self.dataClassification = dataClassification
        self.consentSource = consentSource
        self.providerID = providerID
        self.modelID = modelID
        self.attemptedAt = attemptedAt
    }

    public init(
        id: DataEgressEventID = DataEgressEventID(),
        request: DataEgressRequest,
        attemptedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = request.meetingID
        self.operation = request.operation
        self.destinationScope = request.destination.scope
        self.destinationHost = request.destination.url.host?.lowercased() ?? ""
        self.dataClassification = request.dataClassification
        self.consentSource = request.consentSource
        self.providerID = request.providerDisclosure.providerID
        self.modelID = request.providerDisclosure.modelID
        self.attemptedAt = attemptedAt
    }
}

/// Durable sink owned by the composition root. A gateway with a recorder must
/// persist the event before URLSession can observe the request body; recorder
/// failure therefore fails closed instead of creating an unreceipted transfer.
public protocol DataEgressEventRecorder: Sendable {
    func recordDataEgressEvent(_ event: DataEgressEvent) async throws
}

public enum PrivacyReceiptCoverage: Equatable, Sendable {
    /// The meeting entered the local store after receipt tracking began.
    case complete
    /// The meeting predates tracking, so silence before this date is unknown.
    case since(Date)
}

public enum PrivacyReceiptStatus: Equatable, Sendable {
    case allContentStayedOnDevice
    case noRemoteTransferRecorded
    case remoteTransferAttempted
}

/// Purpose-built projection of model provenance. Configuration JSON, prompts,
/// fingerprints, metrics, transcript, and generated output are intentionally
/// absent from the user-facing privacy surface.
public struct PrivacyReceiptGeneration: Equatable, Sendable {
    public let kind: GenerationRunKind
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?
    public let startedAt: Date
    public let finishedAt: Date?
    public let outcome: GenerationRunOutcome?

    public init(_ run: GenerationRun) {
        kind = run.kind
        providerID = run.providerID
        modelID = run.modelID
        modelRevision = run.modelRevision
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        outcome = run.outcome
    }
}

/// Content-free disclosure of one meeting's private-sync standing, read from
/// the meeting database's sync journal. HTTP egress attempts and private
/// CloudKit sync are different transports with different consent surfaces;
/// the receipt reports BOTH so "did anything leave this Mac?" has one honest
/// answer. Audio, embeddings, and voiceprints never sync.
///
/// The journal records every local change unconditionally, so an
/// unacknowledged entry cannot distinguish "sync disabled" from "first upload
/// in flight" — only an acknowledgement is durable proof of a cloud copy,
/// which is why the disclosure has exactly these two cases.
public enum PrivacyReceiptSyncDisclosure: String, Codable, Equatable, Sendable {
    /// No generation was ever acknowledged: as far as the durable record
    /// knows, this meeting's text has no private-cloud copy.
    case noCloudCopyRecorded = "no-cloud-copy-recorded"
    /// The user's private cloud database acknowledged at least one generation
    /// of this meeting's text aggregate: its text left the Mac in CloudKit
    /// encrypted fields or assets. End-to-end protection additionally depends
    /// on the user's Advanced Data Protection setting, which Portavoz cannot
    /// inspect and therefore does not claim here.
    case acknowledgedByPrivateCloud = "acknowledged-by-private-cloud"
}

/// Local, content-free audit projection for one meeting.
public struct PrivacyReceipt: Equatable, Sendable {
    public let meetingID: MeetingID
    public let coverage: PrivacyReceiptCoverage
    public let trackingStartedAt: Date
    public let generation: [PrivacyReceiptGeneration]
    public let egressEvents: [DataEgressEvent]
    public let syncDisclosure: PrivacyReceiptSyncDisclosure

    public init(
        meetingID: MeetingID,
        meetingStoredAt: Date,
        trackingStartedAt: Date,
        generationRuns: [GenerationRun],
        egressEvents: [DataEgressEvent],
        syncDisclosure: PrivacyReceiptSyncDisclosure
    ) {
        self.meetingID = meetingID
        self.coverage = meetingStoredAt >= trackingStartedAt
            ? .complete
            : .since(trackingStartedAt)
        self.trackingStartedAt = trackingStartedAt
        self.generation = generationRuns.map(PrivacyReceiptGeneration.init)
        self.egressEvents = egressEvents
        self.syncDisclosure = syncDisclosure
    }

    public var remoteEvents: [DataEgressEvent] {
        egressEvents.filter { $0.destinationScope == .remote }
    }

    public var localDeviceEvents: [DataEgressEvent] {
        egressEvents.filter { $0.destinationScope == .localDevice }
    }

    public var status: PrivacyReceiptStatus {
        if !remoteEvents.isEmpty { return .remoteTransferAttempted }
        switch coverage {
        case .complete: return .allContentStayedOnDevice
        case .since: return .noRemoteTransferRecorded
        }
    }
}

public enum DataEgressGatewayError: Error, Equatable, Sendable {
    case invalidMetadata(String)
    case nonHTTPResponse
}

/// The only transport port for meeting-derived data leaving a capability.
/// Concrete network policy and URLSession execution live in an outbound Kit.
public protocol DataEgressGateway: Sendable {
    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse
}
