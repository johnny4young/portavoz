import Foundation
import PortavozCore
import StorageKit

public protocol RecordingInputStore: Sendable {
    func persistRecordingInput(
        _ items: [ContextItem], removing removedIDs: [UUID], for meetingID: MeetingID
    ) async throws
}

public protocol RecordingInputPresence: Sendable {
    func hasRecordingInput(for meetingID: MeetingID) async throws -> Bool
}

extension MeetingStore: RecordingInputStore, RecordingInputPresence {}

/// Explicit live authoring uses canonical context rows, not a second journal
/// whose promotion could fail independently of the captured aggregate.
public struct PersistRecordingInput: Sendable {
    private let store: any RecordingInputStore

    public init(store: any RecordingInputStore) {
        self.store = store
    }

    public func execute(
        meetingID: MeetingID,
        items: [ContextItem] = [],
        removing removedIDs: [UUID] = []
    ) async throws {
        try Task.checkCancellation()
        try await store.persistRecordingInput(items, removing: removedIDs, for: meetingID)
        // Do not turn a committed write into a reported cancellation.
    }
}
