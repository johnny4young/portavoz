import FluidAudio
import Foundation
import PortavozCore
@testable import TranscriptionKit

@testable import portavoz_app
import XCTest

final class DictationVendorProbeTests: XCTestCase {
    @MainActor
    func testRetiredEdgeWordMustNotSurviveInEitherConsumer() async throws {
        // Synthetic characterization of the native seam-retirement shape.
        // The public deltas omit the producer's removal of the previous word;
        // a later start is not evidence that the old word remains canonical.
        for (opening, fragment, replacement, ending, expected) in [
            ("▁We", "▁an", "▁analyzing", "▁now.", "We analyzing now."),
            ("▁Estamos", "▁anal", "▁analizando", "▁ahora.", "Estamos analizando ahora."),
        ] {
            // Same raw tokens/times/expected strings as the red fixture, now
            // carrying the producer's explicit retirement and terminal authority.
            var stream = ParakeetSegmentMapper.RevisionStream()
            let meetingID = MeetingID()
            let jobID = UUID()
            var rows: [TranscriptSegment] = []
            var projection = DictationTranscriptProjection()
            let recording = RecordingController()
            let raw = [
                [token(opening, 0, 0.2), token(fragment, 0.2, 0.4)],
                [token(replacement, 0.24, 0.6), token(ending, 0.6, 0.8)],
                []
            ]
            for (index, counts) in [(0, (0, 0, 1)), (1, (2, 1, 2)), (2, (3, 3, 3))] {
                let event = SlidingWindowTokenUpdate(tokens: raw[index], revision: .init(
                    jobID: jobID, ordinal: index + 1, previousTokenCount: counts.0,
                    retainedTokenCount: counts.1, stableTokenCount: counts.2,
                    window: 0..<38400, center: 0..<32000, isTerminal: index == 2))
                for segment in try stream.segments(
                    from: event, meetingID: meetingID, channel: .microphone, language: nil) {
                    CaptionCoalescer().apply(segment, to: &rows)
                    _ = projection.apply(segment)
                    recording.receiveLiveCaption(segment)
                }
                if index == 0 {
                    XCTAssertEqual(rows.map(\.text).joined(separator: " "), opening.replacingOccurrences(of: "▁", with: ""))
                    XCTAssertTrue(projection.partialText.contains(fragment.replacingOccurrences(of: "▁", with: "")))
                }
            }
            try stream.finish()
            XCTAssertEqual(rows.map(\.text).joined(separator: " "), expected)
            XCTAssertEqual(projection.finalText, expected)
            XCTAssertEqual(recording.captions.map(\.text).joined(separator: " "), expected)
            XCTAssertTrue(recording.speechVolatileByChannel.isEmpty)
            XCTAssertEqual(projection.partialText, projection.finalText)
        }
    }

    @MainActor
    func testProducerPreviewKeepsEqualTimeSubwordsAndSpokenRepetitions() async throws {
        var stream = ParakeetSegmentMapper.RevisionStream()
        let meetingID = MeetingID()
        let jobID = UUID()
        var rows: [TranscriptSegment] = []
        var projection = DictationTranscriptProjection()
        let recording = RecordingController()
        let first = SlidingWindowTokenUpdate(
            tokens: [token("▁va", 0, 0.1), token("mos", 0, 0.1), token("▁sí", 0.1, 0.2), token("▁sí", 0.1, 0.2)],
            revision: .init(jobID: jobID, ordinal: 1, previousTokenCount: 0, retainedTokenCount: 0,
                            stableTokenCount: 2, window: 0..<22400, center: 0..<16000, isTerminal: false))
        let terminal = SlidingWindowTokenUpdate(tokens: [], revision: .init(
            jobID: jobID, ordinal: 2, previousTokenCount: 4, retainedTokenCount: 4,
            stableTokenCount: 4, window: 0..<22400, center: 0..<16000, isTerminal: true))
        for event in [first, terminal] {
            for segment in try stream.segments(from: event, meetingID: meetingID, channel: .microphone, language: "es") {
                CaptionCoalescer().apply(segment, to: &rows)
                _ = projection.apply(segment)
                recording.receiveLiveCaption(segment)
            }
            XCTAssertEqual(projection.partialText, "vamos sí sí")
            if !event.revision.isTerminal { XCTAssertEqual(rows.map(\.text), ["vamos"]) }
        }
        try stream.finish()
        XCTAssertEqual(rows.map(\.text), ["vamos sí sí"])
        XCTAssertEqual(recording.captions.map(\.text), ["vamos sí sí"])
        XCTAssertEqual(projection.finalText, "vamos sí sí")
        XCTAssertTrue(recording.speechVolatileByChannel.isEmpty)
    }

