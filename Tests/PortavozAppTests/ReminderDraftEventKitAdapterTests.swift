import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class ReminderDraftEventKitAdapterTests: XCTestCase {
    func testDeliveryRequiresFullAccessBeforeAnySave() async throws {
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let store = RecordingReminderDraftEventStore(
            authorization: .denied,
            target: target)
        let adapter = AppReminderDraftEventKitAdapter(store: store)

        do {
            try await adapter.deliver(draft(), to: target)
            XCTFail("a denied app must not write a reminder")
        } catch {
            XCTAssertEqual(error as? AppReminderDraftError, .authorizationDenied)
            XCTAssertEqual(
                (error as? CategorizedFailure)?.category,
                .recoverable)
        }
        let savedAfterDenial = await store.savedDrafts
        XCTAssertTrue(savedAfterDenial.isEmpty)
    }

    func testDestinationRenameAfterPreviewFailsClosed() async throws {
        let previewed = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let renamed = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Renamed work"))
        let store = RecordingReminderDraftEventStore(
            authorization: .fullAccess,
            target: renamed)
        let adapter = AppReminderDraftEventKitAdapter(store: store)

        do {
            try await adapter.deliver(draft(), to: previewed)
            XCTFail("a changed destination must require a fresh preview")
        } catch {
            XCTAssertEqual(error as? AppReminderDraftError, .staleTarget)
        }
        let savedAfterRename = await store.savedDrafts
        XCTAssertTrue(savedAfterRename.isEmpty)
    }

    func testExactTargetAndDraftReachOneSave() async throws {
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let store = RecordingReminderDraftEventStore(
            authorization: .fullAccess,
            target: target)
        let adapter = AppReminderDraftEventKitAdapter(store: store)
        let expected = draft()

        try await adapter.deliver(expected, to: target)

        let saves = await store.savedDrafts
        XCTAssertEqual(saves, [ReminderDraftSave(draft: expected, target: target)])
    }

    func testPermissionRequestIsExplicitAndDelegatedOnce() async throws {
        let target = try XCTUnwrap(AppReminderDraftTarget(
            identifier: "opaque-list-42",
            title: "Work"))
        let store = RecordingReminderDraftEventStore(
            authorization: .notDetermined,
            requestedAuthorization: .fullAccess,
            target: target)
        let adapter = AppReminderDraftEventKitAdapter(store: store)

        let before = await adapter.authorizationStatus()
        let requested = try await adapter.requestFullAccess()
        let requestCount = await store.permissionRequestCount
        let resolvedTarget = await adapter.defaultTarget()
        XCTAssertEqual(before, .notDetermined)
        XCTAssertEqual(requested, .fullAccess)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(resolvedTarget, target)
    }

    private func draft() -> ReminderDraft {
        ReminderDraft(
            title: "Send the signed package",
            dueAt: Date(timeIntervalSince1970: 1_700_003_600),
            commitmentID: CommitmentID())
    }
}

private struct ReminderDraftSave: Equatable {
    let draft: ReminderDraft
    let target: AppReminderDraftTarget
}

private actor RecordingReminderDraftEventStore: AppReminderDraftEventStore {
    private var authorization: AppReminderDraftAuthorization
    private let requestedAuthorization: AppReminderDraftAuthorization
    private let target: AppReminderDraftTarget?
    private(set) var permissionRequestCount = 0
    private(set) var savedDrafts: [ReminderDraftSave] = []

    init(
        authorization: AppReminderDraftAuthorization,
        requestedAuthorization: AppReminderDraftAuthorization = .fullAccess,
        target: AppReminderDraftTarget?
    ) {
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization
        self.target = target
    }

    func authorizationStatus() -> AppReminderDraftAuthorization {
        authorization
    }

    func requestFullAccess() -> AppReminderDraftAuthorization {
        permissionRequestCount += 1
        authorization = requestedAuthorization
        return authorization
    }

    func defaultTarget() -> AppReminderDraftTarget? { target }

    func target(identifier: String) -> AppReminderDraftTarget? {
        target?.identifier == identifier ? target : nil
    }

    func save(_ draft: ReminderDraft, to target: AppReminderDraftTarget) {
        savedDrafts.append(ReminderDraftSave(draft: draft, target: target))
    }
}
