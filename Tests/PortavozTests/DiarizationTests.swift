import AVFoundation
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

// MARK: - Phantom tail speakers

final class SanitizeTurnsTests: XCTestCase {
    func testDropsLowQualityLabelBornInTheFinalWindow() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 10, confidence: 0.6),
            SpeakerTurn(voiceLabel: "S2", startTime: 12, endTime: 20, confidence: 0.5),
            // Phantom: only exists in the last window, weak embedding.
            SpeakerTurn(voiceLabel: "S3", startTime: 31, endTime: 34, confidence: 0.2),
        ]
        let cleaned = PyannoteDiarizer.sanitizeTurns(turns, audioDuration: 34)
        XCTAssertEqual(Set(cleaned.map(\.voiceLabel)), ["S1", "S2"])
    }

    func testKeepsRecurringLabelEvenWithWeakTailTurn() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 10, confidence: 0.6),
            SpeakerTurn(voiceLabel: "S1", startTime: 31, endTime: 34, confidence: 0.2),
        ]
        let cleaned = PyannoteDiarizer.sanitizeTurns(turns, audioDuration: 34)
        XCTAssertEqual(cleaned.count, 2)
    }

    func testKeepsConfidentLatecomer() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 28, confidence: 0.6),
            // Joins at the end but with a clear voice: a real person.
            SpeakerTurn(voiceLabel: "S2", startTime: 30, endTime: 34, confidence: 0.8),
        ]
        let cleaned = PyannoteDiarizer.sanitizeTurns(turns, audioDuration: 34)
        XCTAssertEqual(cleaned.count, 2)
    }

    func testNeverDropsEnrolledMe() {
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 28, confidence: 0.6),
            SpeakerTurn(voiceLabel: "Me", startTime: 31, endTime: 34, confidence: 0.1),
        ]
        let cleaned = PyannoteDiarizer.sanitizeTurns(turns, audioDuration: 34)
        XCTAssertEqual(cleaned.count, 2)
    }
}

// MARK: - DER evaluation

final class DiarizationEvaluationTests: XCTestCase {
    func testParsesRTTMSpeakerRecords() {
        let rttm = """
            SPEAKER sample 1 6.690 0.430 <NA> <NA> speaker90 <NA> <NA>
            SPEAKER sample 1 7.550 0.800 <NA> <NA> speaker91 <NA> <NA>
            ;; comment line
            SPKR-INFO sample 1 <NA> <NA> <NA> unknown speaker90 <NA>
            """
        let turns = DiarizationEvaluation.parseRTTM(rttm)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].voiceLabel, "speaker90")
        XCTAssertEqual(turns[0].startTime, 6.69, accuracy: 0.001)
        XCTAssertEqual(turns[0].endTime, 7.12, accuracy: 0.001)
        XCTAssertEqual(turns[1].voiceLabel, "speaker91")
    }

    func testPerfectHypothesisScoresZeroWithLabelMapping() {
        let reference = [
            SpeakerTurn(voiceLabel: "alice", startTime: 0, endTime: 5),
            SpeakerTurn(voiceLabel: "bob", startTime: 5, endTime: 10),
        ]
        // Same timeline, different label names: mapping must absorb it.
        let hypothesis = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 5),
            SpeakerTurn(voiceLabel: "S2", startTime: 5, endTime: 10),
        ]
        let score = DiarizationEvaluation.score(
            reference: reference, hypothesis: hypothesis, collar: 0)
        XCTAssertEqual(score.der, 0, accuracy: 0.01)
        XCTAssertEqual(score.mapping["S1"], "alice")
        XCTAssertEqual(score.mapping["S2"], "bob")
    }

    func testMissedSpeechRaisesDER() {
        let reference = [SpeakerTurn(voiceLabel: "alice", startTime: 0, endTime: 10)]
        let hypothesis = [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 5)]
        let score = DiarizationEvaluation.score(
            reference: reference, hypothesis: hypothesis, collar: 0)
        XCTAssertEqual(score.miss, 0.5, accuracy: 0.02)
        XCTAssertGreaterThan(score.der, 0.4)
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

    /// Streams a real meeting through the LIVE path — `diarize(AsyncStream)`,
    /// the exact pipeline the recording UI feeds chunk by chunk — and expects
    /// ≥2 distinct voices (spec 03 live hints). Same gating as above; caps at
    /// 4 minutes to stay quick.
    func testLiveStreamingPathFindsMultipleVoices() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard let wavPath = ProcessInfo.processInfo.environment["PORTAVOZ_TEST_CONVERSATION_WAV"]
        else {
            throw XCTSkip("set PORTAVOZ_TEST_CONVERSATION_WAV to a two-voice recording")
        }

        let store = ModelStore()
        let directory = try await store.ensureAvailable(ModelCatalog.speakerDiarization)
        let diarizer = try PyannoteDiarizer.load(fromVerifiedDirectory: directory)

        // Feed the file the way a recording session does: ~0.5 s chunks at
        // the file's native rate.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 2)
        let maxFrames = AVAudioFramePosition(format.sampleRate * 240)
        let (stream, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        var elapsed: TimeInterval = 0
        while file.framePosition < min(file.length, maxFrames) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            else { break }
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            feed.yield(AudioChunk(
                channel: .system, samples: samples,
                sampleRate: format.sampleRate, timestamp: elapsed))
            elapsed += Double(buffer.frameLength) / format.sampleRate
        }
        feed.finish()

        var turns: [SpeakerTurn] = []
        for try await turn in diarizer.diarize(stream) {
            turns.append(turn)
        }

        XCTAssertFalse(turns.isEmpty)
        let voices = Set(turns.map(\.voiceLabel))
        XCTAssertGreaterThanOrEqual(voices.count, 2, "expected ≥2 live voices, got \(voices)")
        for turn in turns {
            XCTAssertLessThan(turn.startTime, turn.endTime)
        }
    }
}

