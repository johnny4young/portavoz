import ApplicationKit
import PortavozCore
import XCTest

@testable import portavoz_app

/// The recording phase is the only capture owner the resource governor sees.
@MainActor
final class RecordingResourceOwnershipTests: XCTestCase {
    func testRecordingProtectsMaintenanceUntilItStops() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        defer { services.recordingPhaseDidChange(.idle) }
        services.recordingPhaseDidChange(.recording)
        XCTAssertEqual(services.resourceCaptureState.current, .active)
        XCTAssertEqual(AppResourceGovernorMaintenanceGate.disposition(
            for: ResourceWorkloadDescriptor(
                workloadClass: .maintenance, kind: .searchIndex, operation: .execute),
            phase: .admission, captureState: services.resourceCaptureState.current), .pause)
        services.requestSearchReconciliation()
        for owner: BackgroundWorkOwner in [.semanticIndex, .memoryGraph] {
            XCTAssertEqual(services.backgroundWork.snapshots[owner]?.phase, .waitingForRecording,
                           "The actual reconciliation entry point must yield to the recording")
        }
        services.recordingPhaseDidChange(.idle)
        XCTAssertEqual(services.resourceCaptureState.current, .inactive)
    }

    func testEveryRecordingPhaseSetsTheCaptureStateItself() async throws {
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:])
        defer { services.recordingPhaseDidChange(.idle) }
        let expected: [(RecordingPhase, ResourceCaptureState)] = [
            (.preparing, .starting), (.recording, .active), (.processing("Saving"), .stopping),
            (.done(MeetingID()), .inactive), (.preparing, .starting), (.failed("x"), .inactive),
            (.recording, .active), (.idle, .inactive)
        ]
        for (phase, state) in expected {
            services.recordingPhaseDidChange(phase)
            XCTAssertEqual(services.resourceCaptureState.current, state, "\(phase)")
        }
    }
}
