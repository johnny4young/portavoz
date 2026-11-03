import Foundation
import XCTest

@testable import portavoz_app

final class SkillActionAttemptTests: XCTestCase {
    func testAnUnverifiedControlChangeLocksUntilAVerifiedReadClearsIt() {
        var change = SkillActionAttempt<SkillControlsSubject>()

        change.begin(.controls)
        XCTAssertTrue(change.isInFlight)
        change.fail(.controls)
        change.finish(.controls)

        XCTAssertTrue(change.hasFailed)
        XCTAssertFalse(change.isInFlight)
        XCTAssertTrue(skillControlsAreLocked(
            hasSnapshot: true, isChanging: change.isInFlight, hasUnverifiedChange: change.hasFailed))

        change.clearFailure()

        XCTAssertFalse(skillControlsAreLocked(
            hasSnapshot: true, isChanging: change.isInFlight, hasUnverifiedChange: change.hasFailed))
    }

    func testAFailedReviewKeepsItsOfferAndARetryStartsClean() {
        let offer = UUID()
        var review = SkillActionAttempt<UUID>()

        review.begin(offer)
        review.fail(offer)
        review.finish(offer)

        XCTAssertEqual(review.failed, offer)
        review.keepFailure { $0 == offer }
        XCTAssertEqual(review.failed, offer, "the offer still exists, so its failure and retry stay")

        review.begin(offer)

        XCTAssertNil(review.failed)
        XCTAssertTrue(review.isInFlight(offer))
    }

    func testAFailedDismissalClearsOnlyWhenItsOfferIsGone() {
        let offer = UUID()
        var dismissal = SkillActionAttempt<UUID>()
        dismissal.begin(offer)
        dismissal.fail(offer)

        dismissal.keepFailure { _ in false }

        XCTAssertNil(dismissal.failed)
    }

    func testAFailedRevocationReportsWithoutFinishingTheAction() {
        let receipt = UUID()
        var revocation = SkillActionAttempt<UUID>()

        revocation.begin(receipt)
        revocation.fail(receipt)
        revocation.finish(receipt)

        XCTAssertTrue(revocation.hasFailed)
        XCTAssertFalse(revocation.isInFlight)
    }

    func testAFailedRecoveryRetryThatSucceedsLeavesNoFailureBehind() {
        let receipt = UUID()
        var recovery = SkillActionAttempt<UUID>()
        recovery.begin(receipt)
        recovery.fail(receipt)

        recovery.begin(receipt)
        recovery.finish(receipt)

        XCTAssertFalse(recovery.hasFailed)
        XCTAssertFalse(recovery.isInFlight)
    }

    func testASupersededContextAttemptCannotReportAFailure() {
        let current = UUID()
        let superseded = UUID()
        var context = SkillActionAttempt<UUID>()
        context.begin(current)

        context.fail(superseded)
        context.finish(superseded)

        XCTAssertNil(context.failed)
        XCTAssertTrue(context.isInFlight(current))
    }
}
