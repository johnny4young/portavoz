import XCTest

@testable import portavoz_app

final class SkillProposalPresentationStateTests: XCTestCase {
    func testOnlyVerifiedProposalSnapshotsAllowExplicitRefresh() {
        XCTAssertEqual(
            SkillProposalPresentationState(
                hasVerifiedSnapshot: false,
                hasOffers: false,
                loadFailed: false),
            .loading)
        XCTAssertEqual(
            SkillProposalPresentationState(
                hasVerifiedSnapshot: true,
                hasOffers: true,
                loadFailed: true),
            .unavailable)

        let empty = SkillProposalPresentationState(
            hasVerifiedSnapshot: true,
            hasOffers: false,
            loadFailed: false)
        let offers = SkillProposalPresentationState(
            hasVerifiedSnapshot: true,
            hasOffers: true,
            loadFailed: false)

        XCTAssertEqual(empty, .empty)
        XCTAssertEqual(offers, .offers)
        XCTAssertTrue(empty.allowsExplicitRefresh)
        XCTAssertTrue(offers.allowsExplicitRefresh)
        XCTAssertFalse(
            SkillProposalPresentationState.loading.allowsExplicitRefresh)
        XCTAssertFalse(
            SkillProposalPresentationState.unavailable.allowsExplicitRefresh)
    }

    func testAccessibilityPositionIsBoundedAndOneBased() throws {
        XCTAssertNil(SkillProposalAccessibilityPosition(offset: -1, total: 2))
        XCTAssertNil(SkillProposalAccessibilityPosition(offset: 0, total: 0))
        XCTAssertNil(SkillProposalAccessibilityPosition(offset: 2, total: 2))

        let first = try XCTUnwrap(
            SkillProposalAccessibilityPosition(offset: 0, total: 2))
        let second = try XCTUnwrap(
            SkillProposalAccessibilityPosition(offset: 1, total: 2))

        XCTAssertEqual(first.ordinal, 1)
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(second.ordinal, 2)
        XCTAssertEqual(second.total, 2)
        XCTAssertNotEqual(first, second)
    }
}
