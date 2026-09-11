@testable import ApplicationKit
import Foundation
import os
import PortavozCore
import XCTest

final class AskBundleAdmissionTests: XCTestCase {
    func testLegacyInitializerRemainsSourceCompatible() {
        let evidence = BundleAdmissionFixture().evidence
        for text in [nil, "Supported answer"] {
            let answer = AskEvidenceBundleAnswer(
                question: "when", generatedText: text, evidence: evidence)
            XCTAssertEqual(answer.generationOutcome, text == nil ? .unavailable : .generated)
            XCTAssertEqual(answer.evidence, evidence)
        }
    }

    func testMissingProviderKeepsEvidenceWithUnavailableOutcome() async throws {
        let fixture = BundleAdmissionFixture()
        let answer = try await fixture.answer(fixture.useCase(provider: nil))
        XCTAssertEqual(answer.generationOutcome, .unavailable)
        XCTAssertNil(answer.generatedText)
        XCTAssertEqual(answer.evidence, fixture.evidence)
    }

    func testEmptyRequestDoesNotRunCapabilities() async throws {
        let fixture = BundleAdmissionFixture()
        let called = OSAllocatedUnfairLock(initialState: false)
        let useCase = fixture.useCase(provider: BundleAdmissionProvider { _ in
            called.withLock { $0 = true }
            return "Must not run"
        })
        let answer = try await useCase.answerBundle(" \n ", source: .library, graphQuery: fixture.query)
        XCTAssertEqual(answer.generationOutcome, .notRequested)
        XCTAssertEqual(answer.evidence, AskEvidenceBundle(transcriptCitations: [], graphFacts: .notRequested))
        XCTAssertFalse(called.withLock { $0 })
    }

    func testOutputAdmissionPreservesExactEvidenceAndDoesNotTruncate() async throws {
        // One grapheme can exceed the UTF-8 budget without exceeding the
        // character limit, so these are independent admission dimensions.
        let byteOversize = "a" + String(repeating: "\u{0301}", count: 32_000)
        XCTAssertEqual(byteOversize.count, 1)
        let cases: [(String?, AskGenerationOutcome)] = [
            (nil, .unavailable), ("", .failed), (" \n\t", .failed),
            (" El viernes. Friday. ", .generated),
            (String(repeating: "a", count: 8_000), .generated),
            (String(repeating: "a", count: 8_001), .failed),
            (byteOversize, .failed),
            ("a" + String(repeating: "\u{0301}", count: 31_999) + "b", .generated),
        ]
        for (text, outcome) in cases {
            let fixture = BundleAdmissionFixture()
            let useCase = fixture.useCase(provider: BundleAdmissionProvider { input in
                XCTAssertEqual(input.transcriptCitations, fixture.evidence.transcriptCitations)
                XCTAssertTrue(input.isFactAwareGenerationReady)
                return text
            })
            let answer = try await fixture.answer(useCase)
            XCTAssertEqual(answer.generationOutcome, outcome)
            XCTAssertEqual(answer.generatedText, outcome == .generated ? text : nil)
            XCTAssertEqual(answer.evidence, fixture.evidence)
        }
    }

    func testLateValueAndErrorTimeOutEvenWhenTimerCannotWake() async throws {
        for shouldThrow in [false, true] {
            let fixture = BundleAdmissionFixture()
            let clock = AskManualClock()
            var useCase = fixture.useCase(provider: BundleAdmissionProvider { _ in
                clock.advance(by: .seconds(8))
                if shouldThrow { throw BundleAdmissionError.provider }
                return "Late result"
            })
            useCase.answerClock = clock.clock
            let answer = try await fixture.answer(useCase)
            XCTAssertEqual(answer.generationOutcome, .timedOut)
            XCTAssertNil(answer.generatedText)
            XCTAssertEqual(answer.evidence, fixture.evidence)
        }
    }

