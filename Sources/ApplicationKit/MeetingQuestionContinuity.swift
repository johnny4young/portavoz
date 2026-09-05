import PortavozCore
import StorageKit

public protocol MeetingQuestionContinuityStore: Sendable {
    func confirmMeetingQuestion(
        _ confirmation: MeetingQuestionConfirmation
    ) async throws -> MeetingQuestionContinuity
    func applyMeetingQuestionTransition(
        _ confirmation: MeetingQuestionTransitionConfirmation
    ) async throws -> MeetingQuestionContinuity
    func meetingQuestionContinuity(
        for questionID: MeetingQuestionID
    ) async throws -> MeetingQuestionContinuity
}

extension MeetingStore: MeetingQuestionContinuityStore {}

/// The explicit boundary that turns reviewed wording and current transcript
/// evidence into question authority. It accepts no Companion-card identity.
public struct ConfirmMeetingQuestion: ApplicationUseCase {
    private let store: any MeetingQuestionContinuityStore

    public init(store: any MeetingQuestionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: MeetingQuestionConfirmation
    ) async throws -> MeetingQuestionContinuity {
        try await store.confirmMeetingQuestion(confirmation)
    }
}

public struct ManageMeetingQuestion: ApplicationUseCase {
    private let store: any MeetingQuestionContinuityStore

    public init(store: any MeetingQuestionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: MeetingQuestionTransitionConfirmation
    ) async throws -> MeetingQuestionContinuity {
        try await store.applyMeetingQuestionTransition(confirmation)
    }
}

public struct LoadMeetingQuestionContinuity: ApplicationUseCase {
    private let store: any MeetingQuestionContinuityStore

    public init(store: any MeetingQuestionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ questionID: MeetingQuestionID
    ) async throws -> MeetingQuestionContinuity {
        try await store.meetingQuestionContinuity(for: questionID)
    }
}
