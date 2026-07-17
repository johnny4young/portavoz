import CloudKit

/// Builds only an explicitly injected, manually driven sync engine. The caller
/// owns the private database and must invoke fetch/send after consent;
/// construction creates no container and starts no network operation.
public enum CloudMeetingSyncRuntime {
    public static let subscriptionID = "app.portavoz.meeting-sync.v1"

    public static func make(
        database: CKDatabase,
        delegate: CloudMeetingSyncEngineDelegate
    ) async throws -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: try await delegate.restoredEngineState(),
            delegate: delegate)
        configuration.automaticallySync = false
        configuration.subscriptionID = subscriptionID
        return CKSyncEngine(configuration)
    }
}
