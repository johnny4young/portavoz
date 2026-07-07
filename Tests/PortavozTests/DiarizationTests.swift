import Foundation
import PortavozCore
import XCTest

@testable import DiarizationKit
@testable import ModelStoreKit

// MARK: - Catalog

final class DiarizationCatalogTests: XCTestCase {
    func testDiarizationDescriptorIsWellFormed() {
        let model = ModelCatalog.speakerDiarization
        XCTAssertEqual(model.artifacts.count, 10)
        XCTAssertTrue(model.tasks.contains(.diarization))
        XCTAssertTrue(model.resolveBase.absoluteString.contains(model.revision))

        for artifact in model.artifacts {
            XCTAssertEqual(artifact.sha256.count, 64)
            XCTAssertGreaterThan(artifact.sizeBytes, 0)
        }

        // Exactly the two bundles FluidAudio's explicit-path loader needs.
        let bundles = Set(model.artifacts.map { $0.path.components(separatedBy: "/").first! })
        XCTAssertEqual(bundles, ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"])

        // ~14 MB — small enough to bundle-download without ceremony.
        XCTAssertLessThan(model.totalSizeBytes, 20_000_000)
    }

    func testDiarizationIsRoutable() {
        XCTAssertEqual(ModelCatalog.recommended(for: .diarization)?.id, "speaker-diarization-coreml")
    }
}

// MARK: - Attribution

final class SpeakerAttributorTests: XCTestCase {
    private let meeting = MeetingID()

    private func segment(
        _ text: String, channel: AudioChannel, from start: TimeInterval, to end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting, channel: channel, text: text,
            startTime: start, endTime: end, isFinal: true)
    }

    /// D5: everything on the mic channel is the user — no ML, no turns needed.
    func testMicrophoneSegmentsAreAlwaysMe() {
        let attribution = SpeakerAttributor.attribute(
            segments: [segment("hola, soy yo", channel: .microphone, from: 0, to: 2)],
            turns: [],
            meetingID: meeting
        )
        XCTAssertEqual(attribution.speakers.count, 1)
        XCTAssertEqual(attribution.speakers[0].label, "Me")
        XCTAssertTrue(attribution.speakers[0].isMe)
        XCTAssertEqual(attribution.segments[0].speakerID, attribution.speakers[0].id)
    }

