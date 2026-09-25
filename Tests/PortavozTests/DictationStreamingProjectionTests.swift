import CryptoKit
import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationStreamingProjectionTests: XCTestCase {
    func testBilingualDeltasKeepPunctuationBoundariesAndFinalRules() async throws {
        let cases = [
            ("Don’t delete", "these notes", "The total is 1,250.50", "USD", "Done"),
            ("No borres", "estas notas", "El total es 1.250,50", "€", "Listo"),
        ]
        for (opening, continuation, total, currency, ending) in cases {
            let fixture = StreamingDictationFixture()
            defer { fixture.cancel() }
            fixture.harness.set(false, forKey: DictationController.fillerFilterKey)
            fixture.harness.set(
                #"[{"trigger":"C++","replacement":"Swift $5\\path"}]"#,
                forKey: DictationController.replacementsKey)
            fixture.start()
            try await fixture.waitForEngine()
            fixture.emit("", at: 0)
            fixture.emit("…", at: 0)
            fixture.emit("  " + opening + "  ", at: 0)
            try await fixture.expect(confirmed: "", partial: opening)
            fixture.emit(continuation, at: 0.5)
            fixture.emit(".", at: 0.8)
            let first = opening + " " + continuation + "."
            try await fixture.expect(confirmed: "", partial: first)
            fixture.emit(total, at: 8)
            try await fixture.expect(confirmed: first, partial: total)
            fixture.emit("DDDDDDDD", at: 8.2)
            fixture.emit(currency + " C++", at: 8.5)
            fixture.emit("!", at: 8.8)
            let second = total + " " + currency + " C++!"
            try await fixture.expect(confirmed: first, partial: second)
            fixture.emit(ending, at: 16)
            try await fixture.expect(confirmed: first + " " + second, partial: ending)
            try await fixture.finish()
            XCTAssertEqual(fixture.harness.insertions, [
                first + " " + total + " " + currency + " Swift $5\\path! " + ending,
            ])
        }
    }

    func testDelayedRemoteReplacementCanReopenThePreviouslyClosedRow() async throws {
        for (remote, echo) in [
            ("Previous remote statement", "Please record tomorrow’s deadline"),
            ("Una intervención anterior", "Conserva las notas del miércoles"),
        ] {
            let fixture = StreamingDictationFixture()
            defer { fixture.cancel() }
            fixture.start()
            try await fixture.waitForEngine()
            fixture.emit(remote, at: 0, channel: .system)
            try await fixture.expect(confirmed: "", partial: remote)
            fixture.emit(echo, at: 1.2)
            try await fixture.expect(confirmed: remote, partial: echo)
            fixture.emit(echo, at: 1.3, channel: .system)
            // Removal of the open microphone echo exposes the previous remote
            // row; the current coalescer extends it, reducing the row count.
            try await fixture.expect(confirmed: "", partial: remote + " " + echo)
            fixture.emit("Final marker", at: 10, channel: .room)
            try await fixture.expect(confirmed: remote + " " + echo, partial: "Final marker")
            try await fixture.finish()
            XCTAssertEqual(fixture.harness.insertions, [remote + " " + echo + " Final marker"])
        }
    }

    func testLengthBoundaryDelayedArrivalAndCancelledSessionCannotLoseOrLeakText() async throws {
        for length in [279, 280, 281] {
            let fixture = StreamingDictationFixture()
            defer { fixture.cancel() }
            fixture.start()
            try await fixture.waitForEngine()
            let row = String(String(repeating: "Café mañana unicode ", count: 20).prefix(length))
                .replacingOccurrences(of: " ", with: "·")
            fixture.emit(row, at: 10)
            fixture.emit("next", at: 11)
            let prefix = length < 280 ? "" : row
            let tail = length < 280 ? row + " next" : "next"
            try await fixture.expect(confirmed: prefix, partial: tail)
            fixture.emit("Older callback", at: 0)
            try await fixture.expect(confirmed: row + " next", partial: "Older callback")
            fixture.cancel()
            XCTAssertEqual(fixture.harness.controller.confirmedText, "", "Cancel clears text before teardown")
            XCTAssertEqual(fixture.harness.controller.partialText, "", "Cancel clears text before teardown")
            try await fixture.waitUntil { fixture.harness.finishes == 1 }
            XCTAssertTrue(fixture.harness.insertions.isEmpty)
            XCTAssertEqual(fixture.harness.controller.confirmedText, "")
            XCTAssertEqual(fixture.harness.controller.partialText, "")
        }
    }

    func testOldStreamCompletionCannotOverwriteAnImmediatelyRestartedSession() async throws {
        let harness = DictationControllerHarness(text: "unused")
        let old = StreamingDictationFixture(harness: harness)
        let next = StreamingDictationFixture(harness: .init(text: "unused", controller: harness.controller))
        defer { next.cancel() }
        old.start()
        try await old.waitForEngine()
        old.emit("Old text — no conservar", at: 0)
        try await old.expect(confirmed: "", partial: "Old text — no conservar")
        old.cancel()
        next.start()
        try await next.waitForEngine()
        try await next.waitUntil { harness.finishes == 1 }
        XCTAssertEqual(harness.controller.confirmedText, "")
        XCTAssertEqual(harness.controller.partialText, "")
        next.emit("New session — sólo esto", at: 0)
        try await next.expect(confirmed: "", partial: "New session — sólo esto")
        next.cancel()
        try await next.waitUntil { next.harness.finishes == 1 }
        XCTAssertTrue(next.harness.insertions.isEmpty)
        XCTAssertTrue(harness.insertions.isEmpty)
    }

    func testSyntheticControllerBurstMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["PORTAVOZ_DICTATION_PROJECTION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in synthetic controller benchmark; not an ASR or native latency measurement")
        }
        for closedRows in [100, 1_000, 4_000] {
            let fixture = StreamingDictationFixture(capacity: 8_192)
            defer { fixture.cancel() }
            fixture.start()
            try await fixture.waitForEngine()
            for index in 0..<closedRows {
                fixture.emit("Reference sentence number \(index)", at: Double(index) * 8)
            }
            let start = Double(closedRows) * 8
            fixture.emit("Measured start", at: start)
            try await fixture.waitUntil { fixture.harness.controller.partialText == "Measured start" }
            let clock = ContinuousClock()
            let began = clock.now
            for index in 0..<1_000 {
                fixture.emit("Unique token \(index)", at: start + Double(index) * 0.1)
            }
            fixture.emit("Terminal marker", at: start + 1_000)
            try await fixture.waitUntil { fixture.harness.controller.partialText == "Terminal marker" }
            let elapsed = began.duration(to: clock.now)
            XCTAssertTrue(fixture.harness.controller.confirmedText.hasPrefix("Reference sentence number 0"))
            XCTAssertTrue(fixture.harness.controller.confirmedText.contains("Unique token 999"))
            let digest = SHA256.hash(data: Data(fixture.harness.controller.confirmedText.utf8))
                .map { String(format: "%02x", $0) }.joined()
            print("DICTATION_PROJECTION synthetic=true closed_rows=\(closedRows) deltas=1001 elapsed=\(elapsed) "
                + "utf8=\(fixture.harness.controller.confirmedText.utf8.count) sha256=\(digest)")
        }
    }
}

