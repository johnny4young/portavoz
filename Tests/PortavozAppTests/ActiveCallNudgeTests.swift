import AudioCaptureKit
import Foundation
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
