import Foundation
import IntelligenceKit
import PortavozCore
import XCTest

@testable import StorageKit

/// The reviewed transcript projection is what summary and Apuntador operation
/// fingerprints hash. Two channels routinely open a segment at the same
/// instant, so `startTime` alone cannot decide that projection.
final class TranscriptProjectionOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_699_200)

    private func meeting() -> Meeting {
        Meeting(
            id: MeetingID(),
            title: "Tied transcript",
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            lifecycleState: .ready)
    }

    private func segment(
        id: UUID,
        meetingID: MeetingID,
        channel: AudioChannel,
        text: String,
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: meetingID,
            channel: channel,
            text: text,
            language: "en",
            startTime: start,
            endTime: start + 1,
            isFinal: true)
    }

    /// Insertion order deliberately contradicts identity order, so a read that
    /// leaned on physical row order would disagree with `TranscriptSegmentOrder`.
    func testReviewProjectionIsTotallyOrderedAcrossTiedStartTimes() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let later = UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!
        let earlier = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        try await store.save([
            segment(
                id: later, meetingID: captured.id, channel: .system,
                text: "system at the same instant", start: 12),
            segment(
                id: earlier, meetingID: captured.id, channel: .microphone,
                text: "microphone at the same instant", start: 12),
        ])

        let firstRead = try await store.detail(captured.id)
        let secondRead = try await store.detail(captured.id)
        let first = try XCTUnwrap(firstRead).segments
        let second = try XCTUnwrap(secondRead).segments

        XCTAssertEqual(first.map(\.id), [earlier, later])
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertEqual(
            first.map(\.id),
            TranscriptSegmentOrder.canonical(first.shuffled()).map(\.id))
    }

    /// The durable read and the in-memory material a producer fingerprints must
    /// agree, or the derived job is fenced against an input nothing reproduces.
    func testSummaryFingerprintMatchesCanonicalMaterialFromEitherSide() async throws {
        let store = try MeetingStore.inMemory()
        let captured = meeting()
        try await store.save(captured)
        let meetingID = captured.id
        let material = [
            segment(
                id: UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!,
                meetingID: meetingID, channel: .system, text: "second", start: 12),
            segment(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                meetingID: meetingID, channel: .microphone, text: "first", start: 12),
        ]
        try await store.save(material)
        func fingerprint(_ segments: [TranscriptSegment]) -> String {
            SummaryOperationFingerprint.compute(
                request: SummaryRequest(
                    meetingID: meetingID,
                    segments: segments,
                    speakers: [],
                    recipe: .general,
                    targetLanguage: "en"),
                providerID: "durable-test",
                transcriptRevision: captured.transcriptRevision)
        }

        let read = try await store.detail(meetingID)
        let stored = try XCTUnwrap(read).segments

        XCTAssertEqual(
            fingerprint(TranscriptSegmentOrder.canonical(material)),
            fingerprint(stored))
    }
}
