import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingMemoryGraphQueryTelemetryTests: XCTestCase {
    func testTaxonomyIsClosedAndStable() {
        XCTAssertEqual(
            MeetingMemoryGraphQueryJob.allCases.map(\.rawValue),
            [
                "commitmentBlockers",
                "topicFirstDiscussion",
                "personCommitments",
                "decisionConflicts",
                "changeSince",
                "decisionHistory",
            ])
        XCTAssertEqual(
            MeetingMemoryGraphQueryOutcome.allCases.map(\.rawValue),
            ["facts", "abstained", "cancelled", "failed"])
    }

    func testTraceClassifiesFactsAndAbstentionWithoutPayload() async throws {
        let recorder = MeetingMemoryGraphQueryEventRecorder()
        let telemetry = MeetingMemoryGraphQueryTelemetry(
            receiver: recorder.receive)
        let page = MeetingMemoryGraphFactPage(
            facts: [],
            hasMore: false,
            projectionGeneration: 4,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0)

        let facts = await telemetry.measure(.decisionHistory) {
            .facts(page)
        }
        let abstained = await telemetry.measure(.changeSince) {
            .abstained(.invalidQuery)
        }

        XCTAssertEqual(facts, .facts(page))
        XCTAssertEqual(abstained, .abstained(.invalidQuery))
        XCTAssertEqual(recorder.events.count, 4)
        try assertMatched(
            start: recorder.events[0],
            finish: recorder.events[1],
            job: .decisionHistory,
            outcome: .facts)
        try assertMatched(
            start: recorder.events[2],
            finish: recorder.events[3],
            job: .changeSince,
            outcome: .abstained)
    }

    func testTraceClassifiesCancellationAndFailureWithoutErrorPayload() async throws {
        let recorder = MeetingMemoryGraphQueryEventRecorder()
        let telemetry = MeetingMemoryGraphQueryTelemetry(
            receiver: recorder.receive)

        do {
            _ = try await telemetry.measure(.personCommitments) {
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        do {
            _ = try await telemetry.measure(.commitmentBlockers) {
                throw MeetingMemoryGraphTelemetryTestError.failed
            }
            XCTFail("Expected failure")
        } catch is MeetingMemoryGraphTelemetryTestError {
            // Expected.
        }

        XCTAssertEqual(recorder.events.count, 4)
        try assertMatched(
            start: recorder.events[0],
            finish: recorder.events[1],
            job: .personCommitments,
            outcome: .cancelled)
        try assertMatched(
            start: recorder.events[2],
            finish: recorder.events[3],
            job: .commitmentBlockers,
            outcome: .failed)
    }

    func testEveryExactUseCaseEmitsItsStableJob() async throws {
        let recorder = MeetingMemoryGraphQueryEventRecorder()
        let telemetry = MeetingMemoryGraphQueryTelemetry(
            receiver: recorder.receive)
        let repository = FixedMeetingMemoryGraphQueryRepository(
            result: .abstained(.projectionNotReady))
        let topicID = TopicID()

        _ = try await LoadCommitmentBlockers(
            repository: repository,
            telemetry: telemetry)
            .execute(CommitmentBlockerQuery(commitmentID: CommitmentID()))
        _ = try await LoadTopicFirstDiscussion(
            repository: repository,
            telemetry: telemetry)
            .execute(TopicFirstDiscussionQuery(topicID: topicID))
        _ = try await LoadPersonCommitments(
            repository: repository,
            telemetry: telemetry)
            .execute(PersonCommitmentsQuery(personID: PersonID()))
        _ = try await LoadDecisionConflicts(
            repository: repository,
            telemetry: telemetry)
            .execute(DecisionConflictsQuery(topicID: topicID))
        _ = try await LoadChangeSince(
            repository: repository,
            telemetry: telemetry)
            .execute(ChangeSinceQuery(
                topicID: topicID,
                sinceMeetingID: MeetingID()))
        _ = try await LoadDecisionHistory(
            repository: repository,
            telemetry: telemetry)
            .execute(DecisionHistoryQuery(topicID: topicID))

        let startedJobs: [MeetingMemoryGraphQueryJob] =
            recorder.events.compactMap { event in
                guard case .started(let trace) = event else { return nil }
                return trace.job
            }
        let outcomes: [MeetingMemoryGraphQueryOutcome] =
            recorder.events.compactMap { event in
                guard case .finished(_, let outcome) = event else { return nil }
                return outcome
            }
        XCTAssertEqual(startedJobs, MeetingMemoryGraphQueryJob.allCases)
        XCTAssertEqual(outcomes, Array(
            repeating: MeetingMemoryGraphQueryOutcome.abstained,
            count: MeetingMemoryGraphQueryJob.allCases.count))
    }

    func testAliasResolutionStartsTelemetryOnlyAfterExactIdentity() async throws {
        let recorder = MeetingMemoryGraphQueryEventRecorder()
        let telemetry = MeetingMemoryGraphQueryTelemetry(
            receiver: recorder.receive)
        let repository = FixedMeetingMemoryGraphQueryRepository(
            result: .abstained(.projectionNotReady))
        let first = Person(preferredName: "Ana")
        let second = Person(preferredName: "Ana")

        let ambiguous = try await LoadPersonCommitmentsByAlias(
            people: FixedCanonicalPersonCandidates(people: [first, second]),
            commitments: repository,
            telemetry: telemetry)
            .execute(PersonCommitmentsAliasQuery(alias: "Ana"))
        XCTAssertEqual(ambiguous, .abstained(.ambiguousPerson))
        XCTAssertEqual(recorder.events, [])

        let exact = try await LoadPersonCommitmentsByAlias(
            people: FixedCanonicalPersonCandidates(people: [first]),
            commitments: repository,
            telemetry: telemetry)
            .execute(PersonCommitmentsAliasQuery(alias: "Ana"))
        XCTAssertEqual(exact, .abstained(.projectionNotReady))
        XCTAssertEqual(recorder.events.count, 2)
        try assertMatched(
            start: recorder.events[0],
            finish: recorder.events[1],
            job: .personCommitments,
            outcome: .abstained)
    }

    func testAppAdapterObserverHasExplicitLifetime() async throws {
        let recorder = MeetingMemoryGraphQueryEventRecorder()
        let adapter = AppMeetingMemoryGraphQueryTelemetry()
        let observer = adapter.addObserver(recorder.receive)

        _ = await adapter.telemetry.measure(.topicFirstDiscussion) {
            .abstained(.topicUnavailable)
        }
        adapter.removeObserver(observer)
        _ = await adapter.telemetry.measure(.topicFirstDiscussion) {
            .abstained(.topicUnavailable)
        }

        XCTAssertEqual(recorder.events.count, 2)
        try assertMatched(
            start: recorder.events[0],
            finish: recorder.events[1],
            job: .topicFirstDiscussion,
            outcome: .abstained)
    }

    private func assertMatched(
        start: MeetingMemoryGraphQueryEvent,
        finish: MeetingMemoryGraphQueryEvent,
        job: MeetingMemoryGraphQueryJob,
        outcome: MeetingMemoryGraphQueryOutcome
    ) throws {
        guard case .started(let started) = start,
              case .finished(let finished, let actualOutcome) = finish
        else { return XCTFail("Expected a matched telemetry interval") }
        XCTAssertEqual(started, finished)
        XCTAssertEqual(started.job, job)
        XCTAssertEqual(actualOutcome, outcome)
    }
}

private final class MeetingMemoryGraphQueryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeetingMemoryGraphQueryEvent] = []

    var events: [MeetingMemoryGraphQueryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ event: MeetingMemoryGraphQueryEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private struct FixedMeetingMemoryGraphQueryRepository:
    CommitmentBlockerFactReading,
    TopicFirstDiscussionReading,
    PersonCommitmentFactReading,
    DecisionConflictsReading,
    ChangeSinceReading,
    DecisionHistoryReading
{
    let result: MeetingMemoryGraphQueryResult

    func commitmentBlockerFacts(
        _ query: CommitmentBlockerQuery
    ) async throws -> MeetingMemoryGraphQueryResult { result }

    func topicFirstDiscussion(
        _ query: TopicFirstDiscussionQuery
    ) async throws -> MeetingMemoryGraphQueryResult { result }

    func personCommitmentFacts(
        _ query: PersonCommitmentsQuery
    ) async throws -> MeetingMemoryGraphQueryResult { result }

    func decisionConflicts(
        _ query: DecisionConflictsQuery
    ) async throws -> MeetingMemoryGraphQueryResult { result }

    func changeSince(
        _ query: ChangeSinceQuery
    ) async throws -> MeetingMemoryGraphQueryResult { result }

    func decisionHistory(
        _ query: DecisionHistoryQuery
    ) async throws -> MeetingMemoryGraphQueryResult { result }
}

private struct FixedCanonicalPersonCandidates: CanonicalPersonCandidateReading {
    let people: [Person]

    func people(matchingAlias alias: String) async throws -> [Person] {
        people
    }
}

private enum MeetingMemoryGraphTelemetryTestError: Error {
    case failed
}
