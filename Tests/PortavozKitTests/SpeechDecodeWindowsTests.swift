import PortavozCore
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

    func testWithoutAnySupportedDetectionWindowsTakeTheClosestSupportedLanguage() {
        XCTAssertEqual(
            SpeechDecodeWindows.languages(detected: ["ja", "pt", "gl", nil], allowed: ["en", "es"]),
            ["en", "es", "es", nil])
        XCTAssertEqual(
            SpeechDecodeWindows.languages(detected: ["pt"], allowed: ["en"]),
            ["en"])
    }

    func testFaintStretchedRowsAreDroppedButQuietRealPhrasesStay() {
        let rate = 16_000.0
        var samples = (0..<Int(rate * 60)).map { index in
            Float(0.003 * sin(Double(index) * 12.9898).truncatingRemainder(dividingBy: 1))
        }
        for range in [2.0..<5.0, 45.0..<50.0] {
            for index in Int(range.lowerBound * rate)..<Int(range.upperBound * rate) {
                samples[index] += Float(0.1 * sin(2 * Double.pi * 220 * Double(index) / rate))
            }
        }
        let meetingID = MeetingID()
        func row(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
            TranscriptSegment(meetingID: meetingID, channel: .microphone, text: text, startTime: start, endTime: end)
        }
        let stretch = 2 / FaintSpeechFilter.maximumWordsPerSecond + 0.5
        let rows = [
            row(2, 5, "Esto es una grabación"),
            row(10, 11.5, "Ya estoy cerrando las ventanas"),
            row(20, 40, "Gracias."),
            row(51, 51 + stretch, "E aí"),
            row(45, 50, "Okay."),
        ]

        let result = FaintSpeechFilter.filter(rows, samples: samples, sampleRate: rate)

        XCTAssertEqual(result.kept.map(\.text), ["Esto es una grabación", "Ya estoy cerrando las ventanas", "Okay."])
        XCTAssertEqual(result.droppedSeconds, 20 + stretch, accuracy: 0.001)
    }

    func testFaintFilterKeepsEverythingWithoutAudio() {
        let row = TranscriptSegment(meetingID: MeetingID(), channel: .system, text: "Hi", startTime: 0, endTime: 9)
        let result = FaintSpeechFilter.filter([row], samples: [], sampleRate: 16_000)
        XCTAssertEqual(result.kept.count, 1)
        XCTAssertEqual(result.droppedSeconds, 0)
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
