import PortavozCore
import XCTest

@testable import portavoz_app

final class PortavozAppIntentBridgeTests: XCTestCase {
    @MainActor
    func testLatestBufferedEntityNavigationWinsAndIsConsumedOnce() {
        _ = PortavozAppIntentBridge.consumeNavigationRequest()
        PortavozAppIntentBridge.requestNavigation(.meeting(UUID().uuidString))
        PortavozAppIntentBridge.requestNavigation(.commitments)

        XCTAssertEqual(
            PortavozAppIntentBridge.consumeNavigationRequest(),
            .commitments)
        XCTAssertNil(PortavozAppIntentBridge.consumeNavigationRequest())
    }

    @MainActor
    func testEntityNavigationRejectsMalformedTypedIdentifiersToRecoveryRoutes() {
        XCTAssertEqual(
            PortavozAppDelegate.route(for: .meeting("invalid")),
            .library)
        XCTAssertEqual(
            PortavozAppDelegate.route(for: .person("invalid")),
            .commitments(nil))
        XCTAssertEqual(
            PortavozAppDelegate.route(for: .commitment("invalid")),
            .commitments(nil))
    }

    @MainActor
    func testEntityOpenActionsRevalidateAndPublishEveryExactRoute() async {
        _ = PortavozAppIntentBridge.consumeNavigationRequest()
        let meeting = PortavozMeetingEntity(
            id: UUID().uuidString,
            title: "Stored meeting",
            dateDescription: "Today")
        let person = PortavozPersonEntity(
            id: UUID().uuidString,
            name: "Stored person")
        let commitment = PortavozCommitmentEntity(
            id: UUID().uuidString,
            title: "Stored commitment",
            dueDescription: nil)
        let catalog = StubPortavozAppEntityCatalog(
            meetingValues: [meeting],
            personValues: [person],
            commitmentValues: [commitment])

        _ = await PortavozAppEntityOpenAction.openMeeting(
            meeting,
            catalog: catalog)
        XCTAssertEqual(
            PortavozAppIntentBridge.consumeNavigationRequest(),
            .meeting(meeting.id))

        _ = await PortavozAppEntityOpenAction.showPersonCommitments(
            person,
            catalog: catalog)
        XCTAssertEqual(
            PortavozAppIntentBridge.consumeNavigationRequest(),
            .person(person.id))

        _ = await PortavozAppEntityOpenAction.openCommitment(
            commitment,
            catalog: catalog)
        XCTAssertEqual(
            PortavozAppIntentBridge.consumeNavigationRequest(),
            .commitment(commitment.id))
        XCTAssertNil(PortavozAppIntentBridge.consumeNavigationRequest())
    }

    @MainActor
    func testEntityOpenActionsRecoverFromMissingAndUnreadableCatalogValues() async {
        _ = PortavozAppIntentBridge.consumeNavigationRequest()
        let meeting = PortavozMeetingEntity(
            id: UUID().uuidString,
            title: "Missing meeting",
            dateDescription: "Today")
        let person = PortavozPersonEntity(
            id: UUID().uuidString,
            name: "Missing person")
        let commitment = PortavozCommitmentEntity(
            id: UUID().uuidString,
            title: "Missing commitment",
            dueDescription: nil)
        let missingCatalog = StubPortavozAppEntityCatalog()
        let unreadableCatalog = StubPortavozAppEntityCatalog(shouldFail: true)

        for catalog in [missingCatalog, unreadableCatalog] {
            _ = await PortavozAppEntityOpenAction.openMeeting(
                meeting,
                catalog: catalog)
            XCTAssertEqual(
                PortavozAppIntentBridge.consumeNavigationRequest(),
                .library)

            _ = await PortavozAppEntityOpenAction.showPersonCommitments(
                person,
                catalog: catalog)
            XCTAssertEqual(
                PortavozAppIntentBridge.consumeNavigationRequest(),
                .commitments)

            _ = await PortavozAppEntityOpenAction.openCommitment(
                commitment,
                catalog: catalog)
            XCTAssertEqual(
                PortavozAppIntentBridge.consumeNavigationRequest(),
                .commitments)
        }
        XCTAssertNil(PortavozAppIntentBridge.consumeNavigationRequest())
    }

