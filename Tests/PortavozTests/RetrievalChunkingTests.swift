import ApplicationKit
import PortavozCore
import XCTest

final class RetrievalChunkingTests: XCTestCase {
    func testSingleTurnChunksNeverCrossObservedActors() throws {
        let meetingID = meeting(1)
        let firstSpeaker = speaker(10, meetingID: meetingID)
        let secondSpeaker = speaker(20, meetingID: meetingID)
        let first = segment(
            1, meetingID: meetingID, speakerID: firstSpeaker.id,
            text: "The rollout starts", start: 0, end: 1)
        let continuation = segment(
            2, meetingID: meetingID, speakerID: firstSpeaker.id,
            text: "on Friday", start: 1.2, end: 2)
        let reply = segment(
            3, meetingID: meetingID, speakerID: secondSpeaker.id,
            text: "I can own it", start: 2.1, end: 3)
        let laterTurn = segment(
            4, meetingID: meetingID, speakerID: firstSpeaker.id,
            text: "Thank you", start: 3.1, end: 4)

        let chunks = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 7,
            segments: [laterTurn, continuation, reply, first],
            speakers: [secondSpeaker, firstSpeaker])

        XCTAssertEqual(chunks.map(\.sourceSegmentIDs), [
            [first.id, continuation.id],
            [reply.id],
            [laterTurn.id]
        ])
        XCTAssertEqual(chunks.map(\.text), [
            "The rollout starts on Friday",
            "I can own it",
            "Thank you"
        ])
        XCTAssertEqual(chunks.map(\.speakerIDs), [
            [firstSpeaker.id],
            [secondSpeaker.id],
            [firstSpeaker.id]
        ])
    }

    func testConfirmedPersonCanUnifyAdjacentObservedSpeakerLabels() throws {
        let meetingID = meeting(2)
        let personID = person(99)
        let firstSpeaker = speaker(10, meetingID: meetingID, personID: personID)
        let secondSpeaker = speaker(20, meetingID: meetingID, personID: personID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "primera parte", language: "es-CO", start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: secondSpeaker.id,
                text: "segunda parte", language: "es", start: 1.1, end: 2)
        ]

        let chunks = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: segments,
            speakers: [firstSpeaker, secondSpeaker])

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].speakerIDs, [firstSpeaker.id, secondSpeaker.id])
        XCTAssertEqual(chunks[0].personIDs, [personID])
        XCTAssertEqual(chunks[0].spokenLanguages, ["es-co", "es"])
    }

    func testAnonymousRemoteRowsStayIsolatedButMicrophoneRowsShareHardwareIdentity() throws {
        let meetingID = meeting(3)
        let segments = [
            segment(
                1, meetingID: meetingID, channel: .system,
                text: "remote one", start: 0, end: 1),
            segment(
                2, meetingID: meetingID, channel: .system,
                text: "remote two", start: 1.1, end: 2),
            segment(
                3, meetingID: meetingID, channel: .microphone,
                text: "my first part", start: 2.1, end: 3),
            segment(
                4, meetingID: meetingID, channel: .microphone,
                text: "my second part", start: 3.1, end: 4)
        ]

        let chunks = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: segments,
            speakers: [])

        XCTAssertEqual(chunks.map(\.sourceSegmentIDs), [
            [segments[0].id],
            [segments[1].id],
            [segments[2].id, segments[3].id]
        ])
    }

    func testMixedLanguageTurnPreservesPerSourceLanguageAndSpokenText() throws {
        let meetingID = meeting(4)
        let observedSpeaker = speaker(10, meetingID: meetingID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: "We ship Friday", language: "en-US", start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: "y revisamos el lunes", language: "es_CO", start: 1.1, end: 2)
        ]

        let chunk = try XCTUnwrap(RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 2,
            segments: segments,
            speakers: [observedSpeaker]).first)

        XCTAssertEqual(chunk.text, "We ship Friday y revisamos el lunes")
        XCTAssertEqual(chunk.sources.map(\.language), ["en-us", "es-co"])
        XCTAssertEqual(chunk.spokenLanguages, ["en-us", "es-co"])
    }

    func testTurnBoundsSplitLongDenseAndDistantSpeech() throws {
        let meetingID = meeting(5)
        let observedSpeaker = speaker(10, meetingID: meetingID)
        let denseText = String(repeating: "a", count: 500)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: denseText, start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: denseText, start: 1.1, end: 2),
            segment(
                3, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: "after a pause", start: 5, end: 6),
            segment(
                4, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: "after a long turn", start: 50, end: 51)
        ]

        let chunks = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: segments,
            speakers: [observedSpeaker])

        XCTAssertEqual(chunks.map(\.sourceSegmentIDs), segments.map { [$0.id] })
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= RetrievalTurnChunker.maximumCharacters })
    }

    func testTextNormalizationAvoidsRepresentationOnlyRebuilds() throws {
        let meetingID = meeting(6)
        let observedSpeaker = speaker(10, meetingID: meetingID)
        let composed = "café   listo"
        let decomposed = "cafe\u{301}\nlisto"

        let first = try chunks(
            meetingID: meetingID,
            revision: 1,
            text: composed,
            speaker: observedSpeaker)
        let second = try chunks(
            meetingID: meetingID,
            revision: 2,
            text: decomposed,
            speaker: observedSpeaker)
        let delta = RetrievalChunkDelta.between(previous: first, current: second)

        XCTAssertEqual(first[0].id, second[0].id)
        XCTAssertEqual(
            first[0].normalizedTextFingerprint,
            second[0].normalizedTextFingerprint)
        XCTAssertEqual(delta.retained, second)
        XCTAssertTrue(delta.upserts.isEmpty)
        XCTAssertTrue(delta.removedChunkIDs.isEmpty)
    }

    func testCorrectionInvalidatesOnlyItsOverlappingChunk() throws {
        let meetingID = meeting(7)
        let firstSpeaker = speaker(10, meetingID: meetingID)
        let secondSpeaker = speaker(20, meetingID: meetingID)
        let original = [
            segment(
                1, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "alpha one", start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "alpha two", start: 1.1, end: 2),
            segment(
                3, meetingID: meetingID, speakerID: secondSpeaker.id,
                text: "hola provando", language: "es", start: 2.1, end: 3),
            segment(
                4, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "alpha returns", start: 3.1, end: 4)
        ]
        var corrected = original
        corrected[2].text = "hola probando"

        let previous = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 4,
            segments: original,
            speakers: [firstSpeaker, secondSpeaker])
        let current = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 5,
            segments: corrected,
            speakers: [firstSpeaker, secondSpeaker])
        let delta = RetrievalChunkDelta.between(previous: previous, current: current)

        XCTAssertEqual(previous.map(\.id), current.map(\.id))
        XCTAssertEqual(delta.upserts.map(\.sourceSegmentIDs), [[original[2].id]])
        XCTAssertEqual(delta.retained.map(\.sourceSegmentIDs), [
            [original[0].id, original[1].id],
            [original[3].id]
        ])
        XCTAssertTrue(delta.removedChunkIDs.isEmpty)
        XCTAssertTrue(delta.retained.allSatisfy { $0.transcriptRevision == 5 })
    }

    func testMovingWordsBetweenStableSourcesStillInvalidatesTheChunk() throws {
        let meetingID = meeting(11)
        let observedSpeaker = speaker(10, meetingID: meetingID)
        let original = [
            segment(
                1, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: "alpha", start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: observedSpeaker.id,
                text: "beta gamma", start: 1.1, end: 2)
        ]
        var redistributed = original
        redistributed[0].text = "alpha beta"
        redistributed[1].text = "gamma"

        let previous = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: original,
            speakers: [observedSpeaker])
        let current = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 2,
            segments: redistributed,
            speakers: [observedSpeaker])
        let delta = RetrievalChunkDelta.between(previous: previous, current: current)

        XCTAssertEqual(previous[0].id, current[0].id)
        XCTAssertEqual(previous[0].text, current[0].text)
        XCTAssertNotEqual(previous[0].sourceFingerprint, current[0].sourceFingerprint)
        XCTAssertEqual(delta.upserts, current)
        XCTAssertTrue(delta.retained.isEmpty)
    }

    func testReplacingASourceRemovesOldChunkAndAddsNewChunk() throws {
        let meetingID = meeting(8)
        let observedSpeaker = speaker(10, meetingID: meetingID)
        let oldSegment = segment(
            1, meetingID: meetingID, speakerID: observedSpeaker.id,
            text: "old evidence", start: 0, end: 1)
        let replacement = segment(
            2, meetingID: meetingID, speakerID: observedSpeaker.id,
            text: "new evidence", start: 0, end: 1)
        let previous = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: [oldSegment],
            speakers: [observedSpeaker])
        let current = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 2,
            segments: [replacement],
            speakers: [observedSpeaker])

        let delta = RetrievalChunkDelta.between(previous: previous, current: current)

        XCTAssertEqual(delta.upserts, current)
        XCTAssertEqual(delta.removedChunkIDs, [previous[0].id])
        XCTAssertTrue(delta.retained.isEmpty)
    }

    func testValidationRejectsAmbiguousAggregateEvidence() throws {
        let meetingID = meeting(9)
        let otherMeetingID = meeting(10)
        let observedSpeaker = speaker(10, meetingID: meetingID)
        let source = segment(
            1, meetingID: meetingID, speakerID: observedSpeaker.id,
            text: "valid", start: 0, end: 1)

        XCTAssertThrowsError(try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: -1,
            segments: [source],
            speakers: [observedSpeaker])) { error in
                XCTAssertEqual(error as? RetrievalChunkingError, .invalidTranscriptRevision)
        }
        XCTAssertThrowsError(try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: [source, source],
            speakers: [observedSpeaker])) { error in
                XCTAssertEqual(error as? RetrievalChunkingError, .duplicateSegmentID(source.id))
        }
        XCTAssertThrowsError(try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: [source],
            speakers: [observedSpeaker, observedSpeaker])) { error in
                XCTAssertEqual(
                    error as? RetrievalChunkingError,
                    .duplicateSpeakerID(observedSpeaker.id))
        }
        let mixed = segment(
            2, meetingID: otherMeetingID,
            text: "wrong meeting", start: 0, end: 1)
        XCTAssertThrowsError(try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: [mixed],
            speakers: [observedSpeaker])) { error in
                XCTAssertEqual(error as? RetrievalChunkingError, .mixedMeeting)
        }
        let unknown = segment(
            3, meetingID: meetingID, speakerID: speaker(77),
            text: "unknown", start: 0, end: 1)
        XCTAssertThrowsError(try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: [unknown],
            speakers: [observedSpeaker])) { error in
                XCTAssertEqual(error as? RetrievalChunkingError, .unknownSpeaker(unknown.id))
        }
        let invalidTime = segment(
            4, meetingID: meetingID,
            text: "invalid", start: 2, end: 1)
        XCTAssertThrowsError(try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            segments: [invalidTime],
            speakers: [])) { error in
                XCTAssertEqual(error as? RetrievalChunkingError, .invalidTimeline(invalidTime.id))
        }
    }

    private func chunks(
        meetingID: MeetingID,
        revision: Int,
        text: String,
        speaker: Speaker
    ) throws -> [RetrievalChunk] {
        try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: revision,
            segments: [segment(
                1, meetingID: meetingID, speakerID: speaker.id,
                text: text, start: 0, end: 1)],
            speakers: [speaker])
    }

    private func segment(
        _ value: Int,
        meetingID: MeetingID,
        speakerID: SpeakerID? = nil,
        channel: AudioChannel = .system,
        text: String,
        language: String? = "en",
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: uuid(value),
            meetingID: meetingID,
            speakerID: speakerID,
            channel: channel,
            text: text,
            language: language,
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    private func speaker(
        _ value: Int,
        meetingID: MeetingID,
        personID: PersonID? = nil
    ) -> Speaker {
        Speaker(
            id: speaker(value),
            meetingID: meetingID,
            label: "S\(value)",
            personID: personID)
    }

    private func meeting(_ value: Int) -> MeetingID {
        MeetingID(rawValue: uuid(10_000 + value))
    }

    private func speaker(_ value: Int) -> SpeakerID {
        SpeakerID(rawValue: uuid(20_000 + value))
    }

    private func person(_ value: Int) -> PersonID {
        PersonID(rawValue: uuid(30_000 + value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
