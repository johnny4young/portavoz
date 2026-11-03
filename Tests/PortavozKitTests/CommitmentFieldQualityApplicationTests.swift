import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class CommitmentFieldQualityApplicationTests: XCTestCase {
    func testLoadSamplesOneWindowAndReturnsOnlyTheAggregateScorecard() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = CommitmentFieldQualityObservation(
            language: .spanish,
            firstPresentedAt: now.addingTimeInterval(-120),
            outcome: .dismissed,
            reviewedAt: now.addingTimeInterval(-60),
            suggestedOwnerToken: UUID())
        let repository = CommitmentFieldQualityRepositoryFake(
            observations: [observation])

        let scorecard = try await LoadCommitmentFieldQuality(
            repository: repository,
            now: { now }).execute(())

        let requestedWindowEnds = await repository.requestedWindowEnds()
        XCTAssertEqual(requestedWindowEnds, [now])
        XCTAssertEqual(scorecard.windowEndedAt, now)
        XCTAssertEqual(scorecard.overall.observationCount, 1)
        XCTAssertEqual(scorecard.overall.dismissedCount, 1)
        XCTAssertEqual(scorecard.overall.reviewFalsePositiveRate, 1)
        XCTAssertEqual(scorecard.byLanguage.first {
            $0.language == .spanish
        }?.metrics.observationCount, 1)
    }

    func testRecordOwnsStableIdentityAndPresentationTime() async throws {
        let meetingID = MeetingID()
        let actionItemID = UUID()
        let observationID = UUID()
        let presentedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = CommitmentFieldQualityRepositoryFake()

        let result = try await RecordCommitmentFieldPresentation(
            repository: repository,
            now: { presentedAt },
            makeObservationID: { observationID })
            .execute(RecordCommitmentFieldPresentationRequest(
                meetingID: meetingID,
                actionItemID: actionItemID))

        XCTAssertEqual(result, observationID)
        let recordedPresentations = await repository.recordedPresentations()
        XCTAssertEqual(recordedPresentations, [
            .init(
                meetingID: meetingID,
                actionItemID: actionItemID,
                observationID: observationID,
                presentedAt: presentedAt),
        ])
    }
}

private actor CommitmentFieldQualityRepositoryFake:
    CommitmentFieldQualityReading,
    CommitmentFieldPresentationRecording {
    struct Presentation: Equatable {
        let meetingID: MeetingID
        let actionItemID: UUID
        let observationID: UUID
        let presentedAt: Date
    }

    private let observations: [CommitmentFieldQualityObservation]
    private var windowEnds: [Date] = []
    private var presentations: [Presentation] = []

    init(observations: [CommitmentFieldQualityObservation] = []) {
        self.observations = observations
    }

    func commitmentFieldQualityObservations(
        endingAt windowEnd: Date
    ) async throws -> [CommitmentFieldQualityObservation] {
        windowEnds.append(windowEnd)
        return observations
    }

    func recordCommitmentFieldPresentation(
        actionItemID: UUID,
        meetingID: MeetingID,
        observationID: UUID,
        at presentedAt: Date
    ) async throws -> UUID {
        presentations.append(Presentation(
            meetingID: meetingID,
            actionItemID: actionItemID,
            observationID: observationID,
            presentedAt: presentedAt))
        return observationID
    }

    func requestedWindowEnds() -> [Date] { windowEnds }

    func recordedPresentations() -> [Presentation] { presentations }
}