    @MainActor
    func testEmptyRetirementClearsBothPreviewsWithoutPersistingText() async throws {
        var stream = ParakeetSegmentMapper.RevisionStream()
        let meeting = MeetingID()
        let job = UUID()
        var projection = DictationTranscriptProjection()
        let recording = RecordingController()
        var rows: [TranscriptSegment] = []
        for event in [
            tokenEvent([token("▁temporary", 0, 0.2)], job: job, ordinal: 1, previous: 0, retained: 0, stable: 0),
            tokenEvent([], job: job, ordinal: 2, previous: 1, retained: 0, stable: 0),
            tokenEvent([], job: job, ordinal: 3, previous: 0, retained: 0, stable: 0, terminal: true)
        ] {
            for segment in try stream.segments(from: event, meetingID: meeting, channel: .microphone, language: nil) {
                CaptionCoalescer().apply(segment, to: &rows)
                _ = projection.apply(segment)
                recording.receiveLiveCaption(segment)
            }
            if event.revision.ordinal == 1 {
                XCTAssertEqual(projection.partialText, "temporary")
                XCTAssertEqual(recording.speechVolatileByChannel.count, 1)
            } else {
                XCTAssertEqual(projection.partialText, "")
                XCTAssertTrue(recording.speechVolatileByChannel.isEmpty)
            }
            XCTAssertTrue(rows.isEmpty)
            XCTAssertTrue(recording.captions.isEmpty)
            XCTAssertEqual(projection.finalText, "")
        }
        try stream.finish()
    }

    func testRevisionJobMeetingAndChannelFailuresCannotMutateConsumer() throws {
        var stream = ParakeetSegmentMapper.RevisionStream()
        let meeting = MeetingID()
        let job = UUID()
        _ = try stream.segments(
            from: tokenEvent([token("▁word", 0, 0.2)], job: job, ordinal: 1, previous: 0, retained: 0, stable: 0),
            meetingID: meeting, channel: .microphone, language: nil)
        let terminal = tokenEvent([], job: job, ordinal: 2, previous: 1, retained: 1, stable: 1, terminal: true)
        for (id, channel) in [(MeetingID(), AudioChannel.microphone), (meeting, .system)] {
            XCTAssertThrowsError(try stream.segments(from: terminal, meetingID: id, channel: channel, language: nil))
        }
        let foreign = tokenEvent([], job: UUID(), ordinal: 2, previous: 1, retained: 1, stable: 1, terminal: true)
        XCTAssertThrowsError(try stream.segments(from: foreign, meetingID: meeting, channel: .microphone, language: nil))
        let final = try stream.segments(from: terminal, meetingID: meeting, channel: .microphone, language: nil)
        XCTAssertEqual(final.filter(\.isFinal).map(\.text), ["word"])
        try stream.finish()
    }

