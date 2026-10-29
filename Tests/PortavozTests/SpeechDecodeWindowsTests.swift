import XCTest

@testable import TranscriptionKit

final class SpeechDecodeWindowsTests: XCTestCase {
    func testSilenceBetweenTurnsNeverReachesTheDecoder() {
        let windows = SpeechDecodeWindows.plan([10...14, 600...603], duration: 3_600)

        XCTAssertEqual(windows, [9.8..<14.2, 599.8..<603.2])
    }

    func testShortPausesStayInOneWindowUpToWhispersLimit() {
        let windows = SpeechDecodeWindows.plan(
            [0...8, 9...17, 18...26, 27...35], duration: 60)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].lowerBound, 0)
        XCTAssertEqual(windows[0].upperBound, 26.2, accuracy: 1e-9)
        XCTAssertEqual(windows[1].lowerBound, 26.8, accuracy: 1e-9)
    }

    func testPaddingIsClampedToTheFile() {
        let windows = SpeechDecodeWindows.plan([0...1, 59.9...60], duration: 60)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0], 0..<1.2)
        XCTAssertEqual(windows[1].lowerBound, 59.7, accuracy: 1e-9)
        XCTAssertEqual(windows[1].upperBound, 60)
        XCTAssertTrue(SpeechDecodeWindows.plan([], duration: 60).isEmpty)
    }

    func testUnsupportedDetectionsTakeTheChannelMajority() {
        let languages = SpeechDecodeWindows.languages(
            detected: ["en", "de", "en", "ja", "es", nil],
            allowed: ["en", "es"])

        XCTAssertEqual(languages, ["en", "en", "en", "en", "es", "en"])
    }

    func testWithoutAnySupportedDetectionWindowsStayAutomatic() {
        XCTAssertEqual(
            SpeechDecodeWindows.languages(detected: ["ja", "pt", nil], allowed: ["en", "es"]),
            [nil, nil, nil])
    }

    func testMajorityTieIsDeterministic() {
        XCTAssertEqual(
            SpeechDecodeWindows.languages(detected: ["es", "en", "ru"], allowed: ["en", "es"]),
            ["es", "en", "en"])
    }

    func testCaptionMarkersAreStripped() {
        XCTAssertEqual(
            TranscriptionTextFilter.strippingCaptionMarkers("- I'll look at the site ID for you."),
            "I'll look at the site ID for you.")
        XCTAssertEqual(TranscriptionTextFilter.strippingCaptionMarkers("-5 degrees"), "-5 degrees")
        XCTAssertEqual(
            TranscriptionTextFilter.strippingCaptionMarkers("JOHN MUELLER: That's correct."),
            "That's correct.")
        XCTAssertEqual(
            TranscriptionTextFilter.strippingCaptionMarkers("VIKAS KHANNA: I think in that case,"),
            "I think in that case,")
        XCTAssertEqual(
            TranscriptionTextFilter.strippingCaptionMarkers("OK: let's go"), "OK: let's go")
        XCTAssertEqual(
            TranscriptionTextFilter.strippingCaptionMarkers("JOHNNY, does that align?"),
            "JOHNNY, does that align?")
        XCTAssertEqual(
            TranscriptionTextFilter.strippingCaptionMarkers("Note: the API changed"),
            "Note: the API changed")
    }

    func testSpanishSilenceBoilerplateIsKnown() {
        XCTAssertTrue(TranscriptionTextFilter.isKnownSilenceHallucination("Gracias."))
        XCTAssertTrue(TranscriptionTextFilter.isKnownSilenceHallucination("Gracias por ver el video."))
        XCTAssertFalse(TranscriptionTextFilter.isKnownSilenceHallucination("Gracias por el reporte"))
    }
}
