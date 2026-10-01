import Foundation
import PortavozCore
import XCTest

@testable import TranscriptionKit

final class SpeechAnalyzerLiveEngineTests: XCTestCase {
    func testReadinessDoesNotTreatAutomaticOrUnsupportedLanguageAsInstalled() {
        guard #available(macOS 26.0, *) else { return }
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: nil, available: true, supported: "en_US", installed: ["en_US"]),
            .languageRequired)
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "auto", available: true, supported: "en_US", installed: ["en_US"]),
            .languageRequired)
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "es", available: false, supported: "es_ES", installed: ["es_ES"]),
            .unavailable)
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "es", available: true, supported: "en_US", installed: ["en_US"]),
            .unsupported("es"))
    }

    func testReadinessPrefersAnAlreadyInstalledEquivalentLanguage() {
        guard #available(macOS 26.0, *) else { return }
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "es", available: true, supported: "es_CL", installed: ["es_ES"]),
            .ready("es_ES"))
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "es", available: true, supported: "es_CL", installed: ["es_CL"]),
            .ready("es_CL"))
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "en", available: true, supported: nil, installed: []),
            .unsupported("en"))
        XCTAssertEqual(
            SpeechAnalyzerLiveReadiness.resolve(
                requested: "en", available: true, supported: "en_US", installed: ["es_ES"]),
            .needsDownload("en_US"))
    }

    func testFinalResultGateRejectsEmptyInvalidAndOverlappingRanges() throws {
        guard #available(macOS 26.0, *) else { return }
        let meetingID = MeetingID()
        func segment(
            _ text: String,
            start: Double,
            end: Double,
            final: Bool = true
        ) -> TranscriptSegment {
            TranscriptSegment(
                meetingID: meetingID,
                channel: .microphone,
                text: text,
                startTime: start,
                endTime: end,
                isFinal: final)
        }
        var gate = SpeechAnalyzerFinalResultGate()
        XCTAssertTrue(try gate.accept(segment("old", start: 0, end: 2, final: false)))
        XCTAssertFalse(try gate.accept(segment("  ", start: 0, end: 20)))
        XCTAssertTrue(try gate.accept(segment("one", start: 0, end: 2)))
        XCTAssertTrue(try gate.accept(segment("dos", start: 2, end: 3)))
        XCTAssertNoThrow(try gate.finish())
        XCTAssertThrowsError(try gate.accept(segment("repeat", start: 2.9, end: 4)))
        XCTAssertThrowsError(try gate.accept(segment("invalid", start: .nan, end: 5)))
        XCTAssertThrowsError(try gate.accept(segment("reverse", start: 6, end: 5)))
    }

    func testUnconfirmedTailFailsClosedAndLateVolatileCannotReviseAConfirmedRange() throws {
        guard #available(macOS 26.0, *) else { return }
        let meetingID = MeetingID()
        func segment(_ text: String, start: Double, end: Double, final: Bool) -> TranscriptSegment {
            TranscriptSegment(meetingID: meetingID, channel: .microphone,
                              text: text, startTime: start, endTime: end, isFinal: final)
        }
        var gate = SpeechAnalyzerFinalResultGate()
        XCTAssertTrue(try gate.accept(segment("Do not send", start: 0, end: 1, final: false)))
        XCTAssertThrowsError(try gate.finish())
        XCTAssertTrue(try gate.accept(segment("Do not send", start: 0, end: 1, final: true)))
        XCTAssertFalse(try gate.accept(segment("Send", start: 0, end: 1, final: false)))
        XCTAssertNoThrow(try gate.finish())
    }

    func testShortFinalCannotConfirmTheRestOfALongerVolatileRange() throws {
        guard #available(macOS 26.0, *) else { return }
        let meetingID = MeetingID()
        var gate = SpeechAnalyzerFinalResultGate()
        XCTAssertTrue(try gate.accept(TranscriptSegment(
            meetingID: meetingID, channel: .microphone, text: "Do not publish the rest",
            startTime: 0, endTime: 2, isFinal: false)))
        XCTAssertTrue(try gate.accept(TranscriptSegment(
            meetingID: meetingID, channel: .microphone, text: "Do not publish",
            startTime: 0, endTime: 1, isFinal: true)))
        XCTAssertThrowsError(try gate.finish())
    }

    func testAdjacentFinalRangesTogetherConfirmOneLongerVolatileRange() throws {
        guard #available(macOS 26.0, *) else { return }
        let meetingID = MeetingID()
        var gate = SpeechAnalyzerFinalResultGate()
        func segment(_ text: String, start: Double, end: Double, final: Bool)
            -> TranscriptSegment {
            TranscriptSegment(meetingID: meetingID, channel: .microphone,
                              text: text, startTime: start, endTime: end, isFinal: final)
        }
        XCTAssertTrue(try gate.accept(segment("one two", start: 0, end: 2, final: false)))
        XCTAssertTrue(try gate.accept(segment("one", start: 0, end: 1, final: true)))
        XCTAssertThrowsError(try gate.finish(), "the second half is not confirmed yet")
        XCTAssertTrue(try gate.accept(segment("two", start: 1, end: 2, final: true)))
        XCTAssertNoThrow(try gate.finish())
    }
}
