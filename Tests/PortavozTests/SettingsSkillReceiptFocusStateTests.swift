import Foundation
import XCTest
@testable import portavoz_app

@MainActor
final class SettingsSkillReceiptFocusStateTests: XCTestCase {
    func testEligibleDismissalPublishesTheExactReceiptAfterTheModalScopeLeaves() async throws {
        let state = SettingsSkillReceiptFocusState()
        let receiptID = UUID()

        state.beginInspection(of: receiptID)
        state.restoreAfterDismissal { true }

        XCTAssertNil(state.requestID)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(state.requestID, receiptID)
    }

    func testClearCancelsAPendingRestoration() async throws {
        let state = SettingsSkillReceiptFocusState()

        state.beginInspection(of: UUID())
        state.restoreAfterDismissal { true }
        state.clear()

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(state.requestID)
    }

    func testNewInspectionSupersedesTheOlderRestoration() async throws {
        let state = SettingsSkillReceiptFocusState()
        let currentReceiptID = UUID()

        state.beginInspection(of: UUID())
        state.restoreAfterDismissal { true }
        state.beginInspection(of: currentReceiptID)
        state.restoreAfterDismissal { true }

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(state.requestID, currentReceiptID)
    }

    func testIneligibleDismissalNeverPublishesFocus() async throws {
        let state = SettingsSkillReceiptFocusState()

        state.beginInspection(of: UUID())
        state.restoreAfterDismissal { false }

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(state.requestID)
    }
}