@MainActor
private final class StreamingDictationFixture {
    let harness: DictationControllerHarness
    private let stream: AsyncThrowingStream<TranscriptSegment, Error>
    private let continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    private let meetingID = MeetingID()
    private var ready = false

    init(harness: DictationControllerHarness = .init(text: "unused"), capacity: Int = 128) {
        self.harness = harness
        (stream, continuation) = AsyncThrowingStream.makeStream(
            of: TranscriptSegment.self, bufferingPolicy: .bufferingOldest(capacity))
    }

    func start() {
        var dependencies = harness.dependencies
        dependencies.acquireRuntime = { [weak self] in
            guard let self else { throw CancellationError() }
            harness.loads += 1
            return LiveTranscriptionRuntime(engine: StreamingDictationEngine(
                stream: stream, onStart: { [weak self] in self?.ready = true })) { [weak self] in
                self?.harness.finishes += 1
            }
        }
        harness.controller.toggle(using: dependencies)
    }

    func emit(_ text: String, at time: TimeInterval, channel: AudioChannel = .microphone) {
        let result = continuation.yield(TranscriptSegment(
            meetingID: meetingID, channel: channel, text: text, startTime: time, endTime: time + 0.4))
        guard case .enqueued = result else {
            return XCTFail("Every synthetic delta must reach the actual controller")
        }
    }

    func waitForEngine() async throws { try await waitUntil { self.ready } }

    func expect(confirmed: String, partial: String) async throws {
        try await waitUntil {
            self.harness.controller.confirmedText == confirmed && self.harness.controller.partialText == partial
        }
        XCTAssertEqual(harness.controller.confirmedText, confirmed)
        XCTAssertEqual(harness.controller.partialText, partial)
    }

    func finish() async throws {
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        continuation.finish()
        try await waitUntil { self.harness.finishes == 1 }
    }

    func cancel() {
        harness.controller.cancel()
        continuation.finish()
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try XCTUnwrap(condition() ? true : nil, "Controller did not reach the expected stream state")
    }
}

private struct StreamingDictationEngine: TranscriptionEngine {
    let stream: AsyncThrowingStream<TranscriptSegment, Error>
    let onStart: @MainActor @Sendable () -> Void
    let descriptor = EngineDescriptor(
        id: "streaming-fixture", displayName: "Streaming fixture", realTimeFactor: 0,
        runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        Task { await onStart() }
        return stream
    }
}
