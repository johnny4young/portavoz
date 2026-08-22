import Foundation
import PortavozCore
import StorageKit

public enum AutomationEntityLookupError: Error, Equatable, Sendable {
    case invalidLimit
    case tooManyIdentifiers
    case queryTooLong
    case conflictingSelectors
}

/// One bounded query shape shared by protected local entity-catalog consumers.
/// `nil` identifiers means a suggestion or text-search request; an empty
/// identifier list is an exact request for no values.
public struct AutomationEntityLookup<ID: Hashable & Sendable>: Sendable {
    public static var maximumResultCount: Int { 50 }
    public static var maximumQueryCharacterCount: Int { 120 }

    public let identifiers: [ID]?
    public let matching: String?
    public let limit: Int

    public init(
        identifiers: [ID]? = nil,
        matching: String? = nil,
        limit: Int = 20
    ) throws {
        guard (1...Self.maximumResultCount).contains(limit) else {
            throw AutomationEntityLookupError.invalidLimit
        }
        if let identifiers,
           identifiers.count > Self.maximumResultCount {
            throw AutomationEntityLookupError.tooManyIdentifiers
        }
        let matching = matching.map(Self.normalizedQuery)
        if identifiers != nil, matching?.isEmpty == false {
            throw AutomationEntityLookupError.conflictingSelectors
        }
        if let matching,
           matching.count > Self.maximumQueryCharacterCount {
            throw AutomationEntityLookupError.queryTooLong
        }
        self.identifiers = identifiers.map(Self.uniqueIdentifiers)
        self.matching = matching?.isEmpty == false ? matching : nil
        self.limit = limit
    }

    private static func normalizedQuery(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func uniqueIdentifiers(_ values: [ID]) -> [ID] {
        var seen = Set<ID>()
        return values.filter { seen.insert($0).inserted }
    }
}

public protocol AutomationEntityCatalogReading: Sendable {
    func automationMeetings(
        identifiers: [MeetingID]?,
        matchingTitle: String?,
        limit: Int
    ) async throws -> [Meeting]

    func automationPeople(
        identifiers: [PersonID]?,
        matchingName: String?,
        limit: Int
    ) async throws -> [Person]

    func automationCommitments(
        identifiers: [CommitmentID]?,
        matchingTitle: String?,
        limit: Int
    ) async throws -> [Commitment]
}

extension MeetingStore: AutomationEntityCatalogReading {}

/// Application-owned, read-only boundary for native automation and explicit
/// local selectors. It never opens transcript, audio, summary, or evidence.
public struct LoadAutomationEntities: Sendable {
    private let catalog: any AutomationEntityCatalogReading

    public init(catalog: any AutomationEntityCatalogReading) {
        self.catalog = catalog
    }

    public func meetings(
        _ lookup: AutomationEntityLookup<MeetingID>
    ) async throws -> [Meeting] {
        try await catalog.automationMeetings(
            identifiers: lookup.identifiers,
            matchingTitle: lookup.matching,
            limit: lookup.limit)
    }

    public func people(
        _ lookup: AutomationEntityLookup<PersonID>
    ) async throws -> [Person] {
        try await catalog.automationPeople(
            identifiers: lookup.identifiers,
            matchingName: lookup.matching,
            limit: lookup.limit)
    }

    public func commitments(
        _ lookup: AutomationEntityLookup<CommitmentID>
    ) async throws -> [Commitment] {
        try await catalog.automationCommitments(
            identifiers: lookup.identifiers,
            matchingTitle: lookup.matching,
            limit: lookup.limit)
    }
}
