import Foundation
import PortavozCore
import StorageKit

/// Reads for local agents such as the MCP server. Consent is checked by the
/// store in the same read as the rows, on every call.
public protocol DictationAgentStore: Sendable {
    func dictationRecordsForAgents(
        matching filter: DictationRecordFilter, offset: Int, limit: Int
    ) async throws -> DictationAgentRead<DictationRecordPage>
    func dictationRecordForAgents(_ id: DictationRecordID) async throws -> DictationAgentRead<DictationRecord?>
}

extension MeetingStore: DictationAgentStore {}

public struct ReadDictationsForAgents: ApplicationUseCase {
    public struct Request: Sendable {
        public let filter: DictationRecordFilter
        public let offset: Int
        public let limit: Int

        public init(filter: DictationRecordFilter, offset: Int, limit: Int) {
            self.filter = filter
            self.offset = offset
            self.limit = limit
        }
    }

    private let store: any DictationAgentStore

    public init(store: any DictationAgentStore) {
        self.store = store
    }

    public func execute(_ request: Request) async throws -> DictationAgentRead<DictationRecordPage> {
        try await store.dictationRecordsForAgents(
            matching: request.filter, offset: request.offset, limit: request.limit)
    }
}

public struct ReadDictationForAgents: ApplicationUseCase {
    private let store: any DictationAgentStore

    public init(store: any DictationAgentStore) {
        self.store = store
    }

    public func execute(_ request: DictationRecordID) async throws -> DictationAgentRead<DictationRecord?> {
        try await store.dictationRecordForAgents(request)
    }
}
