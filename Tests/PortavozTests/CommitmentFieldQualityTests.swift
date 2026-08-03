import CryptoKit
import Foundation
import PortavozCore
import XCTest

final class CommitmentFieldQualityTests: XCTestCase {
    func testCanonicalNinetyDayFixtureProducesExpectedScorecard() throws {
        let fixture = try Self.loadFixture()

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.generation, "public-synthetic-v1")
        XCTAssertEqual(fixture.kind, "commitment-field-quality")
        XCTAssertEqual(fixture.contentSource, "synthetic-only")
        XCTAssertEqual(fixture.observations.count, 12)

        let digest = SHA256.hash(data: try Data(contentsOf: Self.fixtureURL))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            digest,
            "081d97c5c96d13ba58a8afeff61b629c7a732c0610ea6d7a36e673f1d71db632")

        let scorecard = try CommitmentFieldQualityEvaluator.evaluate(
            fixture.observations,
            endingAt: fixture.windowEndedAt)
        XCTAssertEqual(
            scorecard.windowEndedAt.timeIntervalSince(scorecard.windowStartedAt),
            CommitmentFieldQualityEvaluator.windowDuration,
            accuracy: 0.001)
        XCTAssertEqual(
            fixture.observations.map(\.firstPresentedAt).min(),
            scorecard.windowStartedAt)

        let metrics = scorecard.overall
        XCTAssertEqual(metrics.observationCount, 12)
        XCTAssertEqual(metrics.pendingCount, 2)
        XCTAssertEqual(metrics.deferredCount, 1)
        XCTAssertEqual(metrics.dismissedCount, 3)
        XCTAssertEqual(metrics.confirmedCount, 6)
        XCTAssertEqual(metrics.terminalReviewCount, 9)
        XCTAssertEqual(metrics.reviewFalsePositiveRate, 3.0 / 9.0)
        XCTAssertEqual(metrics.ownerClaimCount, 7)
        XCTAssertEqual(metrics.exactOwnerClaimCount, 4)
        XCTAssertEqual(metrics.ownerPrecision, 4.0 / 7.0)
        XCTAssertEqual(metrics.dueDateClaimCount, 5)
        XCTAssertEqual(metrics.exactDueDateClaimCount, 2)
        XCTAssertEqual(metrics.dueDatePrecision, 2.0 / 5.0)
        XCTAssertEqual(metrics.evidenceCoveredConfirmationCount, 5)
        XCTAssertEqual(metrics.evidenceCoverage, 5.0 / 6.0)
        XCTAssertEqual(metrics.confirmationLatencyCount, 6)
        XCTAssertEqual(metrics.confirmationLatencyP50, 6 * 60 * 60)
        XCTAssertEqual(metrics.confirmationLatencyP95, 72 * 60 * 60)
    }

    func testLanguageBreakdownsDoNotCountPendingOrDeferredClaimsAsReviewed() throws {
        let fixture = try Self.loadFixture()
        let scorecard = try CommitmentFieldQualityEvaluator.evaluate(
            fixture.observations,
            endingAt: fixture.windowEndedAt)
        let byLanguage = Dictionary(
            uniqueKeysWithValues: scorecard.byLanguage.map { ($0.language, $0.metrics) })

        let english = try XCTUnwrap(byLanguage[.english])
        XCTAssertEqual(english.terminalReviewCount, 3)
        XCTAssertEqual(english.ownerClaimCount, 3)
        XCTAssertEqual(english.ownerPrecision, 1.0 / 3.0)
        XCTAssertEqual(english.evidenceCoverage, 1)

        let spanish = try XCTUnwrap(byLanguage[.spanish])
        XCTAssertEqual(spanish.deferredCount, 1)
        XCTAssertEqual(spanish.ownerClaimCount, 1)
        XCTAssertEqual(spanish.ownerPrecision, 1)
        XCTAssertEqual(spanish.dueDatePrecision, 0)

        let mixed = try XCTUnwrap(byLanguage[.mixed])
        XCTAssertEqual(mixed.pendingCount, 1)
        XCTAssertEqual(mixed.ownerClaimCount, 3)
        XCTAssertEqual(mixed.ownerPrecision, 2.0 / 3.0)
        XCTAssertEqual(mixed.evidenceCoverage, 0.5)
    }

    func testEmptyCohortKeepsUndefinedRatesExplicit() throws {
        let endingAt = Date(timeIntervalSince1970: 1_800_000_000)
        let scorecard = try CommitmentFieldQualityEvaluator.evaluate([], endingAt: endingAt)

        XCTAssertEqual(scorecard.overall.observationCount, 0)
        XCTAssertNil(scorecard.overall.reviewFalsePositiveRate)
        XCTAssertNil(scorecard.overall.ownerPrecision)
        XCTAssertNil(scorecard.overall.dueDatePrecision)
        XCTAssertNil(scorecard.overall.evidenceCoverage)
        XCTAssertNil(scorecard.overall.confirmationLatencyP50)
        XCTAssertNil(scorecard.overall.confirmationLatencyP95)
        XCTAssertEqual(scorecard.byLanguage.count, 3)
    }

    func testEvaluatorRejectsDuplicateOutOfWindowAndInconsistentObservations() throws {
        let fixture = try Self.loadFixture()
        let first = try XCTUnwrap(fixture.observations.first)

        XCTAssertThrowsError(try CommitmentFieldQualityEvaluator.evaluate(
            [first, first],
            endingAt: fixture.windowEndedAt)) { error in
                XCTAssertEqual(
                    error as? CommitmentFieldQualityError,
                    .duplicateObservation(first.id))
        }

        let outside = CommitmentFieldQualityObservation(
            language: .english,
            firstPresentedAt: fixture.windowEndedAt.addingTimeInterval(
                -CommitmentFieldQualityEvaluator.windowDuration - 1),
            outcome: .pending)
        XCTAssertThrowsError(try CommitmentFieldQualityEvaluator.evaluate(
            [outside],
            endingAt: fixture.windowEndedAt)) { error in
                XCTAssertEqual(
                    error as? CommitmentFieldQualityError,
                    .observationOutsideWindow(outside.id))
        }

        let inconsistent = CommitmentFieldQualityObservation(
            language: .spanish,
            firstPresentedAt: fixture.windowEndedAt.addingTimeInterval(-60),
            outcome: .pending,
            reviewedAt: fixture.windowEndedAt)
        XCTAssertThrowsError(try CommitmentFieldQualityEvaluator.evaluate(
            [inconsistent],
            endingAt: fixture.windowEndedAt)) { error in
                XCTAssertEqual(
                    error as? CommitmentFieldQualityError,
                    .invalidObservation(inconsistent.id))
        }
    }

    func testEvaluatorRejectsAWorksetBeyondThePublishedBound() throws {
        let fixture = try Self.loadFixture()
        let first = try XCTUnwrap(fixture.observations.first)
        let oversized = Array(
            repeating: first,
            count: CommitmentFieldQualityEvaluator.maximumObservationCount + 1)

        XCTAssertThrowsError(try CommitmentFieldQualityEvaluator.evaluate(
            oversized,
            endingAt: fixture.windowEndedAt)) { error in
                XCTAssertEqual(
                    error as? CommitmentFieldQualityError,
                    .tooManyObservations)
        }
    }
}

private extension CommitmentFieldQualityTests {
    struct Fixture: Decodable {
        let schemaVersion: Int
        let generation: String
        let kind: String
        let contentSource: String
        let windowEndedAt: Date
        let observations: [CommitmentFieldQualityObservation]
    }

    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Fixtures/CommitmentFieldQuality/public-synthetic-v1.json")

    static func loadFixture() throws -> Fixture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    }
}