    @MainActor
    func testProducerFailureOrMissingTerminalClearsPreviewWithoutCommittingIt() async throws {
        enum Injected: Error { case model }
        for fails in [true, false] {
            let meeting = MeetingID()
            let job = UUID()
            let first = tokenEvent([token("▁stable", 0, 0.2), token("▁an", 0.2, 0.4)],
                                   job: job, ordinal: 1, previous: 0, retained: 0, stable: 1)
            let updates = AsyncThrowingStream<SlidingWindowTokenUpdate, Error> { output in
                output.yield(first)
                if fails { output.finish(throwing: Injected.model) } else { output.finish() }
            }
            let channel = ParakeetStreamChannel()
            try await channel.set(.microphone)
            let output = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
            do {
                try await ParakeetEngine.consume(updates, hints: .init(meetingID: meeting), channelHolder: channel,
                                                continuation: output.continuation, probe: nil)
                XCTFail("a failed or incomplete producer cannot succeed")
            } catch {
                if fails { XCTAssertTrue(error is Injected) }
                else { XCTAssertEqual(error as? ParakeetTokenRevisionReducer.Failure, .incompleteStream) }
            }
            output.continuation.finish()
            var projection = DictationTranscriptProjection()
            let recording = RecordingController()
            for try await segment in output.stream {
                _ = projection.apply(segment)
                recording.receiveLiveCaption(segment)
            }
            XCTAssertEqual(projection.finalText, "stable")
            XCTAssertEqual(projection.partialText, "stable")
            XCTAssertEqual(recording.captions.map(\.text), ["stable"])
            XCTAssertTrue(recording.speechVolatileByChannel.isEmpty)
        }
    }

    @MainActor
    func testUnboundEmptyJobCannotClearAnotherChannelsPreview() async throws {
        enum Injected: Error { case model }
        for fails in [false, true] {
            let terminal = tokenEvent([], job: UUID(), ordinal: 1,
                                      previous: 0, retained: 0, stable: 0, terminal: true)
            let updates = AsyncThrowingStream<SlidingWindowTokenUpdate, Error> { input in
                if fails {
                    input.finish(throwing: Injected.model)
                } else {
                    input.yield(terminal)
                    input.finish()
                }
            }
            let output = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
            do {
                try await ParakeetEngine.consume(
                    updates, hints: .init(), channelHolder: ParakeetStreamChannel(),
                    continuation: output.continuation, probe: nil)
                XCTAssertFalse(fails)
            } catch {
                XCTAssertTrue(fails)
                XCTAssertTrue(error is Injected)
            }
            output.continuation.finish()
            let recording = RecordingController()
            recording.receiveLiveCaption(TranscriptSegment(
                meetingID: MeetingID(), channel: .microphone, text: " pending",
                startTime: 0, endTime: 0.2, confidence: 1,
                isFinal: false, liveUpdateMode: .tokenPreview))
            var count = 0
            for try await segment in output.stream {
                count += 1
                recording.receiveLiveCaption(segment)
            }
            XCTAssertEqual(count, 0, "an unbound producer owns no channel to clear")
            XCTAssertEqual(recording.speechVolatileByChannel[.microphone]?.text, " pending")
        }
    }

