import Foundation
import PortavozCore
import XCTest

final class ActiveCallDetectorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    private func signal(
        bundleID: String = "us.zoom.xos",
        appName: String = "Zoom",
        mic: Bool = true,
        output: Bool = true,
        native: Bool = true
    ) -> ActiveCallSignal {
        ActiveCallSignal(
            bundleID: bundleID,
            appName: appName,
            isUsingMicrophone: mic,
            isPlayingAudio: output,
            isNativeCallApp: native)
    }

    func testOutputOnlyMediaNeverTriggersANudge() {
        var detector = ActiveCallDetector()
        let youtube = signal(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            mic: false,
            output: true,
            native: false)

        XCTAssertNil(detector.observe(signals: [youtube], isRecording: false, at: origin))
        XCTAssertNil(detector.observe(
            signals: [youtube], isRecording: false, at: origin.addingTimeInterval(10)))
        XCTAssertNil(detector.activeNudge)
    }

    func testRequiresSustainedMicrophoneActivityBeforeNudging() {
        var detector = ActiveCallDetector(confirmationDuration: 4)
        let zoom = signal()

        XCTAssertNil(detector.observe(signals: [zoom], isRecording: false, at: origin))
        XCTAssertNil(detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(3)))

        let nudge = detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(4))
        XCTAssertEqual(nudge?.bundleID, "us.zoom.xos")
        XCTAssertEqual(nudge?.appName, "Zoom")
    }

    func testBriefMicProbeResetsCandidateWhenSilentAgain() {
        var detector = ActiveCallDetector(confirmationDuration: 4)
        let zoom = signal()

        XCTAssertNil(detector.observe(signals: [zoom], isRecording: false, at: origin))
        XCTAssertNil(detector.observe(
            signals: [], isRecording: false, at: origin.addingTimeInterval(2)))
        XCTAssertNil(detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(5)))
        XCTAssertNil(detector.activeNudge, "a restarted probe must satisfy a fresh confirmation window")
    }

    func testPrefersNativeCallAppOverBrowserWhenBothUseMic() {
        var detector = ActiveCallDetector(confirmationDuration: 4)
        let chrome = signal(
            bundleID: "com.google.Chrome", appName: "Google Chrome", native: false)
        let teams = signal(
            bundleID: "com.microsoft.teams2", appName: "Microsoft Teams", native: true)

        XCTAssertNil(detector.observe(signals: [chrome, teams], isRecording: false, at: origin))
        let nudge = detector.observe(
            signals: [chrome, teams], isRecording: false, at: origin.addingTimeInterval(5))
        XCTAssertEqual(nudge?.bundleID, "com.microsoft.teams2")
        XCTAssertEqual(nudge?.appName, "Microsoft Teams")
    }

    func testRecordingActiveSuppressesAndClearsNudge() {
        var detector = ActiveCallDetector(confirmationDuration: 4)
        let slack = signal(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")

        _ = detector.observe(signals: [slack], isRecording: false, at: origin)
        XCTAssertNotNil(detector.observe(
            signals: [slack], isRecording: false, at: origin.addingTimeInterval(4)))

        XCTAssertNil(detector.observe(
            signals: [slack], isRecording: true, at: origin.addingTimeInterval(6)))
        XCTAssertNil(detector.activeNudge)
    }

    func testDismissSilencesCurrentCallAndRearmsAfterCallEnds() {
        var detector = ActiveCallDetector(
            confirmationDuration: 4,
            clearAfterQuiet: 6,
            quietResetDuration: 30)
        let zoom = signal()

        _ = detector.observe(signals: [zoom], isRecording: false, at: origin)
        XCTAssertNotNil(detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(4)))
        detector.dismiss(at: origin.addingTimeInterval(5))
        XCTAssertNil(detector.activeNudge)

        // Same call continuing does not re-nag.
        XCTAssertNil(detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(15)))
        XCTAssertNil(detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(25)))

        // Call stops for >= 30 s, then a brand new call starts.
        XCTAssertNil(detector.observe(
            signals: [], isRecording: false, at: origin.addingTimeInterval(60)))
        XCTAssertNil(detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(65)))
        let secondNudge = detector.observe(
            signals: [zoom], isRecording: false, at: origin.addingTimeInterval(69))
        XCTAssertEqual(secondNudge?.bundleID, "us.zoom.xos")
    }

    func testDismissedCallStaysSilentHoweverLongItRuns() {
        var detector = ActiveCallDetector(confirmationDuration: 4, quietResetDuration: 30)
        let teams = signal(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams")

        _ = detector.observe(signals: [teams], isRecording: false, at: origin)
        XCTAssertNotNil(detector.observe(
            signals: [teams], isRecording: false, at: origin.addingTimeInterval(4)))
        detector.dismiss(at: origin.addingTimeInterval(5))

        for second in stride(from: 8.0, through: 3 * 3_600, by: 3) {
            XCTAssertNil(detector.observe(
                signals: [teams], isRecording: false, at: origin.addingTimeInterval(second)))
        }
    }

    func testActiveNudgeClearsAutomaticallyAfterCallEnds() {
        var detector = ActiveCallDetector(confirmationDuration: 4, clearAfterQuiet: 6)
        let meet = signal(
            bundleID: "com.google.Chrome", appName: "Google Chrome", native: false)

        _ = detector.observe(signals: [meet], isRecording: false, at: origin)
        XCTAssertNotNil(detector.observe(
            signals: [meet], isRecording: false, at: origin.addingTimeInterval(4)))

        // Brief dip under 6 s keeps the banner visible.
        XCTAssertNotNil(detector.observe(
            signals: [], isRecording: false, at: origin.addingTimeInterval(8)))
        // Quiet past 6 s clears it cleanly.
        XCTAssertNil(detector.observe(
            signals: [], isRecording: false, at: origin.addingTimeInterval(10)))
    }
}
