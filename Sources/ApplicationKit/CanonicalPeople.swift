import PortavozCore
import StorageKit

/// Read-only exact-alias lookup. Duplicate results are intentional and must
/// remain visible to the caller as ambiguity.
public protocol CanonicalPersonCandidateReading: Sendable {
    func people(matchingAlias alias: String) async throws -> [Person]
}

/// Identity mutation stays behind explicit user selection so an alias match
/// can never merge people by itself.
public protocol CanonicalPeopleStore: CanonicalPersonCandidateReading {
    func createPersonAndLink(
        speakerID: SpeakerID,
        preferredName: String,
        source: PersonAliasSource
    ) async throws -> ConfirmedPersonLink
    func linkSpeaker(
        _ speakerID: SpeakerID,
        to personID: PersonID,
        observedAlias: String,
        source: PersonAliasSource
    ) async throws -> ConfirmedPersonLink
}

extension MeetingStore: CanonicalPeopleStore {}

public struct FindCanonicalPeople: ApplicationUseCase {
    private let store: any CanonicalPersonCandidateReading

    public init(store: any CanonicalPersonCandidateReading) {
        self.store = store
    }

    public func execute(_ alias: String) async throws -> [Person] {
        try await store.people(matchingAlias: alias)
    }
}

public enum CanonicalPersonSelection: Sendable {
    case createDistinct
    case existing(PersonID)
}

public struct LinkObservedSpeakerRequest: Sendable {
    public let speakerID: SpeakerID
    public let observedName: String
    public let source: PersonAliasSource
    public let selection: CanonicalPersonSelection

    public init(
        speakerID: SpeakerID,
        observedName: String,
        source: PersonAliasSource,
        selection: CanonicalPersonSelection
    ) {
        self.speakerID = speakerID
        self.observedName = observedName
        self.source = source
        self.selection = selection
    }
}

public struct LinkObservedSpeaker: ApplicationUseCase {
    private let store: any CanonicalPeopleStore

    public init(store: any CanonicalPeopleStore) {
        self.store = store
    }

    public func execute(_ request: LinkObservedSpeakerRequest) async throws
        -> ConfirmedPersonLink {
        switch request.selection {
        case .createDistinct:
            return try await store.createPersonAndLink(
                speakerID: request.speakerID,
                preferredName: request.observedName,
                source: request.source)
        case .existing(let personID):
            return try await store.linkSpeaker(
                request.speakerID,
                to: personID,
                observedAlias: request.observedName,
                source: request.source)
        }
    }
}
