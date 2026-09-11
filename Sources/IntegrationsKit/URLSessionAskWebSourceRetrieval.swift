import Foundation
import PortavozCore

/// Direct-page retrieval behind the same receipt-before-transport gateway as
/// every other outbound operation. Redirects are intentionally not followed:
/// the source shown to the user is the destination that receives the request.
public struct URLSessionAskWebSourceRetrieval: AskWebSourceRetrieving {
    private let gateway: any DataEgressGateway
    private let policy: AskWebURLPolicy
    private let now: @Sendable () -> Date

    public init(
        gateway: any DataEgressGateway,
        policy: AskWebURLPolicy = .publicHTTPS,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gateway = gateway
        self.policy = policy
        self.now = now
    }

    public func retrieve(_ url: URL) async throws -> AskWebCitation {
        try AskWebURLValidator.validate(url, policy: policy)
        try Task.checkCancellation()
        let response = try await fetch(url)
        try Task.checkCancellation()
        try Self.validateStatus(response.statusCode)
        try Self.validateContentType(response.headers["content-type"])
        let document = AskWebDocumentParser.parse(response.data)
        guard !document.text.isEmpty else {
            throw AskWebRetrievalError.emptyDocument
        }
        let retrievedAt = now()
        let observed = Self.observedDate(
            headers: response.headers,
            document: document)
        return AskWebCitation(
            url: url,
            title: document.title ?? Self.fallbackTitle(for: url),
            observedDate: observed.date,
            observedDateKind: observed.kind,
            retrievedAt: retrievedAt,
            freshness: Self.freshness(
                observedAt: observed.date,
                retrievedAt: retrievedAt),
            text: document.text,
            isExcerptTruncated: document.isTruncated)
    }

    private func fetch(_ url: URL) async throws -> DataEgressResponse {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue(
            "text/html, application/xhtml+xml, text/plain;q=0.9",
            forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Portavoz/1.0 Web Ask", forHTTPHeaderField: "User-Agent")
        let host = url.host?.lowercased() ?? ""
        let metadata = DataEgressRequest(
            operation: .webSourceRetrieval,
            destination: DataEgressDestination(url: url),
            dataClassification: .publicWebSourceRequest,
            meetingID: nil,
            consentSource: .explicitWebAsk,
            providerDisclosure: DataEgressProviderDisclosure(
                providerID: host))
        let response: DataEgressResponse
        do {
            response = try await gateway.perform(request, metadata: metadata)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DataEgressGatewayError {
            if case .responseTooLarge = error {
                throw AskWebRetrievalError.responseTooLarge
            }
            throw AskWebRetrievalError.transport
        } catch {
            try Task.checkCancellation()
            throw AskWebRetrievalError.transport
        }
        return response
    }

    private static func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200..<300:
            break
        case 300..<400:
            throw AskWebRetrievalError.redirected
        case 500..<600:
            throw AskWebRetrievalError.providerUnavailable
        default:
            throw AskWebRetrievalError.transport
        }
    }

    private static func validateContentType(_ rawValue: String?) throws {
        guard let contentType = rawValue?.lowercased(),
              contentType.hasPrefix("text/html")
                || contentType.hasPrefix("text/plain")
                || contentType.hasPrefix("application/xhtml+xml")
        else { throw AskWebRetrievalError.unsupportedContent }
    }

    private static func observedDate(
        headers: [String: String],
        document: AskWebParsedDocument
    ) -> (date: Date?, kind: AskWebObservedDateKind) {
        if let raw = headers["x-portavoz-fixture-published-at"],
           let date = ISO8601DateFormatter().date(from: raw) {
            return (date, .published)
        }
        if let date = document.observedDate {
            return (date, .published)
        }
        if let raw = headers["last-modified"],
           let date = HTTPDateParser.date(from: raw) {
            return (date, .lastModified)
        }
        return (nil, .unavailable)
    }

    private static func freshness(
        observedAt: Date?,
        retrievedAt: Date
    ) -> AskWebFreshness {
        guard let observedAt else { return .unknown }
        let age = retrievedAt.timeIntervalSince(observedAt)
        guard age >= 0 else { return .unknown }
        return age <= 90 * 86_400 ? .recent : .stale
    }

    private static func fallbackTitle(for url: URL) -> String {
        let host = url.host ?? "Web source"
        return url.path == "/" || url.path.isEmpty
            ? host
            : host + url.path
    }

}

private enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}
