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
        let disclosure = metadata.providerDisclosure
        guard !disclosure.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              disclosure.providerID.caseInsensitiveCompare(url.host ?? "BYOK") == .orderedSame
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "provider disclosure does not match the destination")
        }
        switch metadata.operation {
        case .companionKnowledgeAnswer:
            guard networkRequest.httpMethod == "POST",
                  networkRequest.httpBody?.isEmpty == false,
                  metadata.dataClassification == .meetingQuestionOnly
            else {
                throw DataEgressGatewayError.invalidMetadata(
                    "Companion egress requires a classified non-empty POST")
            }
            if metadata.consentSource == .companionBYOKSettings,
               metadata.meetingID == nil {
                throw DataEgressGatewayError.invalidMetadata(
                    "Settings-approved Companion egress requires a meeting identity")
            }
        }
    }
}
