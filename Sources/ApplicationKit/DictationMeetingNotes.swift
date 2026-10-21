import Foundation
import PortavozCore
import StorageKit

/// Copies a saved dictation into a finished meeting's notes, by explicit user action.
public protocol DictationMeetingNoteStore: Sendable {
    func meetingsForDictation(createdAt: Date, limit: Int) async throws -> [DictationMeetingChoice]
    func addDictationToMeeting(
        _ dictationID: DictationRecordID, meetingID: MeetingID, at now: Date
    ) async throws -> AddDictationToMeetingOutcome
    func dictationMeetingLinks(
        for dictationIDs: [DictationRecordID]
    ) async throws -> [DictationRecordID: [DictationMeetingLink]]
}

extension MeetingStore: DictationMeetingNoteStore {}

public struct ListMeetingsForDictation: ApplicationUseCase {
    public static let limit = 20

    private let store: any DictationMeetingNoteStore

    public init(store: any DictationMeetingNoteStore) {
        self.store = store
    }

    public func execute(_ request: DictationRecord) async throws -> [DictationMeetingChoice] {
        try await store.meetingsForDictation(createdAt: request.createdAt, limit: Self.limit)
    }
}

public struct AddDictationToMeeting: ApplicationUseCase {
    public struct Request: Sendable {
        public let dictationID: DictationRecordID
        public let meetingID: MeetingID

        public init(dictationID: DictationRecordID, meetingID: MeetingID) {
            self.dictationID = dictationID
            self.meetingID = meetingID
        }
    }

    private let store: any DictationMeetingNoteStore
    private let now: @Sendable () -> Date

    public init(store: any DictationMeetingNoteStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func execute(_ request: Request) async throws -> AddDictationToMeetingOutcome {
        try await store.addDictationToMeeting(request.dictationID, meetingID: request.meetingID, at: now())
    }
}

public struct LoadDictationMeetingLinks: ApplicationUseCase {
    private let store: any DictationMeetingNoteStore

    public init(store: any DictationMeetingNoteStore) {
        self.store = store
    }

    public func execute(
        _ request: [DictationRecordID]
    ) async throws -> [DictationRecordID: [DictationMeetingLink]] {
        try await store.dictationMeetingLinks(for: request)
    }
}