    func testSystemSegmentWithinOneTurnTakesThatVoice() {
        let turns = [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 6)]
        let attribution = SpeakerAttributor.attribute(
            segments: [segment("texto de la reunión", channel: .system, from: 4, to: 8)],
            turns: turns,
            meetingID: meeting
        )
        XCTAssertEqual(attribution.segments.count, 1)
        let speaker = attribution.speakers.first { $0.id == attribution.segments[0].speakerID }
        XCTAssertEqual(speaker?.label, "S1")
        XCTAssertEqual(speaker?.isMe, false)
    }

    /// Better unattributed than misattributed: no overlap → nil speaker.
    func testUncoveredSegmentsStayUnattributed() {
        let attribution = SpeakerAttributor.attribute(
            segments: [segment("nadie habló aquí según pyannote", channel: .system, from: 20, to: 22)],
            turns: [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 5)],
            meetingID: meeting
        )
        XCTAssertNil(attribution.segments[0].speakerID)
        XCTAssertTrue(attribution.speakers.isEmpty)
    }

    func testSpeakersAreDedupedAcrossSegmentsAndMeSortsFirst() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 4),
            SpeakerTurn(voiceLabel: "S1", startTime: 6, endTime: 10),
        ]
        let attribution = SpeakerAttributor.attribute(
            segments: [
                segment("primera de S1", channel: .system, from: 1, to: 3),
                segment("mía", channel: .microphone, from: 4, to: 5),
                segment("segunda de S1", channel: .system, from: 7, to: 9),
            ],
            turns: turns,
            meetingID: meeting
        )
        XCTAssertEqual(attribution.speakers.count, 2)
        XCTAssertEqual(attribution.speakers[0].label, "Me")
        XCTAssertEqual(attribution.speakers[1].label, "S1")
        // Both S1 segments resolve to the SAME speaker record.
        XCTAssertEqual(attribution.segments[0].speakerID, attribution.segments[2].speakerID)
    }

    /// A long batch segment spanning two turns is cut at the boundary,
    /// dealing its words out proportionally to time.
    func testMultiTurnSegmentIsSplitAtTurnBoundaries() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 6),
            SpeakerTurn(voiceLabel: "S2", startTime: 6, endTime: 12),
        ]
        let long = segment(
            "uno dos tres cuatro cinco seis siete ocho nueve diez once doce",
            channel: .system, from: 0, to: 12)

        let attribution = SpeakerAttributor.attribute(
            segments: [long], turns: turns, meetingID: meeting)

        XCTAssertEqual(attribution.segments.count, 2)
        XCTAssertEqual(attribution.segments[0].text, "uno dos tres cuatro cinco seis")
        XCTAssertEqual(attribution.segments[1].text, "siete ocho nueve diez once doce")
        XCTAssertEqual(attribution.segments[0].endTime, 6)
        XCTAssertEqual(attribution.segments[1].startTime, 6)

        let labelsByID = Dictionary(
            uniqueKeysWithValues: attribution.speakers.map { ($0.id, $0.label) })
        XCTAssertEqual(attribution.segments[0].speakerID.flatMap { labelsByID[$0] }, "S1")
        XCTAssertEqual(attribution.segments[1].speakerID.flatMap { labelsByID[$0] }, "S2")
    }

    /// Turns separated by a gap: the cut lands midway through the gap, and
    /// back-to-back turns of the same voice never split.
    func testSliceCutsMidGapAndMergesSameVoice() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 2),
            SpeakerTurn(voiceLabel: "S1", startTime: 2, endTime: 4),
            SpeakerTurn(voiceLabel: "S2", startTime: 8, endTime: 12),
        ]
        let pieces = SpeakerAttributor.slice(
            segment("a b c d e f", channel: .system, from: 0, to: 12), across: turns)

        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].voiceLabel, "S1")
        XCTAssertEqual(pieces[1].voiceLabel, "S2")
        XCTAssertEqual(pieces[0].endTime, 6)  // midpoint of the 4…8 gap
        XCTAssertEqual(pieces[0].text, "a b c")
        XCTAssertEqual(pieces[1].text, "d e f")
    }

    func testOverlapMath() {
        let turn = SpeakerTurn(voiceLabel: "S1", startTime: 2, endTime: 6)
        XCTAssertEqual(
            SpeakerAttributor.overlap(turn, segment("x", channel: .system, from: 4, to: 8)), 2)
        XCTAssertEqual(
            SpeakerAttributor.overlap(turn, segment("x", channel: .system, from: 6, to: 8)), 0)
        XCTAssertEqual(
            SpeakerAttributor.overlap(turn, segment("x", channel: .system, from: 0, to: 10)), 4)
    }
}

// MARK: - Real-model integration (gated)

final class DiarizationIntegrationTests: XCTestCase {
    /// Diarizes a synthetic two-voice conversation and expects at least two
    /// distinct speakers. Needs PORTAVOZ_MODEL_TESTS=1, the diarization
    /// model installed, and PORTAVOZ_TEST_CONVERSATION_WAV pointing at a
    /// wav with 2+ alternating voices.
    func testTwoVoiceConversationYieldsTwoSpeakers() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard let wavPath = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_CONVERSATION_WAV"]
        else {
            throw XCTSkip("set PORTAVOZ_TEST_CONVERSATION_WAV to a two-voice wav")
        }

        let store = ModelStore()
        let descriptor = ModelCatalog.speakerDiarization
        let directory = try await store.ensureAvailable(descriptor)
        let diarizer = try PyannoteDiarizer.load(fromVerifiedDirectory: directory)

        let turns = try await diarizer.diarizeFile(at: URL(fileURLWithPath: wavPath))
        XCTAssertFalse(turns.isEmpty)

        let voices = Set(turns.map(\.voiceLabel))
        XCTAssertGreaterThanOrEqual(voices.count, 2, "expected ≥2 voices, got \(voices)")

        for turn in turns {
            XCTAssertLessThan(turn.startTime, turn.endTime)
        }
    }
}