    func testConfiguredTimeoutUsesOneFixedInstant() async throws {
        let fixture = BundleAdmissionFixture()
        let clock = AskManualClock()
        var useCase = fixture.useCase(provider: BundleAdmissionProvider { _ in
            clock.advance(by: .seconds(2))
            return "Expired at the configured boundary"
        }, timeout: .seconds(2))
        useCase.answerClock = clock.clock
        let answer = try await fixture.answer(useCase)
        XCTAssertEqual(answer.generationOutcome, .timedOut)
        XCTAssertEqual(answer.evidence, fixture.evidence)
    }

    func testTimerCancellationDrainsProviderBeforeReturningEvidence() async throws {
        for shouldThrow in [false, true] {
            let fixture = BundleAdmissionFixture()
            let clock = AskManualClock()
            let started = AsyncStream<Void>.makeStream()
            defer { started.continuation.finish() }
            let drained = OSAllocatedUnfairLock(initialState: false)
            var useCase = fixture.useCase(provider: BundleAdmissionProvider { _ in
                started.continuation.yield(())
                do { try await AskManualClock.parkUntilCancelled() } catch {}
                drained.withLock { $0 = true }
                if shouldThrow { throw BundleAdmissionError.provider }
                return "Cancellation-ignoring late answer"
            })
            useCase.answerClock = AskAnswerClock(now: clock.clock.now, sleepUntil: { _ in
                for await _ in started.stream { break }
                clock.advance(by: .seconds(8))
            })
            let answer = try await fixture.answer(useCase)
            XCTAssertTrue(drained.withLock { $0 })
            XCTAssertEqual(answer.generationOutcome, .timedOut)
            XCTAssertNil(answer.generatedText)
            XCTAssertEqual(answer.evidence, fixture.evidence)
        }
    }

    func testCallerCancellationDuringTeardownOverridesValueAndError() async throws {
        for shouldThrow in [false, true] {
            let fixture = BundleAdmissionFixture()
            let clock = AskManualClock()
            let start = AsyncStream<Void>.makeStream()
            let timerStarted = AsyncStream<Void>.makeStream()
            let caller = OSAllocatedUnfairLock<Task<AskEvidenceBundleAnswer, Error>?>(initialState: nil)
            defer {
                caller.withLock { $0 = nil }
                start.continuation.finish()
                timerStarted.continuation.finish()
            }
            var useCase = fixture.useCase(provider: BundleAdmissionProvider { _ in
                for await _ in timerStarted.stream { break }
                if shouldThrow { throw BundleAdmissionError.provider }
                return "On-time result, cancelled during teardown"
            })
            useCase.answerClock = AskAnswerClock(now: clock.clock.now, sleepUntil: { _ in
                timerStarted.continuation.yield(())
                do { try await AskManualClock.parkUntilCancelled() } catch {
                    caller.withLock { $0?.cancel() }
                    throw error
                }
            })
            let configuredUseCase = useCase
            let task = Task {
                for await _ in start.stream { break }
                return try await fixture.answer(configuredUseCase)
            }
            caller.withLock { $0 = task }
            start.continuation.yield(())
            do {
                _ = try await task.value
                XCTFail("caller cancellation must not become evidence-only success")
            } catch is CancellationError {
                // Structured teardown must fence both values and errors.
            }
        }
    }

    func testDeadlineCrossedDuringTeardownRejectsEarlierValue() async throws {
        let fixture = BundleAdmissionFixture()
        let clock = AskManualClock()
        let timerStarted = AsyncStream<Void>.makeStream()
        defer { timerStarted.continuation.finish() }
        var useCase = fixture.useCase(provider: BundleAdmissionProvider { _ in
            for await _ in timerStarted.stream { break }
            return "Earlier value"
        })
        useCase.answerClock = AskAnswerClock(now: clock.clock.now, sleepUntil: { _ in
            timerStarted.continuation.yield(())
            do { try await AskManualClock.parkUntilCancelled() } catch {
                clock.advance(by: .seconds(8))
                throw error
            }
        })
        let answer = try await fixture.answer(useCase)
        XCTAssertEqual(answer.generationOutcome, .timedOut)
        XCTAssertNil(answer.generatedText)
        XCTAssertEqual(answer.evidence, fixture.evidence)
    }
}

