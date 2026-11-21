import Foundation
import PortavozCore
import StorageKit

public protocol TodayWorkReading: Sendable {
    func playbackPositions(for meetingIDs: [MeetingID]) async throws -> [MeetingID: MeetingPlaybackPosition]
    func openItemSources(for itemIDs: [UUID]) async throws -> [UUID: OpenItemSource]
}

extension MeetingStore: TodayWorkReading {}

/// What Today's work rows add to the library snapshot. A part that failed to
/// read is nil, so the screen keeps what it showed instead of claiming "unheard".
public struct TodayWork: Sendable, Equatable {
    public let positions: [MeetingID: MeetingPlaybackPosition]?
    public let sources: [UUID: OpenItemSource]?

    public init(positions: [MeetingID: MeetingPlaybackPosition]?, sources: [UUID: OpenItemSource]?) {
        self.positions = positions
        self.sources = sources
    }
}

/// Reads where listening stopped and who said each shown to-do, each independently.
public struct LoadTodayWork: ApplicationUseCase {
    public struct Request: Sendable {
        public let meetingIDs: [MeetingID]
        public let itemIDs: [UUID]

        public init(meetingIDs: [MeetingID], itemIDs: [UUID]) {
            self.meetingIDs = meetingIDs
            self.itemIDs = itemIDs
        }
    }

    private let store: any TodayWorkReading

    public init(store: any TodayWorkReading) {
        self.store = store
    }

    public func execute(_ request: Request) async throws -> TodayWork {
        async let positions = Self.attempt { try await store.playbackPositions(for: request.meetingIDs) }
        async let sources = Self.attempt { try await store.openItemSources(for: request.itemIDs) }
        let work = try await TodayWork(positions: positions, sources: sources)
        try Task.checkCancellation()
        return work
    }

    private static func attempt<Value: Sendable>(
        _ read: @Sendable () async throws -> Value
    ) async throws -> Value? {
        do {
            return try await read()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}
