import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class RecordingProcessActivityTests: XCTestCase {
    func testInactivePhasesNeverAcquireAnActivity() async {
        let probe = ActivityProbe()
        let activity = probe.makeActivity()
        for phase in [RecordingPhase.idle, .failed("Unavailable"), .done(MeetingID()), .idle] {
            activity.update(for: phase)
        }
        XCTAssertTrue(probe.tokens.isEmpty)
        XCTAssertTrue(probe.ended.isEmpty)
    }

    func testOneActivityCoversStartupRecordingAndEveryStopStage() async {
        let probe = ActivityProbe()
        let activity = probe.makeActivity()
        for phase in [RecordingPhase.preparing, .recording, .recording,
                      .processing("Saving"), .processing("Finishing")] {
            activity.update(for: phase)
            XCTAssertEqual(probe.tokens.count, 1)
            XCTAssertTrue(probe.ended.isEmpty)
        }
        activity.update(for: .done(MeetingID()))
        activity.update(for: .idle)
        XCTAssertEqual(probe.ended, probe.tokens)
        XCTAssertEqual(probe.options, [.userInitiatedAllowingIdleSystemSleep])
        XCTAssertEqual(probe.reasons, ["Recording and saving a meeting"])
        XCTAssertFalse(probe.options[0].contains(.idleSystemSleepDisabled))
        XCTAssertFalse(probe.options[0].contains(.idleDisplaySleepDisabled))
    }

    func testEveryActivePhaseReleasesOnFailureAndRetryGetsAFreshToken() async {
        for phase in [RecordingPhase.preparing, .recording, .processing("Saving")] {
            let probe = ActivityProbe()
            let activity = probe.makeActivity()
            activity.update(for: phase)
            activity.update(for: .failed("Interrupted"))
            activity.update(for: .failed("Interrupted"))
            XCTAssertEqual(probe.ended, probe.tokens)

            activity.update(for: .preparing)
            XCTAssertEqual(probe.tokens.count, 2)
            XCTAssertEqual(probe.ended.count, 1)
            XCTAssertFalse(probe.tokens[0] === probe.tokens[1])
            activity.update(for: .idle)
            XCTAssertEqual(probe.ended, probe.tokens)
        }
    }

    func testRepeatedSessionsDoNotAccumulateActivities() async {
        let probe = ActivityProbe()
        let activity = probe.makeActivity()
        for _ in 0..<100 {
            activity.update(for: .preparing)
            activity.update(for: .recording)
            activity.update(for: .processing("Saving"))
            activity.update(for: .done(MeetingID()))
            activity.update(for: .idle)
            XCTAssertEqual(probe.ended, probe.tokens)
        }
        XCTAssertEqual(probe.tokens.count, 100)
    }

    func testDeallocationEndsAnActiveTokenExactlyOnce() async {
        let probe = ActivityProbe()
        var activity: RecordingProcessActivity? = probe.makeActivity()
        weak let weakActivity = activity
        activity?.update(for: .recording)
        activity = nil
        XCTAssertNil(weakActivity)
        XCTAssertEqual(probe.tokens.count, 1)
        XCTAssertEqual(probe.ended, probe.tokens)
    }

    func testDeallocationDoesNotEndAnAlreadyReleasedTokenAgain() async {
        let probe = ActivityProbe()
        var activity: RecordingProcessActivity? = probe.makeActivity()
        activity?.update(for: .preparing)
        activity?.update(for: .failed("Denied"))
        activity = nil
        XCTAssertEqual(probe.tokens.count, 1)
        XCTAssertEqual(probe.ended, probe.tokens)
    }

    func testNativeAdapterAcceptsACompleteLifecycle() async {
        let activity = RecordingProcessActivity()
        activity.update(for: .preparing)
        activity.update(for: .recording)
        activity.update(for: .processing("Saving"))
        activity.update(for: .done(MeetingID()))
    }
}

@MainActor
private final class ActivityProbe {
    var tokens: [NSObject] = []
    var ended: [NSObject] = []
    var options: [ProcessInfo.ActivityOptions] = []
    var reasons: [String] = []

    func makeActivity() -> RecordingProcessActivity {
        RecordingProcessActivity(
            begin: { options, reason in
                let token = NSObject()
                self.tokens.append(token)
                self.options.append(options)
                self.reasons.append(reason)
                return token
            },
            end: { token in
                guard let token = token as? NSObject else {
                    return XCTFail("The exact acquired token must be released")
                }
                self.ended.append(token)
            })
    }
}
