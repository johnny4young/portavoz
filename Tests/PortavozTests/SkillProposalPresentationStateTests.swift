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
}