final class MergeMicroClustersTests: XCTestCase {
    private func turn(
        _ label: String, _ start: TimeInterval, _ end: TimeInterval, quality: Double = 0.8
    ) -> SpeakerTurn {
        SpeakerTurn(voiceLabel: label, startTime: start, endTime: end, confidence: quality)
    }

    func testMicroClusterMovesToTemporallyNearestMajor() {
        let turns = [
            turn("S1", 0, 30),      // major (30 s)
            turn("S9", 31, 34),     // micro, right after S1
            turn("S2", 100, 140),   // major (40 s)
            turn("S8", 139, 143),   // micro, inside/after S2
        ]
        let merged = PyannoteDiarizer.mergeMicroClusters(turns)
        XCTAssertEqual(merged.map(\.voiceLabel), ["S1", "S1", "S2", "S2"])
        // Times and quality of the reassigned turns are untouched.
        XCTAssertEqual(merged[1].startTime, 31)
        XCTAssertEqual(merged[1].endTime, 34)
    }

    func testShortRealSpeakerSurvivesWhenNothingIsMajor() {
        // Nobody reaches 15 s: a short meeting, not fragmentation.
        let turns = [turn("S1", 0, 5), turn("S2", 6, 10)]
        let merged = PyannoteDiarizer.mergeMicroClusters(turns)
        XCTAssertEqual(merged.map(\.voiceLabel), ["S1", "S2"])
    }

    func testMeIsNeverAbsorbedEvenWhenTiny() {
        let turns = [
            turn("S1", 0, 60),
            turn("Me", 61, 63),  // 2 s of enrolled voice
        ]
        let merged = PyannoteDiarizer.mergeMicroClusters(turns)
        XCTAssertEqual(merged.map(\.voiceLabel), ["S1", "Me"])
    }

    func testMeNeverAbsorbsMicroClusters() {
        // The only major label is "Me": micro turns must NOT become "Me".
        let turns = [
            turn("Me", 0, 60),
            turn("S7", 61, 64),
        ]
        let merged = PyannoteDiarizer.mergeMicroClusters(turns)
        XCTAssertEqual(merged.map(\.voiceLabel), ["Me", "S7"])
    }

    func testAllMajorsPassThroughUntouched() {
        let turns = [turn("S1", 0, 30), turn("S2", 31, 60)]
        XCTAssertEqual(
            PyannoteDiarizer.mergeMicroClusters(turns).map(\.voiceLabel), ["S1", "S2"])
    }

    func testMultiTurnMicroLabelReassignsEachTurnIndependently() {
        let turns = [
            turn("S1", 0, 30),       // major
            turn("S2", 200, 240),    // major
            turn("S9", 28, 31),      // micro turn near S1
            turn("S9", 198, 201),    // micro turn near S2 (same label!)
        ]
        let merged = PyannoteDiarizer.mergeMicroClusters(turns)
        XCTAssertEqual(merged[2].voiceLabel, "S1")
        XCTAssertEqual(merged[3].voiceLabel, "S2")
    }
}
