import Foundation
import PortavozCore

/// Outbound adapter for policy-checked meeting-data transfers. Metadata is
/// validated before URLSession can observe the payload.
public struct URLSessionDataEgressGateway: DataEgressGateway {
    private let session: URLSession
    private let receiptRecorder: any DataEgressEventRecorder
    private let now: @Sendable () -> Date
    private let makeEventID: @Sendable () -> DataEgressEventID

    /// The recorder is required by type, not by composition discipline: a
    /// gateway that cannot persist the attempt must not exist, so the
    /// "immutable attempt persisted before transport" invariant cannot be
    /// silently skipped by a forgotten argument.
    public init(
        session: URLSession = .shared,
        receiptRecorder: any DataEgressEventRecorder,
        now: @escaping @Sendable () -> Date = { Date() },
        makeEventID: @escaping @Sendable () -> DataEgressEventID = { DataEgressEventID() }
    ) {
        self.session = session
        self.receiptRecorder = receiptRecorder
        self.now = now
        self.makeEventID = makeEventID
    }

    public func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        try Self.validate(networkRequest, metadata: metadata)
        try await receiptRecorder.recordDataEgressEvent(DataEgressEvent(
            id: makeEventID(),
            request: metadata,
            attemptedAt: now()))
        let (data, response) = try await session.data(
            for: networkRequest,
            delegate: DataEgressRedirectBlocker())
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
        case .publishGitHubGist:
            try validateGitHubGistRequest(networkRequest, metadata: metadata)
        case .createGitHubIssue:
            try validateGitHubIssueRequest(networkRequest, metadata: metadata)
        case .createLinearIssue:
            try validateLinearIssueRequest(networkRequest, metadata: metadata)
        }
    }

    private static func validateGitHubGistRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        try validatePublishingRequest(
            networkRequest,
            metadata: metadata,
            classification: .meetingExportDocument,
            consentSource: .explicitGistPublish,
            label: "Gist")
        guard networkRequest.url == URL(string: "https://api.github.com/gists")
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "Gist egress requires the canonical GitHub endpoint")
        }
    }

    private static func validateGitHubIssueRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        try validatePublishingRequest(
            networkRequest,
            metadata: metadata,
            classification: .meetingActionItem,
            consentSource: .explicitGitHubIssuePublish,
            label: "GitHub Issue")
        guard let url = networkRequest.url, isCanonicalGitHubIssueURL(url)
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "GitHub Issue egress requires a canonical repository endpoint")
        }
    }

    private static func validateLinearIssueRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        try validatePublishingRequest(
            networkRequest,
            metadata: metadata,
            classification: .meetingActionItem,
            consentSource: .explicitLinearIssuePublish,
            label: "Linear Issue")
        guard networkRequest.url == URL(string: "https://api.linear.app/graphql")
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "Linear Issue egress requires the canonical Linear endpoint")
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

    private static func validatePublishingRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest,
        classification: DataEgressClassification,
        consentSource: DataEgressConsentSource,
        label: String
    ) throws {
        guard networkRequest.httpMethod == "POST",
              networkRequest.httpBody?.isEmpty == false,
              metadata.meetingID != nil,
              metadata.dataClassification == classification,
              metadata.consentSource == consentSource,
              metadata.providerDisclosure.modelID == nil
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "\(label) egress requires explicit classified publishing metadata")
        }
    }

    private static func isCanonicalGitHubIssueURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.github.com",
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 5,
              components[0].isEmpty,
              components[1] == "repos",
              !components[2].isEmpty,
              !components[3].isEmpty,
              components[4] == "issues"
        else { return false }
        return components[2] != "." && components[2] != ".."
            && components[3] != "." && components[3] != ".."
    }
}

/// A validated endpoint cannot silently redirect meeting material to another
/// destination. Provider APIs used by Portavoz have canonical final URLs; a
/// redirect is returned to the caller as the original 3xx response.
final class DataEgressRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
