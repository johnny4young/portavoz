import PortavozCore
import StorageKit

public enum ConfirmedTopicCatalogLookupError: Error, Equatable, Sendable {
    case invalidLimit
    case queryTooLong
}

/// One bounded read shape for explicit topic selectors. Text is presentation
/// discovery only: the consumer must still submit the returned exact TopicID
/// to any factual query.
public struct ConfirmedTopicCatalogLookup: Equatable, Sendable {
    public static let maximumResultCount = 50
    public static let maximumQueryCharacterCount = 120

    public let matching: String?
    public let limit: Int

    public init(
        matching: String? = nil,
        limit: Int = 20
    ) throws {
        guard (1...Self.maximumResultCount).contains(limit) else {
            throw ConfirmedTopicCatalogLookupError.invalidLimit
        }
        let matching = matching.flatMap(TopicAliasNormalizer.displayLabel)
        guard (matching?.count ?? 0) <= Self.maximumQueryCharacterCount else {
            throw ConfirmedTopicCatalogLookupError.queryTooLong
        }
        self.matching = matching
        self.limit = limit
    }
}

public protocol ConfirmedTopicCatalogReading: Sendable {
    func confirmedTopics(
        matching query: String?,
        limit: Int
    ) async throws -> [Topic]
}

extension MeetingStore: ConfirmedTopicCatalogReading {}

/// Read-only ApplicationKit boundary for an interactive exact-topic selector.
/// It exposes no meeting content, fact, evidence, or mutation authority.
public struct LoadConfirmedTopicCatalog: ApplicationUseCase {
    private let catalog: any ConfirmedTopicCatalogReading

    public init(catalog: any ConfirmedTopicCatalogReading) {
        self.catalog = catalog
    }

    public func execute(
        _ lookup: ConfirmedTopicCatalogLookup
    ) async throws -> [Topic] {
        try await catalog.confirmedTopics(
            matching: lookup.matching,
            limit: lookup.limit)
    }
}
