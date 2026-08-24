import Foundation

public enum AskWebEvidenceLimits {
    public static let maximumURLUTF8Bytes = 2_048
    public static let maximumTitleCharacters = 200
    public static let maximumTextCharacters = 16_000
    public static let maximumTextUTF8Bytes = 64_000
}

public enum AskWebFreshness: String, Equatable, Sendable {
    case recent
    case stale
    case unknown
}

public enum AskWebObservedDateKind: String, Equatable, Sendable {
    case published
    case lastModified
    case unavailable
}

/// One direct, user-selected public source. Web evidence has no meeting or
/// segment identity, so it cannot be passed to local-meeting navigation by
/// accident.
public struct AskWebCitation: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let observedDate: Date?
    public let observedDateKind: AskWebObservedDateKind
    public let retrievedAt: Date
    public let freshness: AskWebFreshness
    public let text: String
    public let isExcerptTruncated: Bool

    public init(
        url: URL,
        title: String,
        observedDate: Date?,
        observedDateKind: AskWebObservedDateKind,
        retrievedAt: Date,
        freshness: AskWebFreshness,
        text: String,
        isExcerptTruncated: Bool
    ) {
        self.url = url
        self.title = title
        self.observedDate = observedDate
        self.observedDateKind = observedDateKind
        self.retrievedAt = retrievedAt
        self.freshness = freshness
        self.text = text
        self.isExcerptTruncated = isExcerptTruncated
    }
}

public enum AskWebSourceFailureKind: String, Equatable, Sendable {
    case blockedURL
    case redirected
    case providerUnavailable
    case responseTooLarge
    case unsupportedContent
    case emptyDocument
    case transport
}

public struct AskWebSourceFailure: Equatable, Sendable {
    public let url: URL
    public let kind: AskWebSourceFailureKind

    public init(url: URL, kind: AskWebSourceFailureKind) {
        self.url = url
        self.kind = kind
    }
}

public enum AskWebRetrievalError: Error, Equatable, LocalizedError, Sendable {
    case blockedURL
    case redirected
    case providerUnavailable
    case responseTooLarge
    case unsupportedContent
    case emptyDocument
    case transport

    public var errorDescription: String? {
        switch self {
        case .blockedURL:
            "This web address is not allowed."
        case .redirected:
            "The web address redirected. Paste the final address instead."
        case .providerUnavailable:
            "The web source is unavailable."
        case .responseTooLarge:
            "The web source is too large to read safely."
        case .unsupportedContent:
            "The web source is not readable text or HTML."
        case .emptyDocument:
            "The web source contains no readable text."
        case .transport:
            "The web source could not be reached."
        }
    }

    public var failureKind: AskWebSourceFailureKind {
        switch self {
        case .blockedURL: .blockedURL
        case .redirected: .redirected
        case .providerUnavailable: .providerUnavailable
        case .responseTooLarge: .responseTooLarge
        case .unsupportedContent: .unsupportedContent
        case .emptyDocument: .emptyDocument
        case .transport: .transport
        }
    }
}

public enum AskWebURLPolicy: Equatable, Sendable {
    case publicHTTPS
    case loopbackFixture
}

/// One deterministic URL policy shared by presentation admission and the
/// concrete transport. Presentation cannot consume one-request consent for an
/// address that retrieval will reject later.
public enum AskWebURLValidator {
    public static func validate(
        _ url: URL,
        policy: AskWebURLPolicy
    ) throws {
        guard url.absoluteString.utf8.count
                <= AskWebEvidenceLimits.maximumURLUTF8Bytes,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let host = normalizedHost(url.host),
              !host.isEmpty
        else { throw AskWebRetrievalError.blockedURL }
        let destination = DataEgressDestination(url: url)
        switch policy {
        case .publicHTTPS:
            guard url.scheme?.lowercased() == "https",
                  url.port == nil || url.port == 443,
                  destination.scope == .remote,
                  !isLiteralIPAddress(host),
                  !isPrivateName(host)
            else { throw AskWebRetrievalError.blockedURL }
        case .loopbackFixture:
            guard destination.scope == .localDevice,
                  url.scheme?.lowercased() == "http"
                    || url.scheme?.lowercased() == "https"
            else { throw AskWebRetrievalError.blockedURL }
        }
    }

    public static func admits(
        _ url: URL,
        policy: AskWebURLPolicy
    ) -> Bool {
        do {
            try validate(url, policy: policy)
            return true
        } catch {
            return false
        }
    }

    private static func normalizedHost(_ rawValue: String?) -> String? {
        guard var host = rawValue?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isPrivateName(_ host: String) -> Bool {
        [".local", ".internal", ".lan", ".home", ".localhost"]
            .contains(where: host.hasSuffix)
            || host == "localhost"
    }

    private static func isLiteralIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let components = host.split(
            separator: ".",
            omittingEmptySubsequences: false)
        return components.count == 4
            && components.allSatisfy { component in
                guard let value = Int(component) else { return false }
                return value >= 0 && value <= 255
            }
    }
}

/// Capability port implemented by an outbound adapter. Keeping the evidence
/// contract in Core lets ApplicationKit own orchestration without a capability
/// module depending back on that application layer.
public protocol AskWebSourceRetrieving: Sendable {
    func retrieve(_ url: URL) async throws -> AskWebCitation
}