private enum BundleAdmissionError: Error { case provider }

private struct BundleAdmissionProvider: AskEvidenceBundleAnswering {
    let operation: @Sendable (AskSynthesisInput) async throws -> String?

    init(_ operation: @escaping @Sendable (AskSynthesisInput) async throws -> String?) {
        self.operation = operation
    }

    func answer(question _: String, evidence: AskSynthesisInput) async throws -> String? {
        try await operation(evidence)
    }
}

private struct BundleAdmissionFixture: Sendable {
    let evidence: AskEvidenceBundle
    let query = AskGraphFactQuery.personCommitments(PersonCommitmentsQuery(personID: PersonID()))

    init() {
        let meetingID = MeetingID()
        let segmentID = UUID()
        let commitmentID = CommitmentID()
        let citation = AskCitation(segmentID: segmentID, meetingID: meetingID,
                                   meetingTitle: "Planning", timestamp: 3,
                                   text: "El rollout queda para el viernes. Friday rollout.")
        let fact = MeetingMemoryGraphFact(
            id: .commitment(commitmentID), kind: .personCommittedTo,
            subject: .person(PersonID()), object: .commitment(commitmentID),
            subjectText: "Mara", objectText: "Ship rollout", status: .active,
            occurredAt: Date(timeIntervalSince1970: 1_000),
            evidence: [MeetingMemoryGraphEvidence(
                meetingID: meetingID, meetingTitle: citation.meetingTitle,
                meetingStartedAt: Date(timeIntervalSince1970: 997), transcriptRevision: 0,
                segmentID: segmentID, startTime: 3, endTime: 5, text: citation.text, language: "es")],
            primaryEvidenceSegmentID: segmentID)
        evidence = AskEvidenceBundle(transcriptCitations: [citation], graphFacts: .result(.facts(
            MeetingMemoryGraphFactPage(facts: [fact], hasMore: true, projectionGeneration: 7,
                                      omittedStaleCount: 2, omittedUnavailableCount: 1))))
    }

    func useCase(provider: (any AskEvidenceBundleAnswering)?, timeout: Duration = .seconds(8)) -> AskMeetings {
        AskMeetings(retrieval: BundleAdmissionRetrieval(evidence: evidence),
                    answering: BundleAdmissionTranscriptProvider(), bundleAnswering: provider,
                    graphFacts: BundleAdmissionGraph(evidence: evidence), answerTimeout: timeout)
    }

    func answer(_ useCase: AskMeetings) async throws -> AskEvidenceBundleAnswer {
        try await useCase.answerBundle("when / cuándo", source: .library, graphQuery: query)
    }
}

private struct BundleAdmissionRetrieval: AskMeetingRetrieving {
    let evidence: AskEvidenceBundle
    func search(query _: String, limit _: Int) -> [AskSearchResult] { [] }
    func retrieve(question _: String, limit _: Int) -> [AskCitation] { evidence.transcriptCitations }
}

private struct BundleAdmissionGraph: AskGraphFactRetrieving {
    let evidence: AskEvidenceBundle
    func retrieve(_ query: AskGraphFactQuery) throws -> MeetingMemoryGraphQueryResult {
        guard case .result(let result) = evidence.graphFacts else { throw BundleAdmissionError.provider }
        return result
    }
}

private struct BundleAdmissionTranscriptProvider: AskMeetingAnswering {
    func answer(question _: String, citations _: [AskCitation]) throws -> String? {
        XCTFail("the opt-in graph route must never fall back to transcript generation")
        throw BundleAdmissionError.provider
    }
}
