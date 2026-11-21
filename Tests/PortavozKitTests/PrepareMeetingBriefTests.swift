import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class PrepareMeetingBriefTests: XCTestCase {
    func testBuildsRelatedMeetingsOpenCommitmentsAndGroundedKnowledge() async throws {
        let relatedID = MeetingID()
        let unrelatedID = MeetingID()
        let citations = [
            citation(relatedID, title: "Budget", text: "Ana approved the budget rollout"),
            citation(unrelatedID, title: "Health", text: "blood test results"),
        ]
        let items = (0..<9).map { index in
            MeetingBrief.OpenItem(
                id: UUID(),
                meetingID: relatedID,
                meetingTitle: "Budget",
                text: "Commitment \(index)")
        } + [MeetingBrief.OpenItem(
            id: UUID(),
            meetingID: unrelatedID,
            meetingTitle: "Health",
            text: "Unrelated")]
        let useCase = makeUseCase(
            citations: citations,
            summaries: [relatedID: "# Summary\nShip the rollout Friday."],
            items: items,
            synthesis: [
                MeetingBrief.SynthesisPoint(text: "Ship the rollout Friday.", sourceIndex: 0),
                MeetingBrief.SynthesisPoint(text: "Invalid", sourceIndex: 7),
            ])

        let brief = try await useCase(event)

        XCTAssertEqual(brief.related.count, 1)
        XCTAssertEqual(brief.related[0].meetingID, relatedID)
        XCTAssertEqual(brief.related[0].overview, "Ship the rollout Friday.")
        XCTAssertEqual(brief.related[0].matchedTerms, ["Budget", "rollout", "Ana"])
        XCTAssertEqual(brief.openItems.count, 8)
        XCTAssertTrue(brief.openItems.allSatisfy { $0.meetingID == relatedID })
        XCTAssertEqual(brief.whatToKnow.count, 1)
        XCTAssertEqual(brief.whatToKnow[0].meetingID, relatedID)
    }

    func testWeakEvidenceAndMissingSummaryProduceAnEmptyBrief() async throws {
        let weakID = MeetingID()
        let strongWithoutSummary = MeetingID()
        let citations = [
            citation(weakID, title: "Health", text: "blood test results"),
            citation(strongWithoutSummary, title: "Budget", text: "budget rollout with Ana"),
        ]
        let brief = try await makeUseCase(
            citations: citations,
            summaries: [:],
            items: [],
            synthesis: [])(event)

        XCTAssertTrue(brief.related.isEmpty)
        XCTAssertTrue(brief.openItems.isEmpty)
        XCTAssertTrue(brief.whatToKnow.isEmpty)
    }

    func testIndependentFailuresDegradeWithoutDiscardingTheEvent() async throws {
        let useCase = PrepareMeetingBrief(
            ask: AskMeetings(
                retrieval: BriefRetrievalFake(scenario: .failure),
                answering: BriefAnsweringFake()),
            library: BriefLibraryFake(summaries: [:], items: [], failItems: true),
            synthesizer: BriefSynthesizerFake(points: [], shouldFail: true),
            sources: BriefSourceRecorderFake(occurrence: nil))

        let brief = try await useCase(event)

        XCTAssertEqual(brief.event, event)
        XCTAssertTrue(brief.related.isEmpty)
        XCTAssertTrue(brief.openItems.isEmpty)
        XCTAssertTrue(brief.whatToKnow.isEmpty)
    }

    func testRetrievalCancellationRemainsCancellation() async {
        let useCase = PrepareMeetingBrief(
            ask: AskMeetings(
                retrieval: BriefRetrievalFake(scenario: .cancelled),
                answering: BriefAnsweringFake()),
            library: BriefLibraryFake(summaries: [:], items: []),
            synthesizer: BriefSynthesizerFake(points: []),
            sources: BriefSourceRecorderFake(occurrence: nil))
        do {
            _ = try await useCase(event)
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRecordsTheSameTitleOccurrenceOverTheBestRelatedMeeting() async throws {
        let relatedID = MeetingID()
        let occurrenceID = MeetingID()
        let recorder = BriefSourceRecorderFake(occurrence: occurrenceID)
        let plain = makeUseCase(
            citations: [citation(relatedID, title: "Budget", text: "Ana approved the budget rollout")],
            summaries: [relatedID: "Overview."], items: [], synthesis: [])
        let recording = makeUseCase(
            citations: [citation(relatedID, title: "Budget", text: "Ana approved the budget rollout")],
            summaries: [relatedID: "Overview."], items: [], synthesis: [], sources: recorder)

        let expected = try await plain(event)
        let brief = try await recording(event)

        XCTAssertEqual(brief, expected)
        let lookups = await recorder.lookups
        let recorded = await recorder.recorded
        XCTAssertEqual(lookups, [BriefSourceRecorderFake.Lookup(title: event.title, before: event.startDate)])
        XCTAssertEqual(recorded, [BriefSourceRecorderFake.Record(
            eventID: event.id, eventStartAt: event.startDate, sourceMeetingID: occurrenceID)])
    }

    func testFallsBackToTheBestRelatedMeetingAndClearsWithoutOne() async throws {
        let relatedID = MeetingID()
        let withoutSummary = MeetingID()
        let recorder = BriefSourceRecorderFake(occurrence: nil)
        _ = try await makeUseCase(
            citations: [
                citation(withoutSummary, title: "Budget", text: "budget rollout with Ana"),
                citation(relatedID, title: "Budget", text: "Ana approved the budget rollout"),
            ],
            summaries: [relatedID: "Overview."], items: [], synthesis: [], sources: recorder)(event)
        _ = try await makeUseCase(
            citations: [], summaries: [:], items: [], synthesis: [], sources: recorder)(event)

        let recorded = await recorder.recorded
        XCTAssertEqual(recorded.map(\.sourceMeetingID), [relatedID, nil])
    }

    func testAFailingSourceRecorderDoesNotFailTheBrief() async throws {
        let relatedID = MeetingID()
        let recorder = BriefSourceRecorderFake(occurrence: nil, failure: BriefFakeError.expected)
        let brief = try await makeUseCase(
            citations: [citation(relatedID, title: "Budget", text: "Ana approved the budget rollout")],
            summaries: [relatedID: "Overview."], items: [], synthesis: [], sources: recorder)(event)

        XCTAssertEqual(brief.related.map(\.meetingID), [relatedID])
    }

    func testADegradedInputKeepsTheRecordedSource() async throws {
        let failedRetrieval = BriefSourceRecorderFake(occurrence: nil)
        _ = try await PrepareMeetingBrief(
            ask: AskMeetings(
                retrieval: BriefRetrievalFake(scenario: .failure),
                answering: BriefAnsweringFake()),
            library: BriefLibraryFake(summaries: [:], items: []),
            synthesizer: BriefSynthesizerFake(points: []),
            sources: failedRetrieval)(event)
        let failedLookup = BriefSourceRecorderFake(occurrence: nil, failure: BriefFakeError.expected)
        let relatedID = MeetingID()
        _ = try await makeUseCase(
            citations: [citation(relatedID, title: "Budget", text: "Ana approved the budget rollout")],
            summaries: [relatedID: "Overview."], items: [], synthesis: [], sources: failedLookup)(event)

        let afterRetrieval = await failedRetrieval.recorded
        let afterLookup = await failedLookup.recorded
        XCTAssertTrue(afterRetrieval.isEmpty)
        XCTAssertTrue(afterLookup.isEmpty)
    }

    func testSourceRecorderCancellationRemainsCancellation() async {
        for cancelsLookup in [true, false] {
            let recorder = BriefSourceRecorderFake(
                occurrence: nil, failure: CancellationError(),
                failsLookupOnly: cancelsLookup, failsRecordOnly: !cancelsLookup)
            do {
                _ = try await makeUseCase(
                    citations: [], summaries: [:], items: [], synthesis: [], sources: recorder)(event)
                XCTFail("cancellation must propagate")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    private var event: UpcomingEvent {
        UpcomingEvent(
            id: "event-budget-rollout",
            title: "Budget rollout",
            startDate: Date(timeIntervalSince1970: 1_789_000_000),
            attendees: ["Ana"])
    }

    private func citation(
        _ meetingID: MeetingID,
        title: String,
        text: String
    ) -> AskCitation {
        AskCitation(
            meetingID: meetingID,
            meetingTitle: title,
            timestamp: 0,
            text: text)
    }

    private func makeUseCase(
        citations: [AskCitation],
        summaries: [MeetingID: String],
        items: [MeetingBrief.OpenItem],
        synthesis: [MeetingBrief.SynthesisPoint],
        sources: any MeetingBriefSourceRecording = BriefSourceRecorderFake(occurrence: nil)
    ) -> PrepareMeetingBrief {
        PrepareMeetingBrief(
            ask: AskMeetings(
                retrieval: BriefRetrievalFake(scenario: .citations(citations)),
                answering: BriefAnsweringFake()),
            library: BriefLibraryFake(summaries: summaries, items: items),
            synthesizer: BriefSynthesizerFake(points: synthesis),
            sources: sources)
    }
}

private actor BriefSourceRecorderFake: MeetingBriefSourceRecording {
    struct Lookup: Equatable {
        let title: String
        let before: Date
    }

    struct Record: Equatable {
        let eventID: String
        let eventStartAt: Date
        let sourceMeetingID: MeetingID?
    }

    private let occurrence: MeetingID?
    private let failure: (any Error)?
    private let failsLookupOnly: Bool
    private let failsRecordOnly: Bool
    private(set) var lookups: [Lookup] = []
    private(set) var recorded: [Record] = []

    init(
        occurrence: MeetingID?, failure: (any Error)? = nil,
        failsLookupOnly: Bool = false, failsRecordOnly: Bool = false
    ) {
        self.occurrence = occurrence
        self.failure = failure
        self.failsLookupOnly = failsLookupOnly
        self.failsRecordOnly = failsRecordOnly
    }

    func previousMeetingBriefOccurrence(title: String, before date: Date) async throws -> MeetingID? {
        lookups.append(Lookup(title: title, before: date))
        if let failure, !failsRecordOnly { throw failure }
        return occurrence
    }

    func recordMeetingBriefSource(
        eventID: String, eventStartAt: Date, sourceMeetingID: MeetingID?
    ) async throws {
        recorded.append(Record(
            eventID: eventID, eventStartAt: eventStartAt, sourceMeetingID: sourceMeetingID))
        if let failure, !failsLookupOnly { throw failure }
    }
}

private struct BriefRetrievalFake: AskMeetingRetrieving {
    enum Scenario: Sendable {
        case citations([AskCitation])
        case failure
        case cancelled
    }

    let scenario: Scenario

    func search(query: String, limit: Int) async throws -> [AskSearchResult] {
        []
    }

    func retrieve(question: String, limit: Int) async throws -> [AskCitation] {
        switch scenario {
        case .citations(let citations): return Array(citations.prefix(limit))
        case .failure: throw BriefFakeError.expected
        case .cancelled: throw CancellationError()
        }
    }
}

private struct BriefAnsweringFake: AskMeetingAnswering {
    func answer(question: String, citations: [AskCitation]) async throws -> String? {
        nil
    }
}

private struct BriefLibraryFake: MeetingBriefLibraryReading {
    let summaries: [MeetingID: String]
    let items: [MeetingBrief.OpenItem]
    var failItems = false

    func meetingBriefSummaryMarkdowns(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: String] {
        summaries.filter { meetingIDs.contains($0.key) }
    }

    func openMeetingBriefItems(limit: Int) async throws -> [MeetingBrief.OpenItem] {
        if failItems { throw BriefFakeError.expected }
        return Array(items.prefix(limit))
    }
}

private struct BriefSynthesizerFake: MeetingBriefSynthesizing {
    let points: [MeetingBrief.SynthesisPoint]
    var shouldFail = false

    func synthesizeMeetingBrief(
        eventTitle: String,
        sources: [MeetingBrief.SynthesisSource]
    ) async throws -> [MeetingBrief.SynthesisPoint] {
        if shouldFail { throw BriefFakeError.expected }
        return points
    }
}

private enum BriefFakeError: Error {
    case expected
}
