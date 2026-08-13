import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import ApplicationKit
@testable import portavoz_app

final class SkillActivityPresentationStateTests: XCTestCase {
    func testLoadingHidesRowsEvenWhenTheSnapshotAlreadyMatches() {
        let state = SkillActivityPresentationState(
            receiptScope: .recent,
            snapshot: snapshot(scope: .recent, hasReceipt: true),
            isLoading: true,
            loadFailed: false)

        XCTAssertEqual(state, .loading)
    }

    func testMismatchedSnapshotLoadsWithoutRelabelingItsRows() {
        let state = SkillActivityPresentationState(
            receiptScope: .waiting,
            snapshot: snapshot(scope: .recent, hasReceipt: true),
            isLoading: false,
            loadFailed: false)

        XCTAssertEqual(state, .loading)
    }

    func testMismatchedSnapshotFailureShowsUnavailable() {
        let state = SkillActivityPresentationState(
            receiptScope: .waiting,
            snapshot: snapshot(scope: .recent, hasReceipt: true),
            isLoading: false,
            loadFailed: true)

        XCTAssertEqual(state, .unavailable)
    }

    func testReceiptOnlyFailureShowsUnavailableForTheMatchingScope() {
        let state = SkillActivityPresentationState(
            receiptScope: .completed,
            snapshot: snapshot(
                scope: .completed,
                receiptLoadState: .unavailable),
            isLoading: false,
            loadFailed: false)

        XCTAssertEqual(state, .unavailable)
    }

    func testVerifiedEmptyScopeShowsItsEmptyState() {
        let state = SkillActivityPresentationState(
            receiptScope: .needsAttention,
            snapshot: snapshot(scope: .needsAttention),
            isLoading: false,
            loadFailed: false)

        XCTAssertEqual(state, .empty)
    }

    func testVerifiedNonemptyScopeShowsReceiptRows() {
        let state = SkillActivityPresentationState(
            receiptScope: .completed,
            snapshot: snapshot(scope: .completed, hasReceipt: true),
            isLoading: false,
            loadFailed: false)

        XCTAssertEqual(state, .receipts)
    }

    private func snapshot(
        scope: SkillExecutionReviewScope,
        hasReceipt: Bool = false,
        receiptLoadState: SkillControlCenterReceiptLoadState = .verified
    ) -> SkillControlCenterSnapshot {
        let receipts: [SkillControlCenterReceipt]
        if hasReceipt {
            receipts = [SkillControlCenterReceipt(record: SkillExecutionRecord(
                proposalID: UUID(),
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                idempotencyKey: "presentation-state",
                state: .succeeded,
                failureCategory: nil,
                attempt: 1,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))]
        } else {
            receipts = []
        }
        return SkillControlCenterSnapshot(
            isPaused: false,
            skills: [],
            receiptScope: scope,
            receipts: receipts,
            receiptLoadState: receiptLoadState)
    }
}
