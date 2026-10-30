@testable import IntelligenceKit
import PortavozCore
import XCTest

final class SummaryDetailTests: XCTestCase {
    func testStandardKeepsTheHistoricalPrompts() {
        let historical = PromptFactory.summaryInstructions(
            recipe: .general, targetLanguage: "en", glossary: [])
        XCTAssertEqual(
            PromptFactory.summaryInstructions(
                recipe: .general, targetLanguage: "en", glossary: [], detail: .standard),
            historical)
        XCTAssertTrue(
            PromptFactory.notesInstructions(targetLanguage: "en", glossary: [])
                .contains("at most \(SummaryDetail.standard.noteBullets) terse bullet points"))
    }

    func testBriefAndDetailedAddTheirDirective() throws {
        for level in [SummaryDetail.brief, .detailed] {
            let directive = try XCTUnwrap(level.summaryDirective)
            XCTAssertTrue(
                PromptFactory.summaryInstructions(
                    recipe: .general, targetLanguage: "es", glossary: [], detail: level)
                    .contains(directive))
        }
        XCTAssertGreaterThan(SummaryDetail.detailed.noteBullets, SummaryDetail.standard.noteBullets)
        XCTAssertTrue(
            PromptFactory.notesInstructions(targetLanguage: "en", glossary: [], detail: .detailed)
                .contains("at most \(SummaryDetail.detailed.noteBullets) terse bullet points"))
    }

    func testOnlyNonStandardDetailChangesTheFingerprint() {
        let meetingID = MeetingID()
        let speaker = Speaker(meetingID: meetingID, label: "S1")
        let segment = TranscriptSegment(
            meetingID: meetingID, speakerID: speaker.id, channel: .system,
            text: "Ship on Friday", language: "en", startTime: 0, endTime: 2, isFinal: true)
        func fingerprint(_ detail: SummaryDetail?) -> String {
            var request = SummaryRequest(
                meetingID: meetingID, segments: [segment], speakers: [speaker], recipe: .general)
            if let detail { request.detail = detail }
            return SummaryFingerprint.compute(request: request, providerID: "fm")
        }

        XCTAssertEqual(fingerprint(nil), fingerprint(.standard))
        XCTAssertEqual(Set(SummaryDetail.allCases.map(fingerprint)).count, SummaryDetail.allCases.count)
    }
}
