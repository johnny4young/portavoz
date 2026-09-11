import ApplicationKit
import PortavozCore
import XCTest

final class RetrievalConversationWindowChunkingTests: XCTestCase {
    func testWindowKeepsAlternatingTurnsAndExactActorBoundaries() throws {
        let meetingID = meeting(1)
        let firstSpeaker = speaker(10, meetingID: meetingID)
        let secondSpeaker = speaker(20, meetingID: meetingID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "What ships", start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "on Friday?", start: 1.1, end: 2),
            segment(
                3, meetingID: meetingID, speakerID: secondSpeaker.id,
                text: "The local search candidate", start: 2.1, end: 3),
            segment(
                4, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "Please keep citations exact", start: 3.1, end: 4)
        ]

        let chunks = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 7,
            correctionRevision: .accepted,
            segments: segments,
            speakers: [secondSpeaker, firstSpeaker])

        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunk.chunkerVersion, "conversation-window-v1")
        XCTAssertEqual(chunk.sourceSegmentIDs, segments.map(\.id))
        XCTAssertEqual(chunk.turns.map(\.sourceSegmentIDs), [
            [segments[0].id, segments[1].id],
            [segments[2].id],
            [segments[3].id]
        ])
        XCTAssertEqual(chunk.turns.map(\.speakerIDs), [
            [firstSpeaker.id],
            [secondSpeaker.id],
            [firstSpeaker.id]
        ])
        XCTAssertEqual(chunk.speakerIDs, [firstSpeaker.id, secondSpeaker.id])
        XCTAssertEqual(
            chunk.text,
            "What ships on Friday? The local search candidate "
                + "Please keep citations exact")
    }

    func testWindowsAreNonOverlappingAndBoundedToThreeTurns() throws {
        let meetingID = meeting(2)
        let firstSpeaker = speaker(10, meetingID: meetingID)
        let secondSpeaker = speaker(20, meetingID: meetingID)
        let segments = (0..<4).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: index.isMultiple(of: 2)
                    ? firstSpeaker.id
                    : secondSpeaker.id,
                text: "turn \(index + 1)",
                start: Double(index),
                end: Double(index) + 0.8)
        }

        let chunks = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: segments,
            speakers: [firstSpeaker, secondSpeaker])

        XCTAssertEqual(chunks.map(\.sourceSegmentIDs), [
            Array(segments[0...2]).map(\.id),
            [segments[3].id]
        ])
        XCTAssertEqual(chunks.map(\.turns.count), [3, 1])
        let publishedSources = chunks.flatMap(\.sourceSegmentIDs)
        XCTAssertEqual(publishedSources, segments.map(\.id))
        XCTAssertEqual(Set(publishedSources).count, segments.count)
    }

    func testWindowUsesTheSingleTurnResourceCeiling() throws {
        let meetingID = meeting(3)
        let firstSpeaker = speaker(10, meetingID: meetingID)
        let secondSpeaker = speaker(20, meetingID: meetingID)
        let longText = String(repeating: "a", count: 500)
        let dense = [
            segment(
                1, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: longText, start: 0, end: 1),
            segment(
                2, meetingID: meetingID, speakerID: secondSpeaker.id,
                text: longText, start: 1.1, end: 2)
        ]

        let denseChunks = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: dense,
            speakers: [firstSpeaker, secondSpeaker])

        XCTAssertEqual(
            RetrievalConversationWindowChunker.maximumCharacters,
            RetrievalTurnChunker.maximumCharacters)
        XCTAssertEqual(
            RetrievalConversationWindowChunker.maximumDuration,
            RetrievalTurnChunker.maximumDuration)
        XCTAssertEqual(
            RetrievalConversationWindowChunker.maximumGap,
            RetrievalTurnChunker.maximumGap)
        XCTAssertEqual(denseChunks.map(\.sourceSegmentIDs), dense.map { [$0.id] })

        let delayed = [
            segment(
                3, meetingID: meetingID, speakerID: firstSpeaker.id,
                text: "before pause", start: 10, end: 11),
            segment(
                4, meetingID: meetingID, speakerID: secondSpeaker.id,
                text: "after pause", start: 14, end: 15)
        ]
        let delayedChunks = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: delayed,
            speakers: [firstSpeaker, secondSpeaker])
        XCTAssertEqual(delayedChunks.map(\.sourceSegmentIDs), delayed.map { [$0.id] })
    }

    func testOversizedCanonicalTurnRemainsIndivisibleAndIsolated() throws {
        let meetingID = meeting(9)
        let firstSpeaker = speaker(50, meetingID: meetingID)
        let secondSpeaker = speaker(60, meetingID: meetingID)
        let oversized = segment(
            1,
            meetingID: meetingID,
            speakerID: firstSpeaker.id,
            text: String(repeating: "x", count: 950),
            start: 0,
            end: 60)
        let reply = segment(
            2,
            meetingID: meetingID,
            speakerID: secondSpeaker.id,
            text: "bounded reply",
            start: 60.1,
            end: 61)

        let chunks = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: [oversized, reply],
            speakers: [firstSpeaker, secondSpeaker])

        XCTAssertEqual(chunks.map(\.sourceSegmentIDs), [[oversized.id], [reply.id]])
        XCTAssertGreaterThan(
            chunks[0].text.count,
            RetrievalConversationWindowChunker.maximumCharacters)
        XCTAssertGreaterThan(
            chunks[0].endTime - chunks[0].startTime,
            RetrievalConversationWindowChunker.maximumDuration)
    }

    func testAnonymousRemoteRowsCanShareContextWithoutInventingASpeaker() throws {
        let meetingID = meeting(4)
        let segments = [
            segment(
                1, meetingID: meetingID,
                text: "unattributed question", start: 0, end: 1),
            segment(
                2, meetingID: meetingID,
                text: "unattributed response", start: 1.1, end: 2)
        ]

        let chunk = try XCTUnwrap(RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: segments,
            speakers: []).first)

        XCTAssertEqual(chunk.turns.count, 2)
        XCTAssertEqual(chunk.turns.map(\.sourceSegmentIDs), segments.map { [$0.id] })
        XCTAssertTrue(chunk.speakerIDs.isEmpty)
        XCTAssertTrue(chunk.personIDs.isEmpty)
    }

    func testTextCorrectionInvalidatesOnlyItsNonOverlappingWindow() throws {
        let meetingID = meeting(5)
        let speakers = (0..<4).map {
            speaker(10 + $0, meetingID: meetingID)
        }
        let original = (0..<4).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: speakers[index].id,
                text: "evidence \(index + 1)",
                start: Double(index),
                end: Double(index) + 0.8)
        }
        var corrected = original
        corrected[3].text = "corrected evidence 4"

        let previous = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 3,
            correctionRevision: .accepted,
            segments: original,
            speakers: speakers)
        let currentRevision = correction(1)
        let current = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 3,
            correctionRevision: currentRevision,
            segments: corrected,
            speakers: speakers)
        let delta = RetrievalChunkDelta.between(
            previous: previous,
            current: current)

        XCTAssertEqual(delta.retained.map(\.sourceSegmentIDs), [
            Array(original[0...2]).map(\.id)
        ])
        XCTAssertEqual(delta.upserts.map(\.sourceSegmentIDs), [[original[3].id]])
        XCTAssertEqual(delta.retained[0].correctionRevision, currentRevision)
        XCTAssertTrue(delta.removedChunkIDs.isEmpty)
    }

    func testTextCorrectionCrossingResourceCeilingMayReflowLaterWindows() throws {
        let meetingID = meeting(8)
        let speakers = (0..<4).map {
            speaker(40 + $0, meetingID: meetingID)
        }
        let original = (0..<4).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: speakers[index].id,
                text: "turn \(index + 1)",
                start: Double(index),
                end: Double(index) + 0.4)
        }
        var corrected = original
        corrected[1].text = String(repeating: "x", count: 895)

        let previous = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: original,
            speakers: speakers)
        let current = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: correction(3),
            segments: corrected,
            speakers: speakers)

        XCTAssertEqual(previous.map(\.turns.count), [3, 1])
        XCTAssertEqual(current.map(\.turns.count), [1, 1, 2])
        XCTAssertEqual(
            current.flatMap(\.sourceSegmentIDs),
            corrected.map(\.id))
        XCTAssertEqual(
            Set(current.flatMap(\.sourceSegmentIDs)).count,
            corrected.count)
    }

    func testTopologyChangeMayReflowWindowsButKeepsSourcesCanonical() throws {
        let meetingID = meeting(7)
        let speakers = (0..<7).map {
            speaker(30 + $0, meetingID: meetingID)
        }
        let original = (0..<6).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: speakers[index].id,
                text: "turn \(index + 1)",
                start: Double(index),
                end: Double(index) + 0.4)
        }
        let inserted = segment(
            100,
            meetingID: meetingID,
            speakerID: speakers[6].id,
            text: "inserted split turn",
            start: 0.5,
            end: 0.8)
        let currentSources = [original[0], inserted] + original.dropFirst()

        let previous = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: original,
            speakers: speakers)
        let current = try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: correction(2),
            segments: Array(currentSources),
            speakers: speakers)
        let delta = RetrievalChunkDelta.between(
            previous: previous,
            current: current)

        XCTAssertEqual(previous.map(\.turns.count), [3, 3])
        XCTAssertEqual(current.map(\.turns.count), [3, 3, 1])
        XCTAssertEqual(
            current.flatMap(\.sourceSegmentIDs),
            currentSources.map(\.id))
        XCTAssertEqual(
            Set(current.flatMap(\.sourceSegmentIDs)).count,
            currentSources.count)
        XCTAssertEqual(delta.removedChunkIDs.count, 2)
        XCTAssertEqual(delta.upserts.count, 3)
    }

    func testWindowDelegatesFailClosedSourceValidation() throws {
        let meetingID = meeting(6)
        let source = segment(
            1, meetingID: meetingID,
            text: "evidence", start: 0, end: 1)

        XCTAssertThrowsError(try RetrievalConversationWindowChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .unavailable,
            segments: [source],
            speakers: [])) { error in
                XCTAssertEqual(
                    error as? RetrievalChunkingError,
                    .invalidCorrectionRevision)
        }
    }

    private func segment(
        _ value: Int,
        meetingID: MeetingID,
        speakerID: SpeakerID? = nil,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: uuid(value),
            meetingID: meetingID,
            speakerID: speakerID,
            channel: .system,
            text: text,
            language: "en",
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    private func speaker(_ value: Int, meetingID: MeetingID) -> Speaker {
        Speaker(
            id: SpeakerID(rawValue: uuid(20_000 + value)),
            meetingID: meetingID,
            label: "S\(value)")
    }

    private func meeting(_ value: Int) -> MeetingID {
        MeetingID(rawValue: uuid(10_000 + value))
    }

    private func correction(_ value: Int) -> TranscriptCorrectionRevision {
        TranscriptCorrectionRevision(rawValue: String(format: "%064x", value))!
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
