import AppIntents
import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

struct AppAutomationEntityCatalog: PortavozAppEntityCatalog {
    private let loader: LoadAutomationEntities

    init(store: StorageKit.MeetingStore) {
        loader = LoadAutomationEntities(catalog: store)
    }

    func meetings(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozMeetingEntity] {
        let values = try await loader.meetings(AutomationEntityLookup(
            identifiers: identifiers.map(Self.meetingIDs),
            matching: matching,
            limit: limit))
        return values.map {
            PortavozMeetingEntity(
                id: $0.id.rawValue.uuidString,
                title: $0.title,
                dateDescription: $0.startedAt.formatted(
                    date: .abbreviated,
                    time: .shortened),
                startedAt: $0.startedAt)
        }
    }

    func people(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozPersonEntity] {
        let values = try await loader.people(AutomationEntityLookup(
            identifiers: identifiers.map(Self.personIDs),
            matching: matching,
            limit: limit))
        return values.map {
            PortavozPersonEntity(
                id: $0.id.rawValue.uuidString,
                name: $0.preferredName)
        }
    }

    func commitments(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozCommitmentEntity] {
        let values = try await loader.commitments(AutomationEntityLookup(
            identifiers: identifiers.map(Self.commitmentIDs),
            matching: matching,
            limit: limit))
        return values.map {
            PortavozCommitmentEntity(
                id: $0.id.rawValue.uuidString,
                title: $0.title,
                dueDescription: $0.dueAt?.formatted(
                    date: .abbreviated,
                    time: .omitted),
                dueAt: $0.dueAt)
        }
    }
}

private extension AppAutomationEntityCatalog {
    static func meetingIDs(_ values: [String]) -> [MeetingID] {
        values.compactMap(UUID.init(uuidString:)).map(MeetingID.init(rawValue:))
    }

    static func personIDs(_ values: [String]) -> [PersonID] {
        values.compactMap(UUID.init(uuidString:)).map(PersonID.init(rawValue:))
    }

    static func commitmentIDs(_ values: [String]) -> [CommitmentID] {
        values.compactMap(UUID.init(uuidString:)).map(CommitmentID.init(rawValue:))
    }
}

extension AppServices {
    func installAutomationEntityCatalog() {
        let catalog: any PortavozAppEntityCatalog = AppAutomationEntityCatalog(store: store)
        AppDependencyManager.shared.add(dependency: catalog)
    }
}