    func testUnboundProducerCannotPublishTokensWithoutAdmittedPCM() async throws {
        let update = tokenEvent([token("▁word", 0, 0.2)], job: UUID(),
                                ordinal: 1, previous: 0, retained: 0, stable: 1)
        let updates = AsyncThrowingStream<SlidingWindowTokenUpdate, Error> { input in
            input.yield(update)
            input.finish()
        }
        let output = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        do {
            try await ParakeetEngine.consume(
                updates, hints: .init(), channelHolder: ParakeetStreamChannel(),
                continuation: output.continuation, probe: nil)
            XCTFail("native text without a capture source must fail closed")
        } catch ParakeetStreamChannel.Failure.unboundChannel { }
        output.continuation.finish()
        var count = 0
        for try await _ in output.stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    private func tokenEvent(
        _ tokens: [TokenTiming], job: UUID, ordinal: Int, previous: Int,
        retained: Int, stable: Int, terminal: Bool = false
    ) -> SlidingWindowTokenUpdate {
        .init(tokens: tokens, revision: .init(
            jobID: job, ordinal: ordinal, previousTokenCount: previous,
            retainedTokenCount: retained, stableTokenCount: stable,
            window: 0..<38400, center: 0..<32000, isTerminal: terminal))
    }

    @MainActor
    func testLiteralConsumerParityIsContentFreeAndCannotChangeSharedReceiptSchema() async throws {
        let stable = TranscriptSegment(
            meetingID: MeetingID(), channel: .microphone, text: "Synthetic phrase", startTime: 0, endTime: 1,
            confidence: 1, isFinal: true, liveUpdateMode: .tokenDelta)
        var preview = stable
        preview.text = " unfinished"
        preview.isFinal = false
        preview.liveUpdateMode = .tokenPreview
        var clear = preview
        clear.text = ""
        let segments = [stable, preview, clear]
        let parity = DictationVendorProbe.consumerParity(
            for: segments, nativeText: "Synthetic phrase", productionText: "Synthetic phrase")
        XCTAssertEqual(parity, .init(nativeMatchesProduction: true, dictationMatchesNative: true,
                                    meetingMatchesNative: true, previewsCleared: true))
        let mismatch = DictationVendorProbe.consumerParity(for: segments, nativeText: "different", productionText: "Synthetic phrase")
        XCTAssertFalse(mismatch.nativeMatchesProduction)
        XCTAssertFalse(mismatch.dictationMatchesNative)
        XCTAssertFalse(mismatch.meetingMatchesNative)
        let parityJSON = String(decoding: try JSONEncoder().encode(parity), as: UTF8.self)
        XCTAssertFalse(parityJSON.contains("Synthetic"))
        XCTAssertFalse(parityJSON.contains("unfinished"))
        let score = try DictationModelProbe.score(
            hypothesis: "Synthetic phrase", legacyCleanedText: "Synthetic phrase", references: ["Synthetic phrase"])
        let receipt = DictationVendorProbe.Receipt(
            vendorFinal: score, mappedAndCoalesced: score, matchesProductionText: true,
            updateCount: 1, timingCount: 2, rejectedAtBoundary: 0, rejectedBeforeBoundary: 0,
            mappedSegmentCount: 1, consumerParity: parity)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["vendorFinal", "mappedAndCoalesced", "matchesProductionText", "updateCount",
                                         "timingCount", "rejectedAtBoundary", "rejectedBeforeBoundary", "mappedSegmentCount"])
    }

    // The public update sequence must retain every newly owned token.
    func testAttributionRetainsTokensAtZeroAndAtPreviousEnd() throws {
        var reduction = DictationVendorProbe.Reduction()
        let first = try reduction.apply(update([
            token("▁Do", 0, 0.2), token("▁not", 0.2, 0.4), token("▁pay", 0.4, 0.6)
        ]))
        XCTAssertEqual(first?.text, "Do not pay")
        let second = try reduction.apply(update([
            token("▁pay", 0.4, 0.6), token("▁today", 0.6, 0.8), token(".", 0.8, 1)
        ]))
        XCTAssertEqual(second?.text, "today.")
        XCTAssertEqual(reduction.timingCount, 6)
        XCTAssertEqual(reduction.rejectedAtBoundary, 1)
        XCTAssertEqual(reduction.rejectedBeforeBoundary, 0)
        XCTAssertEqual(reduction.mappedSegmentCount, 2)
    }

    func testAttributionCountsDiscardedUpdateWithoutAdvancingItsEdge() throws {
        var reduction = DictationVendorProbe.Reduction()
        _ = try reduction.apply(update([token("▁hola", 0.1, 0.5)]))
        XCTAssertNil(try reduction.apply(update([token("▁hola", 0.1, 0.5)])))
        XCTAssertEqual(reduction.edge, 0.5)
        XCTAssertEqual(reduction.mappedSegmentCount, 1)
        XCTAssertEqual(reduction.updateCount, 2)
    }

    @MainActor
    func testEqualTimeSubwordsAndLiteralRepetitionReachBothConsumers() async throws {
        var reduction = DictationVendorProbe.Reduction()
        var rows: [TranscriptSegment] = []
        var projection = DictationTranscriptProjection()
        let coalescer = CaptionCoalescer()
        let recording = RecordingController()
        let updates = [
            update([token("▁very", 0, 0.2)]),
            update([token("▁very", 0, 0.2), token("▁very", 0.2, 0.4)]),
            update([token("▁good", 0.4, 0.5), token("▁meet", 0.5, 0.6)]),
            update([token("▁meet", 0.5, 0.6), token("ing", 0.5, 0.6)]),
            update([token(".", 0.6, 0.7)]),
        ]
        for input in updates {
            if let segment = try reduction.apply(input) {
                coalescer.apply(segment, to: &rows)
                _ = projection.apply(segment)
                recording.receiveLiveCaption(segment)
            }
        }
        XCTAssertEqual(rows.map(\.text).joined(separator: " "), "very very good meeting.")
        XCTAssertEqual(projection.finalText, "very very good meeting.")
        XCTAssertEqual(recording.captions.map(\.text), ["very very good meeting."])
    }

