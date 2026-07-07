import Foundation
import XCTest
@testable import DiarizationKit
@testable import IntelligenceKit
@testable import PortavozCore
@testable import TranscriptionKit

final class CoreTypesTests: XCTestCase {
    func testTranscriptSegmentRoundTripsThroughCodable() throws {
        let segment = TranscriptSegment(
            meetingID: MeetingID(),
            channel: .microphone,
            text: "Hola, soy Johnny",
            language: "es",
            startTime: 1.5,
            endTime: 3.2,
            confidence: 0.94,
            isFinal: true
        )
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(decoded.text, segment.text)
        XCTAssertEqual(decoded.channel, .microphone)
        XCTAssertEqual(decoded.language, "es")
        XCTAssertTrue(decoded.isFinal)
    }

    func testAudioChunkComputesDurationFromSamplesAndRate() {
        let chunk = AudioChunk(
            channel: .system,
            samples: [Float](repeating: 0, count: 48_000),
            sampleRate: 48_000,
            timestamp: 0
        )
        XCTAssertEqual(chunk.duration, 1.0)
    }

    func testChannelsCoverDualCapture() {
        // "Mine vs theirs" must be structural: both channels exist from v1.
        XCTAssertTrue(AudioChannel.allCases.contains(.microphone))
        XCTAssertTrue(AudioChannel.allCases.contains(.system))
    }
}

final class IntelligenceTypesTests: XCTestCase {
    func testGeneralRecipeHasAttributionAwareInstructions() {
        XCTAssertTrue(Recipe.general.sections.contains("Action Items"))
        XCTAssertTrue(Recipe.general.instructions.contains("Never invent"))
    }

    func testSummaryRequestDefaultsToEnglishWithEmptyGlossary() {
        let request = SummaryRequest(
            meetingID: MeetingID(),
            segments: [],
            speakers: [],
            recipe: .general
        )
        XCTAssertEqual(request.targetLanguage, "en")
        XCTAssertTrue(request.glossary.isEmpty)
    }
}

final class ModelRegistryTests: XCTestCase {
    func testEveryModelTaskIsRoutable() {
        XCTAssertEqual(ModelTask.allCases.count, 5)
        XCTAssertTrue(ModelTask.allCases.contains(.liveTranscription))
        XCTAssertTrue(ModelTask.allCases.contains(.finalTranscription))
    }
}
