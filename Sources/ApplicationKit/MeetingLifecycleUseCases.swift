import PortavozCore
import StorageKit

/// The narrow persistence port required by meeting lifecycle mutations.
///
/// Keeping this protocol smaller than `MeetingStore` lets use-case tests prove
/// delegation and error propagation without constructing a database. The real
/// store remains the only production adapter.
public protocol MeetingLifecycleStore: Sendable {
    func delete(_ id: MeetingID) async throws
    func restore(_ id: MeetingID) async throws
}

extension MeetingStore: MeetingLifecycleStore {}

/// Cohesive composition value for the meeting lifecycle commands.
public struct MeetingLifecycleUseCases: Sendable {
    public let delete: DeleteMeeting
    public let restore: RestoreMeeting

    public init(store: any MeetingLifecycleStore) {
        delete = DeleteMeeting(store: store)
        restore = RestoreMeeting(store: store)
    }
}

/// Moves a meeting to Recently Deleted without removing its aggregate.
public struct DeleteMeeting: ApplicationUseCase {
    private let store: any MeetingLifecycleStore

    public init(store: any MeetingLifecycleStore) {
        self.store = store
    }

    public func execute(_ request: MeetingID) async throws {
        try await store.delete(request)
    }
}

/// Restores a tombstoned meeting and all child projections.
public struct RestoreMeeting: ApplicationUseCase {
    private let store: any MeetingLifecycleStore

    public init(store: any MeetingLifecycleStore) {
        self.store = store
    }

    public func execute(_ request: MeetingID) async throws {
        try await store.restore(request)
    }
}
