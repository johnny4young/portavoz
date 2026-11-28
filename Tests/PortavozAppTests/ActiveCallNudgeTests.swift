import AudioCaptureKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class ActiveCallNudgeTests: XCTestCase {
    func testMergesBrowserHelperProcessesAndPrioritizesNativeCallApps() {
        let processes = [
            ActiveAudioProcess(
                pid: 101,
                bundleID: "com.google.Chrome.helper",
                isRunningInput: true,
                isRunningOutput: false),
            ActiveAudioProcess(
                pid: 102,
                bundleID: "com.google.Chrome.helper.renderer",
                isRunningInput: false,
                isRunningOutput: true),
            ActiveAudioProcess(
                pid: 202,
                bundleID: "us.zoom.xos.helper",
                isRunningInput: true,
                isRunningOutput: true),
            ActiveAudioProcess(
                pid: 303,
                bundleID: "com.spotify.client",
                isRunningInput: false,
                isRunningOutput: true),
        ]

        let signals = MeetingAppDetector.activeCallSignals(
            from: processes,
            runningNames: ["com.google.chrome": "Google Chrome"])

        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals[0].bundleID, "us.zoom.xos")
        XCTAssertEqual(signals[0].appName, "Zoom")
        XCTAssertTrue(signals[0].isNativeCallApp)
        XCTAssertTrue(signals[0].isUsingMicrophone)

        XCTAssertEqual(signals[1].bundleID, "com.google.Chrome")
        XCTAssertEqual(signals[1].appName, "Google Chrome")
        XCTAssertFalse(signals[1].isNativeCallApp)
        XCTAssertTrue(signals[1].isUsingMicrophone)
        XCTAssertTrue(signals[1].isPlayingAudio)
    }

    func testCanonicalBundleIDRejectsPrefixSpoofing() {
        XCTAssertEqual(
            MeetingAppDetector.canonicalBundleID(for: "com.brave.Browser.helper"),
            "com.brave.Browser")
        XCTAssertNil(
            MeetingAppDetector.canonicalBundleID(for: "com.brave.BrowserEvil"))
    }

    func testPreferencesDefaultEnabledAndHonorOptOut() {
        let suiteName = "ActiveCallNudgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ActiveCallNudgePreferences.isEnabled(in: defaults))
        defaults.set(false, forKey: ActiveCallNudgePreferences.enabledKey)
        XCTAssertFalse(ActiveCallNudgePreferences.isEnabled(in: defaults))
    }
}

@MainActor
final class ActiveCallNudgeControllerTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)
    private let zoom = ActiveCallSignal(
        bundleID: "us.zoom.xos",
        appName: "Zoom",
        isUsingMicrophone: true,
        isPlayingAudio: true,
        isNativeCallApp: true)

    private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func confirmedNudge(_ controller: ActiveCallNudgeController) {
        XCTAssertNil(controller.poll(enabled: true, isRecording: false, at: at(0)))
        XCTAssertNotNil(controller.poll(enabled: true, isRecording: false, at: at(4)))
    }

    func testRecordedCallStaysSilentAfterALongRecordingStops() async {
        let controller = ActiveCallNudgeController(signalSource: { [zoom] in [zoom] })
        confirmedNudge(controller)
        controller.accept(at: at(5))

        for second in stride(from: 8.0, through: 120, by: 3) {
            XCTAssertNil(controller.poll(enabled: true, isRecording: true, at: at(second)))
        }
        XCTAssertNil(controller.poll(enabled: true, isRecording: false, at: at(123)))
        XCTAssertNil(
            controller.poll(enabled: true, isRecording: false, at: at(129)),
            "the call that was just recorded must not nudge again when recording stops")
    }

    func testIgnoredBannerDoesNotReappearAfterAutoDismiss() async {
        let controller = ActiveCallNudgeController(signalSource: { [zoom] in [zoom] })
        confirmedNudge(controller)
        controller.dismiss(at: at(124))

        XCTAssertNil(controller.poll(enabled: true, isRecording: false, at: at(127)))
    }

    func testReenablingRequiresAFreshConfirmationWindow() async {
        let controller = ActiveCallNudgeController(signalSource: { [zoom] in [zoom] })
        XCTAssertNil(controller.poll(enabled: true, isRecording: false, at: at(0)))
        XCTAssertNil(controller.poll(enabled: false, isRecording: false, at: at(2)))

        XCTAssertNil(controller.poll(enabled: true, isRecording: false, at: at(60)))
        XCTAssertNotNil(controller.poll(enabled: true, isRecording: false, at: at(64)))
    }
}
