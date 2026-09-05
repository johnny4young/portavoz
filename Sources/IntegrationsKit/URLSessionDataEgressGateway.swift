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
        let (bytes, response) = try await session.bytes(
            for: networkRequest,
            delegate: DataEgressRedirectBlocker())
        guard let http = response as? HTTPURLResponse else {
            throw DataEgressGatewayError.nonHTTPResponse
        }
        let maximumBytes = Self.maximumResponseBytes(for: metadata.operation)
        if http.expectedContentLength > Int64(maximumBytes) {
            throw DataEgressGatewayError.responseTooLarge(
                actualBytes: Int(clamping: http.expectedContentLength),
                maximumBytes: maximumBytes)
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(
                Int(clamping: http.expectedContentLength),
                maximumBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw DataEgressGatewayError.responseTooLarge(
                    actualBytes: maximumBytes + 1,
                    maximumBytes: maximumBytes)
            }
            data.append(byte)
        }
        return DataEgressResponse(
            data: data,
            statusCode: http.statusCode,
            headers: Self.headers(from: http))
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
            try validateCompanionRequest(networkRequest, metadata: metadata)
        case .askAnswerGeneration:
            try validateAskRequest(networkRequest, metadata: metadata)
        case .webSourceRetrieval:
            try validateWebSourceRequest(networkRequest, metadata: metadata)
        case .summaryGeneration:
            try validateSummaryRequest(networkRequest, metadata: metadata)
        case .publishGitHubGist:
            try validateGitHubGistRequest(networkRequest, metadata: metadata)
        case .createGitHubIssue:
            try validateGitHubIssueRequest(networkRequest, metadata: metadata)
        case .createLinearIssue:
            try validateLinearIssueRequest(networkRequest, metadata: metadata)
        }
    }

    private static func validateCompanionRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        try validateChatRequest(
            networkRequest,
            metadata: metadata,
            classification: .meetingQuestionOnly,
            label: "Apuntador")
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
    }

    private static func validateAskRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        guard metadata.dataClassification == .meetingAnswerMaterial
                || metadata.dataClassification == .publicWebAnswerMaterial
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "Ask answer generation requires answer-only material")
        }
        try validateChatRequest(
            networkRequest,
            metadata: metadata,
            classification: metadata.dataClassification,
            label: "Ask")
        guard metadata.destination.scope == .localDevice else {
            throw DataEgressGatewayError.invalidMetadata(
                "Ask answer generation requires a loopback destination")
        }
        guard metadata.consentSource == .summaryEngineSettings else {
            throw DataEgressGatewayError.invalidMetadata(
                "Ask answer generation requires local-engine consent")
        }
    }

    private static func validateSummaryRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
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

    private static func validateWebSourceRequest(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) throws {
        guard let url = networkRequest.url,
              networkRequest.httpMethod == "GET",
              networkRequest.httpBody == nil,
              metadata.meetingID == nil,
              metadata.dataClassification == .publicWebSourceRequest,
              metadata.consentSource == .explicitWebAsk,
              metadata.providerDisclosure.modelID == nil
        else {
            throw DataEgressGatewayError.invalidMetadata(
                "Web Ask requires one explicitly consented public-source GET")
        }
        let scheme = url.scheme?.lowercased()
        switch metadata.destination.scope {
        case .localDevice:
            guard scheme == "http" || scheme == "https" else {
                throw DataEgressGatewayError.invalidMetadata(
                    "Loopback Web Ask requires HTTP or HTTPS")
            }
        case .remote:
            guard scheme == "https" else {
                throw DataEgressGatewayError.invalidMetadata(
                    "Remote Web Ask requires HTTPS")
            }
        }
    }

    private static func maximumResponseBytes(
        for operation: DataEgressOperation
    ) -> Int {
        switch operation {
        case .webSourceRetrieval:
            512 * 1_024
        case .companionKnowledgeAnswer,
             .askAnswerGeneration,
             .summaryGeneration,
             .publishGitHubGist,
             .createGitHubIssue,
             .createLinearIssue:
            2 * 1_024 * 1_024
        }
    }

    private static func headers(
        from response: HTTPURLResponse
    ) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key.lowercased()] = String(describing: entry.value)
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
