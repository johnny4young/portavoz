import Foundation
import PortavozCore

/// Outbound adapter for policy-checked meeting-data transfers. Metadata is
/// validated before URLSession can observe the payload.
public struct URLSessionDataEgressGateway: DataEgressGateway {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        try Self.validate(networkRequest, metadata: metadata)
        let (data, response) = try await session.data(for: networkRequest)
        guard let http = response as? HTTPURLResponse else {
            throw DataEgressGatewayError.nonHTTPResponse
        }
        return DataEgressResponse(data: data, statusCode: http.statusCode)
    }

    static func validate(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        let url = try validateDestination(networkRequest, metadata: metadata)
        try validateProvider(metadata.providerDisclosure, for: url)
        try validateOperation(networkRequest, metadata: metadata)
    }

    private static func validateDestination(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws -> URL {
        guard let url = networkRequest.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "destination is not an HTTP endpoint")
        }
        guard metadata.destination == DataEgressDestination(url: url)
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "destination does not match the network request")
        }
        return url
    }

    private static func validateProvider(
        _ disclosure: DataEgressProviderDisclosure,
        for url: URL
    ) throws {
        let providerID = disclosure.providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty,
              providerID.caseInsensitiveCompare(url.host ?? "") == .orderedSame
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "provider disclosure does not match the destination")
        }
    }

    private static func validateOperation(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        switch metadata.operation {
        case .companionKnowledgeAnswer:
            try validateChatRequest(
                networkRequest,
                metadata: metadata,
                classification: .meetingQuestionOnly,
                label: "Companion")
            guard metadata.consentSource == .companionBYOKSettings
                    || metadata.consentSource == .explicitCompanionClient
            else {
                throw DataEgressGatewayError.invalidMetadata(
                    "Companion egress requires Companion-specific consent")
            }
            if metadata.consentSource == .companionBYOKSettings,
               metadata.meetingID == nil {
                throw DataEgressGatewayError.invalidMetadata(
                    "Settings-approved Companion egress requires a meeting identity")
            }
        case .summaryGeneration:
            try validateChatRequest(
                networkRequest,
                metadata: metadata,
                classification: .meetingSummaryMaterial,
                label: "Summary")
            guard metadata.meetingID != nil else {
                throw DataEgressGatewayError.invalidMetadata(
                    "Summary egress requires a meeting identity")
            }
            guard metadata.consentSource == .summaryEngineSettings
                    || metadata.consentSource == .explicitSummaryProvider
            else {
                throw DataEgressGatewayError.invalidMetadata(
                    "Summary egress requires summary-specific consent")
            }
        }
    }

    private static func validateChatRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest,
        classification: DataEgressClassification,
        label: String
    ) throws {
        let modelID = metadata.providerDisclosure.modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard networkRequest.httpMethod == "POST",
              networkRequest.httpBody?.isEmpty == false,
              metadata.dataClassification == classification,
              modelID?.isEmpty == false
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "\(label) egress requires a classified non-empty model POST")
        }
    }
}
