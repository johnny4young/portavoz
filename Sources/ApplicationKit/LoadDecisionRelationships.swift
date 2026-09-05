import PortavozCore
import StorageKit

public protocol DecisionHistoryReading: Sendable {
    func decisionHistory(
        _ query: DecisionHistoryQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

extension MeetingStore: DecisionHistoryReading {}

/// Application boundary for "what did we decide about X": the current
/// confirmed decisions linked to one exact topic, superseded truth excluded.
public struct LoadDecisionHistory: ApplicationUseCase {
    private let repository: any DecisionHistoryReading
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        repository: any DecisionHistoryReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.repository = repository
        self.telemetry = telemetry
    }

    public func execute(
        _ query: DecisionHistoryQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await telemetry.measure(.decisionHistory) {
            try await repository.decisionHistory(query)
        }
    }
}

public protocol DecisionConflictsReading: Sendable {
    func decisionConflicts(
        _ query: DecisionConflictsQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

public protocol ChangeSinceReading: Sendable {
    func changeSince(
        _ query: ChangeSinceQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

extension MeetingStore: DecisionConflictsReading {}
extension MeetingStore: ChangeSinceReading {}

/// Application boundary for confirmed decision replacements about one exact
/// topic. Which topic the question names, and how conflicts are phrased, stay
/// outside this exact retrieval boundary.
public struct LoadDecisionConflicts: ApplicationUseCase {
    private let repository: any DecisionConflictsReading
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        repository: any DecisionConflictsReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.repository = repository
        self.telemetry = telemetry
    }

    public func execute(
        _ query: DecisionConflictsQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await telemetry.measure(.decisionConflicts) {
            try await repository.decisionConflicts(query)
        }
    }
}

/// Application boundary for "what changed since one exact meeting". Resolving
/// "the last meeting" to an exact anchor is the caller's job; the adapter
/// abstains on an unresolvable baseline rather than guessing one.
public struct LoadChangeSince: ApplicationUseCase {
    private let repository: any ChangeSinceReading
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        repository: any ChangeSinceReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.repository = repository
        self.telemetry = telemetry
    }

    public func execute(
        _ query: ChangeSinceQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await telemetry.measure(.changeSince) {
            try await repository.changeSince(query)
        }
    }
}
