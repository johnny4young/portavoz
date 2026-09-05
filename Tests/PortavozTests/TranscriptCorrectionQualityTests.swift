import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class TranscriptCorrectionQualityTests: XCTestCase {
    private let composer = ComposeTranscript()
    private let meetingID = MeetingID(rawValue: TranscriptCorrectionQualityTests.uuid(90_001))
    private let firstSpeaker = SpeakerID(
        rawValue: TranscriptCorrectionQualityTests.uuid(90_002))
    private let secondSpeaker = SpeakerID(
        rawValue: TranscriptCorrectionQualityTests.uuid(90_003))
    private let sourceDeviceID = TranscriptCorrectionQualityTests.uuid(90_004)

    func testSeededOperationSequencesRemainOrderIndependent() throws {
        let fixture = operationFixture()
        let canonical = try compose(
            segments: fixture.segments,
            corrections: fixture.corrections)

        for seed in 0..<64 {
            var generator = SeededGenerator(seed: UInt64(seed + 1))
            let shuffledSegments = fixture.segments.shuffled(using: &generator)
            let shuffledCorrections = fixture.corrections.shuffled(using: &generator)
            let candidate = try compose(
                segments: shuffledSegments,
                corrections: shuffledCorrections)

            XCTAssertEqual(candidate, canonical, "composition changed for seed \(seed)")
            XCTAssertTrue(candidate.composed.rows.allSatisfy { row in
                !row.sourceSegmentIDs.isEmpty
                    && row.startTime.isFinite
                    && row.endTime.isFinite
                    && row.endTime >= row.startTime
            })
        }

        XCTAssertEqual(
            canonical.composed.rows.map(\.text),
            [
                "Texto corregido", "English source", "Uno", "dos",
                "Merge these", "Original restored", "Final row",
            ])
        XCTAssertEqual(canonical.composed.rows[1].speakerID, secondSpeaker)
        XCTAssertEqual(canonical.composed.lineage.activeCorrectionIDs.count, 6)
    }

    func testRefinedBilingualCompositionPreservesEachSpeakersLanguage() throws {
        let spanish = segment(
            1,
            text: "Hola, estamos probando",
            language: "es",
            speakerID: firstSpeaker,
            start: 0,
            end: 4)
        let english = segment(
            2,
            text: "We are reviewing the API",
            language: "en",
            speakerID: secondSpeaker,
            start: 4,
            end: 8)
        let spanishReplacement = correction(
            101,
            targets: [spanish.id],
            kind: .replaceText(text: "Hola, estamos probando el flujo", language: "es"))
        let englishSpeaker = correction(
            102,
            targets: [english.id],
            kind: .changeSpeaker(firstSpeaker))

        let result = try composer.execute(
            baseTranscriptRevision: 8,
            baseMaterial: .refined,
            segments: [english, spanish],
            corrections: [englishSpeaker, spanishReplacement])

        XCTAssertEqual(result.accepted.lineage.baseMaterial, .refined)
        XCTAssertEqual(result.composed.lineage.baseMaterial, .refined)
        XCTAssertEqual(
            result.composed.rows.map(\.text),
            ["Hola, estamos probando el flujo", "We are reviewing the API"])
        XCTAssertEqual(result.composed.rows.map(\.language), ["es", "en"])
        XCTAssertEqual(result.composed.rows.map(\.sourceSegmentIDs), [[spanish.id], [english.id]])
        XCTAssertEqual(result.composed.rows.map(\.speakerID), [firstSpeaker, firstSpeaker])
    }
}

private extension TranscriptCorrectionQualityTests {
    struct OperationFixture {
        let segments: [TranscriptSegment]
        let corrections: [TranscriptCorrectionEvent]
    }

    func operationFixture() -> OperationFixture {
        let segments = [
            segment(1, text: "Texto incorrecto", language: "es", start: 0, end: 2),
            segment(2, text: "English source", language: "en", start: 2, end: 4),
            segment(3, text: "Uno dos", language: "es", start: 4, end: 6),
            segment(4, text: "Merge", language: "en", start: 6, end: 8),
            segment(5, text: "these", language: "en", start: 8, end: 10),
            segment(6, text: "Remove me", language: "en", start: 10, end: 12),
            segment(7, text: "Original restored", language: "en", start: 12, end: 14),
            segment(8, text: "Final row", language: "en", start: 14, end: 16),
        ]
        let temporary = correction(
            106,
            targets: [segments[6].id],
            kind: .replaceText(text: "Temporary", language: "en"),
            at: 6)
        let restore = correction(
            107,
            targets: [segments[6].id],
            kind: .restore,
            at: 7,
            supersedes: temporary.id)
        return OperationFixture(
            segments: segments,
            corrections: [
                correction(
                    101,
                    targets: [segments[0].id],
                    kind: .replaceText(text: "Texto corregido", language: "es")),
                correction(
                    102,
                    targets: [segments[1].id],
                    kind: .changeSpeaker(secondSpeaker)),
                correction(
                    103,
                    targets: [segments[2].id],
                    kind: .split([
                        part(301, text: "Uno", language: "es", start: 4, end: 5),
                        part(302, text: "dos", language: "es", start: 5, end: 6),
                    ])),
                correction(
                    104,
                    targets: [segments[3].id, segments[4].id],
                    kind: .merge(replacementText: nil, language: "en")),
                correction(105, targets: [segments[5].id], kind: .suppress),
                temporary,
                restore,
            ])
    }

    func compose(
        segments: [TranscriptSegment],
        corrections: [TranscriptCorrectionEvent]
    ) throws -> TranscriptComposition {
        try composer.execute(
            baseTranscriptRevision: 8,
            baseMaterial: .refined,
            segments: segments,
            corrections: corrections)
    }

    func segment(
        _ value: Int,
        text: String,
        language: String,
        speakerID: SpeakerID? = nil,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: Self.uuid(value),
            meetingID: meetingID,
            speakerID: speakerID ?? firstSpeaker,
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: end,
            confidence: 0.92,
            isFinal: true)
    }

    func correction(
        _ value: Int,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        at: TimeInterval? = nil,
        supersedes: UUID? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: Self.uuid(value),
            meetingID: meetingID,
            baseTranscriptRevision: 8,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + (at ?? Double(value))),
            supersedesCorrectionID: supersedes)
    }

    func part(
        _ value: Int,
        text: String,
        language: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptCorrectionPart {
        TranscriptCorrectionPart(
            id: Self.uuid(value),
            text: text,
            speakerID: firstSpeaker,
            language: language,
            startTime: start,
            endTime: end)
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