    @MainActor
    func testReplayBeyondLeftContextDoesNotEatRepeatedSpeech() async throws {
        var reduction = DictationVendorProbe.Reduction()
        var rows: [TranscriptSegment] = []
        var projection = DictationTranscriptProjection()
        let coalescer = CaptionCoalescer(maxRowCharacters: 10_000)
        let recording = RecordingController()
        for second in 0..<40 {
            let context = (max(0, second - 11)...second).map {
                token("▁sí", Double($0), Double($0) + 0.08)
            }
            let segment = try XCTUnwrap(reduction.apply(update(context)))
            XCTAssertEqual(segment.text, "sí")
            coalescer.apply(segment, to: &rows)
            _ = projection.apply(segment)
            recording.receiveLiveCaption(segment)
            XCTAssertNil(try reduction.apply(update(context)))
        }
        let expected = Array(repeating: "sí", count: 40).joined(separator: " ")
        XCTAssertEqual(rows.map(\.text).joined(separator: " "), expected)
        XCTAssertEqual(projection.finalText, expected)
        XCTAssertEqual(recording.captions.map(\.text).joined(separator: " "), expected)
        XCTAssertEqual(reduction.mappedSegmentCount, 40)
    }

    func testEqualTimeTokenMultiplicityAndIndependentSessions() throws {
        var first = DictationVendorProbe.Reduction()
        var second = DictationVendorProbe.Reduction()
        let one = update([token("▁no", 0, 0.08)])
        let repeated = update([token("▁no", 0, 0.08), token("▁no", 0, 0.08)])
        let opening = try XCTUnwrap(first.apply(one))
        XCTAssertEqual(try first.apply(repeated)?.text, "no")
        XCTAssertNil(try first.apply(repeated))
        let restarted = try XCTUnwrap(second.apply(one))
        XCTAssertEqual(restarted.text, "no")
        XCTAssertNotEqual(opening.meetingID, restarted.meetingID)
    }

    func testNewlyOwnedRepeatedWordIsNotACharacterOverlap() throws {
        var reduction = DictationVendorProbe.Reduction()
        var rows: [TranscriptSegment] = []
        var projection = DictationTranscriptProjection()
        for input in [update([token("▁very", 1, 1.1)]), update([token("▁very", 1.2, 1.3)])] {
            let segment = try XCTUnwrap(reduction.apply(input))
            CaptionCoalescer().apply(segment, to: &rows)
            _ = projection.apply(segment)
        }
        XCTAssertEqual(rows.map(\.text), ["very very"])
        XCTAssertEqual(projection.finalText, "very very")
    }

    @MainActor
    func testMeetingAndDictationRetainHighConfidenceSingleLetterAndNumericTokens() async throws {
        var reduction = DictationVendorProbe.Reduction()
        let recording = RecordingController()
        var projection = DictationTranscriptProjection()
        for (index, piece) in ["▁I", "▁agree", ",", "▁2", "▁€", "."].enumerated() {
            let start = Double(index) * 0.2
            let segment = try XCTUnwrap(reduction.apply(update([token(piece, start, start + 0.2)])))
            recording.receiveLiveCaption(segment)
            _ = projection.apply(segment)
        }
        XCTAssertEqual(recording.captions.map(\.text), ["I agree, 2 €."])
        XCTAssertEqual(projection.finalText, "I agree, 2 €.")
    }

    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 1, startTime: start, endTime: end, confidence: 1)
    }

    private func update(_ tokens: [TokenTiming]) -> SlidingWindowTranscriptionUpdate {
        SlidingWindowTranscriptionUpdate(
            text: "synthetic update", isConfirmed: false, confidence: 1, timestamp: Date(timeIntervalSince1970: 0),
            tokenIds: tokens.map(\.tokenId), tokenTimings: tokens)
    }
}
