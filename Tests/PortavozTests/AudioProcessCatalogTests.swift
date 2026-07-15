import XCTest

@testable import AudioCaptureKit

final class AudioProcessCatalogTests: XCTestCase {
    func testAllowsTheMeetingAppAndItsHelpers() {
        let allowed = Set(["com.brave.Browser", "us.zoom.xos"])
        XCTAssertTrue(AudioProcessCatalog.bundleID(
            "com.brave.Browser", belongsToAnyOf: allowed))
        XCTAssertTrue(AudioProcessCatalog.bundleID(
            "com.brave.Browser.helper.Renderer", belongsToAnyOf: allowed))
        XCTAssertTrue(AudioProcessCatalog.bundleID(
            "US.ZOOM.XOS.Audio", belongsToAnyOf: allowed))
    }

    func testRejectsUnrelatedAndLookalikeApps() {
        let allowed = Set(["com.brave.Browser"])
        XCTAssertFalse(AudioProcessCatalog.bundleID(
            "com.spotify.client", belongsToAnyOf: allowed))
        XCTAssertFalse(AudioProcessCatalog.bundleID(
            "com.brave.BrowserEvil", belongsToAnyOf: allowed))
        XCTAssertFalse(AudioProcessCatalog.bundleID(
            "com.brave", belongsToAnyOf: allowed))
    }
}
