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

    func testMismatchedSkillFilterNeverRelabelsCachedRows() {
        let state = SkillActivityPresentationState(
            receiptScope: .waiting,
            receiptSkillID: MeetingPackageExportSkill.id,
            snapshot: snapshot(
                scope: .waiting,
                skillID: RecapDraftSkill.id,
                hasReceipt: true),
            isLoading: false,
            loadFailed: false)

        XCTAssertEqual(state, .loading)
    }

    func testMismatchedUpdatePeriodNeverRelabelsCachedRows() {
        let state = SkillActivityPresentationState(
            receiptScope: .waiting,
            receiptPeriod: .pastDay,
            snapshot: snapshot(
                scope: .waiting,
                period: .pastWeek,
                hasReceipt: true),
            isLoading: false,
            loadFailed: false)

        XCTAssertEqual(state, .loading)
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

    func testHistoryWindowExpandsOnlyWithVerifiedContinuationEvidence() {
        var window = SkillActivityHistoryWindow()

        XCTAssertEqual(
            window.requestedLimit,
            SkillControlCenterSnapshot.defaultReceiptLimit)
        XCTAssertFalse(window.canExpand(hasMoreReceipts: false))
        XCTAssertTrue(window.canExpand(hasMoreReceipts: true))

        window.expand()

        XCTAssertEqual(
            window.requestedLimit,
            SkillControlCenterSnapshot.maximumReceiptLimit)
        XCTAssertTrue(window.isExpanded)
        XCTAssertFalse(window.canExpand(hasMoreReceipts: true))
    }

    func testHistoryWindowResetRestoresTheCheapScopeDefault() {
        var window = SkillActivityHistoryWindow()
        window.expand()

        window.reset()

        XCTAssertEqual(
            window.requestedLimit,
            SkillControlCenterSnapshot.defaultReceiptLimit)
        XCTAssertFalse(window.isExpanded)
    }

    func testChangingTheStatusLensReturnsToTheCheapWindow() {
        var query = SkillActivityQuery()
        query.window.expand()

        query.selection.scope = .waiting

        XCTAssertFalse(query.window.isExpanded)
    }

    func testChangingTheSkillOrPeriodLensReturnsToTheCheapWindow() {
        var bySkill = SkillActivityQuery()
        bySkill.window.expand()
        bySkill.selection.skillID = "meeting-package-export"
        XCTAssertFalse(bySkill.window.isExpanded)

        var byPeriod = SkillActivityQuery()
        byPeriod.window.expand()
        byPeriod.selection.period = .pastWeek
        XCTAssertFalse(byPeriod.window.isExpanded)
    }

    func testRewritingTheSameLensKeepsWhatThePersonExpanded() {
        var query = SkillActivityQuery()
        query.window.expand()

        query.selection.scope = query.selection.scope
        query.selection = SkillActivitySelection()

        XCTAssertTrue(query.window.isExpanded)
    }

    func testAnActivityReadNeverLocksVerifiedControls() {
        XCTAssertFalse(
            skillControlsAreLocked(hasSnapshot: true, isChanging: false, hasUnverifiedChange: false),
            "a reload of history or suggestions must leave verified controls usable")
    }

    func testAChangeOrAnUnreadPolicyLocksTheControls() {
        XCTAssertTrue(skillControlsAreLocked(hasSnapshot: false, isChanging: false, hasUnverifiedChange: false))
        XCTAssertTrue(skillControlsAreLocked(hasSnapshot: true, isChanging: true, hasUnverifiedChange: false))
        XCTAssertTrue(skillControlsAreLocked(hasSnapshot: true, isChanging: false, hasUnverifiedChange: true))
    }

    func testOnlyVerifiedTerminalActivityStatesAllowExplicitRefresh() {
        XCTAssertFalse(SkillActivityPresentationState.loading.allowsExplicitRefresh)
        XCTAssertFalse(SkillActivityPresentationState.unavailable.allowsExplicitRefresh)
        XCTAssertTrue(SkillActivityPresentationState.empty.allowsExplicitRefresh)
        XCTAssertTrue(SkillActivityPresentationState.receipts.allowsExplicitRefresh)
    }

    func testOnlyVerifiedEmptyActivityWithActiveFiltersAllowsFilterReset() {
        XCTAssertFalse(
            SkillActivityPresentationState.loading.allowsFilterReset(
                hasActiveFilters: true))
        XCTAssertFalse(
            SkillActivityPresentationState.unavailable.allowsFilterReset(
                hasActiveFilters: true))
        XCTAssertFalse(
            SkillActivityPresentationState.receipts.allowsFilterReset(
                hasActiveFilters: true))
        XCTAssertFalse(
            SkillActivityPresentationState.empty.allowsFilterReset(
                hasActiveFilters: false))
        XCTAssertTrue(
            SkillActivityPresentationState.empty.allowsFilterReset(
                hasActiveFilters: true))
    }

    private func snapshot(
        scope: SkillExecutionReviewScope,
        skillID: String? = nil,
        period: SkillExecutionReviewPeriod = .anytime,
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
            receiptSkillID: skillID,
            receiptPeriod: period,
            receiptLoadState: receiptLoadState)
    }
}
