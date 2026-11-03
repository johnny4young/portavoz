import ApplicationKit
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class RecordingInputOwnerTests: XCTestCase {
    func testFailureRetainsTheExactChangeAndBlocksLaterAcknowledgementsUntilRetry() async {
        let owner = RecordingInputPersistence()
        let probe = Probe()
        owner.enqueue(text: "Unspoken — decisión pendiente") {
            probe.events.append("attempt")
            if probe.shouldFail { throw ProbeError.write }
            probe.events.append("accepted")
        }
        owner.enqueue { probe.events.append("later") }
        await owner.drain()
        XCTAssertEqual(probe.events, ["attempt"])
        owner.enqueue { XCTFail("a new automatic refresh must not accumulate behind a failed save") }
        XCTAssertTrue(owner.hasFailure)
        XCTAssertEqual(owner.retainedText, "Unspoken — decisión pendiente")
        probe.shouldFail = false
        owner.retry()
        await owner.drain()
        XCTAssertEqual(probe.events, ["attempt", "attempt", "accepted", "later"])
        XCTAssertFalse(owner.hasFailure)
        XCTAssertFalse(owner.isSaving)
    }

    func testDiscardIsExplicitAndDoesNotDiscardTheFollowingChange() async {
        let owner = RecordingInputPersistence()
        let probe = Probe()
        owner.enqueue { throw ProbeError.write }
        owner.enqueue { probe.acknowledged = true }
        await owner.drain()
        XCTAssertFalse(probe.acknowledged)
        owner.discardFailedChange()
        await owner.drain()
        XCTAssertTrue(probe.acknowledged)
        XCTAssertFalse(owner.hasFailure)
    }

    func testDrainWaitsForAdmittedWorkEvenWhenTheWaitingViewIsCancelled() async {
        let owner = RecordingInputPersistence()
        let began = expectation(description: "write entered")
        let probe = Probe()
        owner.enqueue {
            await withCheckedContinuation { continuation in
                probe.release = continuation
                began.fulfill()
            }
            probe.acknowledged = true
        }
        await fulfillment(of: [began], timeout: 2)
        let waiter = Task { await owner.drain() }
        waiter.cancel()
        XCTAssertTrue(owner.isSaving)
        XCTAssertFalse(probe.acknowledged)
        probe.release?.resume()
        await waiter.value
        XCTAssertTrue(probe.acknowledged)
        XCTAssertFalse(owner.isSaving)
    }

    func testHandshakeCannotBeSelectedOutsideDisposableComposition() async {
        let environment = ["PORTAVOZ_UI_TEST_INPUT_ENTERED_PATH": "/tmp/entered",
                           "PORTAVOZ_UI_TEST_INPUT_CONTINUE_PATH": "/tmp/release"]
        XCTAssertNil(RecordingInputUITestFixture(store: UnusedStore(), usesTemporaryStore: false,
                                                environment: environment))
        XCTAssertNil(RecordingInputUITestFixture(store: UnusedStore(), usesTemporaryStore: true, environment: [:]))
    }

    private struct UnusedStore: RecordingInputStore {
        func persistRecordingInput(_ items: [ContextItem], removing removedIDs: [UUID], for meetingID: MeetingID) async {}
    }

    private final class Probe {
        var shouldFail = true
        var events: [String] = []
        var acknowledged = false
        var release: CheckedContinuation<Void, Never>?
    }

    private enum ProbeError: Error { case write }
}