    @MainActor
    func testPendingRequestCanBeRepublishedAfterServicesBecomeReady() {
        _ = PortavozAppIntentBridge.consumeStartRecordingRequest()
        var deliveries = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.startRecordingRequested,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { deliveries += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = PortavozAppIntentBridge.consumeStartRecordingRequest()
        }

        PortavozAppIntentBridge.requestStartRecording()
        PortavozAppIntentBridge.notifyPendingStartRecordingRequest()

        XCTAssertEqual(deliveries, 2)
        XCTAssertTrue(PortavozAppIntentBridge.consumeStartRecordingRequest())
    }

    @MainActor
    func testStartRecordingIntentHandsOffExactlyOnceInsideItsOwningProcess() async throws {
        // Drain any request left by a failed test before proving one-shot
        // delivery. The bridge is process-scoped by design.
        _ = PortavozAppIntentBridge.consumeStartRecordingRequest()

        _ = try await StartRecordingIntent().perform()

        XCTAssertTrue(PortavozAppIntentBridge.consumeStartRecordingRequest())
        XCTAssertFalse(
            PortavozAppIntentBridge.consumeStartRecordingRequest(),
            "one invocation must not start a second recording later")
    }

    @MainActor
    func testPendingStopRequestCanBeRepublishedAfterServicesBecomeReady() {
        _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        var deliveries = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.stopRecordingRequested,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { deliveries += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        }

        XCTAssertEqual(PortavozAppIntentBridge.requestStopRecording(), .queued)
        PortavozAppIntentBridge.notifyPendingStopRecordingRequest()

        XCTAssertEqual(deliveries, 2)
        XCTAssertTrue(
            PortavozAppIntentBridge.consumeStopRecordingRequest(as: .accepted))
        XCTAssertFalse(
            PortavozAppIntentBridge.consumeStopRecordingRequest(as: .accepted),
            "one request must never be accepted twice")
    }

    @MainActor
    func testStopRecordingIntentReturnsTheDelegateDispositionExactlyOnce() async throws {
        _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.stopRecordingRequested,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                XCTAssertTrue(PortavozAppIntentBridge.consumeStopRecordingRequest(
                    as: .accepted))
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        }

        _ = try await StopRecordingIntent().perform()

        XCTAssertFalse(
            PortavozAppIntentBridge.consumeStopRecordingRequest(as: .accepted),
            "perform() must not leave a second stop behind after acceptance")
    }

    @MainActor
    func testStopRecordingDispositionNamesEveryLifecycleRecovery() {
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .idle,
                stopTaskIsRunning: false),
            .noActiveRecording)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .preparing,
                stopTaskIsRunning: false),
            .recordingIsPreparing)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .recording,
                stopTaskIsRunning: false),
            .accepted)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .processing("Saving"),
                stopTaskIsRunning: false),
            .alreadyStopping)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .done(MeetingID()),
                stopTaskIsRunning: false),
            .noActiveRecording)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .failed("Failed"),
                stopTaskIsRunning: false),
            .recoveryRequired)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .recording,
                stopTaskIsRunning: true),
            .alreadyStopping,
            "the in-flight fence must win before another stop can schedule")
    }

}

private struct StubPortavozAppEntityCatalog: PortavozAppEntityCatalog {
    enum Failure: Error {
        case unreadable
    }

    var meetingValues: [PortavozMeetingEntity] = []
    var personValues: [PortavozPersonEntity] = []
    var commitmentValues: [PortavozCommitmentEntity] = []
    var shouldFail = false

    func meetings(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozMeetingEntity] {
        _ = (identifiers, matching, limit)
        if shouldFail { throw Failure.unreadable }
        return meetingValues
    }

    func people(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozPersonEntity] {
        _ = (identifiers, matching, limit)
        if shouldFail { throw Failure.unreadable }
        return personValues
    }

    func commitments(
        identifiers: [String]?,
        matching: String?,
        limit: Int
    ) async throws -> [PortavozCommitmentEntity] {
        _ = (identifiers, matching, limit)
        if shouldFail { throw Failure.unreadable }
        return commitmentValues
    }
}
