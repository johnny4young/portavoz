import Foundation
import GRDB
import PortavozCore

struct GlobalDataEgressEventRecord:
    Codable,
    FetchableRecord,
    PersistableRecord {
    static let databaseTableName = "globalDataEgressEvent"

    var id: String
    var operation: String
    var destinationScope: String
    var destinationHost: String
    var dataClassification: String
    var consentSource: String
    var providerID: String
    var modelID: String
    var attemptedAt: Date

    init(_ event: DataEgressEvent, modelID: String) {
        id = event.id.rawValue.uuidString
        operation = event.operation.rawValue
        destinationScope = event.destinationScope.rawValue
        destinationHost = event.destinationHost
        dataClassification = event.dataClassification.rawValue
        consentSource = event.consentSource.rawValue
        providerID = event.providerID
        self.modelID = modelID
        attemptedAt = event.attemptedAt
    }

    var event: DataEgressEvent {
        get throws {
            guard let operation = DataEgressOperation(rawValue: operation),
                  let destinationScope = DataEgressDestinationScope(
                      rawValue: destinationScope),
                  let classification = DataEgressClassification(
                      rawValue: dataClassification),
                  let consentSource = DataEgressConsentSource(
                      rawValue: consentSource)
            else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "policy metadata",
                    value: "unrecognized global egress value")
            }
            return DataEgressEvent(
                id: DataEgressEventID(rawValue: try PersistedIdentity.required(
                    id,
                    table: Self.databaseTableName,
                    column: "id")),
                meetingID: nil,
                operation: operation,
                destinationScope: destinationScope,
                destinationHost: destinationHost,
                dataClassification: classification,
                consentSource: consentSource,
                providerID: providerID,
                modelID: modelID,
                attemptedAt: attemptedAt)
        }
    }
}
