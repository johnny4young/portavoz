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
        scope = Self.scope(for: url)
    }

    private static func scope(for url: URL) -> DataEgressDestinationScope {
        guard let rawHost = url.host else { return .remote }
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
}

public enum DataEgressClassification: String, Codable, Sendable {
    /// Only the classified participant question, never transcript context.
    case meetingQuestionOnly = "meeting-question-only"
    /// Formatted transcript, speaker labels, user notes, glossary, and recipe
    /// instructions required to generate one summary.
    case meetingSummaryMaterial = "meeting-summary-material"
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
