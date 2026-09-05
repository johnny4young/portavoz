import Foundation
import XCTest
@testable import portavoz_app

@MainActor
final class SettingsSkillReceiptFocusStateTests: XCTestCase {
    func testEligibleDismissalPublishesTheExactReceiptAfterTheModalScopeLeaves() async throws {
        let sleep = ControlledTestSleep()
        let state = SettingsSkillReceiptFocusState(
            sleep: { try await sleep.wait(for: $0) })
        let receiptID = UUID()

        state.beginInspection(of: receiptID)
        state.restoreAfterDismissal { true }

        XCTAssertNil(state.requestID)
        let sleepStarted = await sleep.waitUntilCallCount(1)
        let duration = await sleep.requestedDuration(at: 0)
        let sleepResumed = await sleep.resumeCall(at: 0)
        let focusArrived = await eventually { state.requestID == receiptID }
        XCTAssertTrue(sleepStarted)
        XCTAssertEqual(duration, .milliseconds(200))
        XCTAssertTrue(sleepResumed)
        XCTAssertTrue(focusArrived)
    }

    func testClearCancelsAPendingRestoration() async throws {
        let sleep = ControlledTestSleep()
        let state = SettingsSkillReceiptFocusState(
            sleep: { try await sleep.wait(for: $0) })

        state.beginInspection(of: UUID())
        state.restoreAfterDismissal { true }
        let sleepStarted = await sleep.waitUntilCallCount(1)
        XCTAssertTrue(sleepStarted)
        state.clear()

        let sleepCancelled = await sleep.waitUntilCancellationCount(1)
        XCTAssertTrue(sleepCancelled)
        XCTAssertNil(state.requestID)
    }

    func testNewInspectionSupersedesTheOlderRestoration() async throws {
        let sleep = ControlledTestSleep()
        let state = SettingsSkillReceiptFocusState(
            sleep: { try await sleep.wait(for: $0) })
        let currentReceiptID = UUID()

        state.beginInspection(of: UUID())
        state.restoreAfterDismissal { true }
        let firstSleepStarted = await sleep.waitUntilCallCount(1)
        XCTAssertTrue(firstSleepStarted)
        state.beginInspection(of: currentReceiptID)
        state.restoreAfterDismissal { true }

        let firstSleepCancelled = await sleep.waitUntilCancellationCount(1)
        let secondSleepStarted = await sleep.waitUntilCallCount(2)
        let secondSleepResumed = await sleep.resumeCall(at: 1)
        let currentFocusArrived = await eventually {
            state.requestID == currentReceiptID
        }
        XCTAssertTrue(firstSleepCancelled)
        XCTAssertTrue(secondSleepStarted)
        XCTAssertTrue(secondSleepResumed)
        XCTAssertTrue(currentFocusArrived)
    }

    func testIneligibleDismissalNeverPublishesFocus() async throws {
        let sleep = ControlledTestSleep()
        let state = SettingsSkillReceiptFocusState(
            sleep: { try await sleep.wait(for: $0) })
        var eligibilityWasChecked = false

        state.beginInspection(of: UUID())
        state.restoreAfterDismissal {
            eligibilityWasChecked = true
            return false
        }

        let sleepStarted = await sleep.waitUntilCallCount(1)
        let sleepResumed = await sleep.resumeCall(at: 0)
        let eligibilityCheckArrived = await eventually { eligibilityWasChecked }
        XCTAssertTrue(sleepStarted)
        XCTAssertTrue(sleepResumed)
        XCTAssertTrue(eligibilityCheckArrived)
        XCTAssertNil(state.requestID)
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<20_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return false
    }
}
