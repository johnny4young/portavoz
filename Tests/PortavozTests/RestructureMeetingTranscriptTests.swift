import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class RestructureMeetingTranscriptTests: XCTestCase {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "C3000000-0000-4000-8000-000000000001")!)
    private let speakerID = SpeakerID(
        rawValue: UUID(uuidString: "C3000000-0000-4000-8000-000000000002")!)
    private let otherSpeakerID = SpeakerID(
        rawValue: UUID(uuidString: "C3000000-0000-4000-8000-000000000003")!)
    private let sourceDeviceID = UUID(
        uuidString: "C3000000-0000-4000-9000-000000000001")!
    private let timestamp = Date(timeIntervalSince1970: 1_800_100_000)

    func testSplitPartitionsTimeAndPreservesOneSourceMap() async throws {
        let repository = StructuralCorrectionRepositoryProbe()
        let useCase = makeUseCase(repository)
        let accepted = content([
            row(1, text: "First thought second thought", start: 0, end: 4)
        ])

        let result = try await useCase.execute(request(
            accepted: accepted,
            operation: .split(
                sourceSegmentID: accepted.rows[0].id,
                firstText: "First thought",
                secondText: "second thought",
                splitTime: 1.5)))

        guard case .split(let parts) = result.event.kind else {
            return XCTFail("the command must persist a typed split")
        }
        XCTAssertEqual(parts.map(\.text), ["First thought", "second thought"])
        XCTAssertEqual(parts.map(\.startTime), [0, 1.5])
        XCTAssertEqual(parts.map(\.endTime), [1.5, 4])
        XCTAssertEqual(Set(parts.map(\.id)).count, 2)
        XCTAssertFalse(parts.map(\.id).contains(result.event.id))
        XCTAssertFalse(parts.map(\.id).contains(accepted.rows[0].id))
        let composed = try compose(accepted, corrections: [result.event])
        XCTAssertEqual(composed.rows.map(\.sourceSegmentIDs), [
            [accepted.rows[0].id], [accepted.rows[0].id]
        ])
    }

    func testMergeRequiresExplicitAdjacentCompatibleSelection() async throws {
        let accepted = content([
            row(1, text: "First", start: 0, end: 2),
            row(2, text: "Second", start: 2, end: 4),
            row(3, text: "Other", speakerID: otherSpeakerID, start: 4, end: 6)
        ])
        let repository = StructuralCorrectionRepositoryProbe()
        let result = try await makeUseCase(repository).execute(request(
            accepted: accepted,
            operation: .merge(sourceSegmentIDs: [
                accepted.rows[0].id, accepted.rows[1].id
            ])))

        guard case .merge(let replacement, let language) = result.event.kind else {
            return XCTFail("the command must persist a typed merge")
        }
        XCTAssertNil(replacement)
        XCTAssertEqual(language, "en")
        let composed = try compose(accepted, corrections: [result.event])
        XCTAssertEqual(composed.rows[0].text, "First Second")
        XCTAssertEqual(composed.rows[0].sourceSegmentIDs, [
            accepted.rows[0].id, accepted.rows[1].id
        ])

        await assertError(.invalidMerge) {
            _ = try await self.makeUseCase(StructuralCorrectionRepositoryProbe())
                .execute(self.request(
                    accepted: accepted,
                    operation: .merge(sourceSegmentIDs: [
                        accepted.rows[1].id, accepted.rows[0].id
                    ])))
        }

        let overlapping = content([
            row(11, text: "First", start: 0, end: 3),
            row(12, text: "Second", start: 2, end: 4)
        ])
        await assertError(.invalidMerge) {
            _ = try await self.makeUseCase(StructuralCorrectionRepositoryProbe())
                .execute(self.request(
                    accepted: overlapping,
                    operation: .merge(sourceSegmentIDs: overlapping.rows.map(\.id))))
        }
        await assertError(.invalidMerge) {
            _ = try await self.makeUseCase(StructuralCorrectionRepositoryProbe())
                .execute(self.request(
                    accepted: accepted,
                    operation: .merge(sourceSegmentIDs: [
                        accepted.rows[1].id, accepted.rows[2].id
                    ])))
        }
    }

    func testSuppressAndRestoreRemainAppendOnly() async throws {
        let accepted = content([row(1, text: "Background noise", start: 0, end: 2)])
        let repository = StructuralCorrectionRepositoryProbe()
        let useCase = makeUseCase(repository)
        let suppression = try await useCase.execute(request(
            accepted: accepted,
            operation: .suppress(sourceSegmentID: accepted.rows[0].id)))

        XCTAssertTrue(try compose(
            accepted,
            corrections: [suppression.event]).rows.isEmpty)
        let restore = try await useCase.execute(request(
            accepted: accepted,
            operation: .restore(correctionID: suppression.event.id)))

        guard case .restore = restore.event.kind else {
            return XCTFail("undo must append a restore")
        }
        XCTAssertEqual(restore.event.supersedesCorrectionID, suppression.event.id)
        let history = await repository.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(try compose(accepted, corrections: history).rows, accepted.rows)
    }

    func testRestoreReleasesTargetForADifferentLaterStructuralSelection() async throws {
        let accepted = content([
            row(1, text: "First", start: 0, end: 2),
            row(2, text: "Second", start: 2, end: 4)
        ])
        let repository = StructuralCorrectionRepositoryProbe()
        let useCase = makeUseCase(repository)
        let split = try await useCase.execute(request(
            accepted: accepted,
            operation: .split(
                sourceSegmentID: accepted.rows[0].id,
                firstText: "Fir",
                secondText: "st",
                splitTime: 1)))
        _ = try await useCase.execute(request(
            accepted: accepted,
            operation: .restore(correctionID: split.event.id)))

        let merge = try await useCase.execute(request(
            accepted: accepted,
            operation: .merge(sourceSegmentIDs: accepted.rows.map(\.id))))

        let history = await repository.history()
        XCTAssertEqual(history.count, 3)
        XCTAssertNil(merge.event.supersedesCorrectionID)
        XCTAssertEqual(try compose(accepted, corrections: history).rows.count, 1)
    }

    func testPropertyCorrectionBlocksStructuralMutation() async {
        let accepted = content([row(1, text: "Accepted", start: 0, end: 2)])
        let textCorrection = TranscriptCorrectionEvent(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [accepted.rows[0].id],
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp)
        let repository = StructuralCorrectionRepositoryProbe(history: [textCorrection])

        await assertError(.incompatibleCorrection) {
            _ = try await self.makeUseCase(repository).execute(self.request(
                accepted: accepted,
                operation: .suppress(sourceSegmentID: accepted.rows[0].id)))
        }
    }

    func testReadModelExposesMergeAndRecoverableSuppressionContexts() async throws {
        let accepted = content([
            row(1, text: "First", start: 0, end: 2),
            row(2, text: "Second", start: 2, end: 4)
        ])
        let suppression = try await makeUseCase(StructuralCorrectionRepositoryProbe())
            .execute(request(
                accepted: accepted,
                operation: .suppress(sourceSegmentID: accepted.rows[0].id)))
            .event
        let detail = reviewModel(accepted: accepted, corrections: [suppression])
        let hiddenProjection = detail.transcriptStructureProjection(
            current: detail.transcriptContent(),
            accepted: detail.acceptedTranscriptContent())

        let hidden = try XCTUnwrap(hiddenProjection.suppressedContexts.first)
        XCTAssertTrue(hidden.isSuppressed)
        XCTAssertEqual(hidden.originals.map(\.id), [accepted.rows[0].id])

        let uncorrected = reviewModel(accepted: accepted, corrections: [])
        let projection = uncorrected.transcriptStructureProjection(
            current: uncorrected.transcriptContent(),
            accepted: uncorrected.acceptedTranscriptContent())
        let context = try XCTUnwrap(projection.context(for: accepted.rows[0]))
        XCTAssertTrue(context.canSplit)
        XCTAssertTrue(context.canSuppress)
        XCTAssertEqual(context.mergeCandidates.map(\.direction), [.next])
        XCTAssertEqual(context.mergeCandidates[0].rows.map(\.id), accepted.rows.map(\.id))
    }

    func testHiddenContextsFollowTranscriptOrderInsteadOfCorrectionTime() {
        let accepted = content([
            row(1, text: "First noise", start: 0, end: 1),
            row(2, text: "Kept", start: 1, end: 2),
            row(3, text: "Last noise", start: 2, end: 3),
        ])
        let lastFirst = TranscriptCorrectionEvent(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [accepted.rows[2].id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp)
        let firstLater = TranscriptCorrectionEvent(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [accepted.rows[0].id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp.addingTimeInterval(1))
        let detail = reviewModel(
            accepted: accepted,
            corrections: [lastFirst, firstLater])

        let projection = detail.transcriptStructureProjection(
            current: detail.transcriptContent(),
            accepted: detail.acceptedTranscriptContent())

        XCTAssertEqual(
            projection.suppressedContexts.flatMap { $0.originals.map(\.id) },
            [accepted.rows[0].id, accepted.rows[2].id])
    }

    func testStructureProjectionKeepsLargeTranscriptLookupsAddressable() throws {
        let accepted = content((0..<20_000).map { index in
            row(
                index + 1,
                text: "Row \(index)",
                start: Double(index) * 2,
                end: Double(index) * 2 + 1)
        })
        let detail = reviewModel(accepted: accepted, corrections: [])

        let projection = detail.transcriptStructureProjection(
            current: accepted,
            accepted: accepted)

        let last = try XCTUnwrap(projection.context(for: accepted.rows[19_999]))
        XCTAssertTrue(last.canSplit)
        XCTAssertEqual(last.mergeCandidates.map(\.direction), [.previous])
    }

    func testGeneratedIdentityCollisionFailsClosedBeforePersistence() async {
        let accepted = content([
            row(1, text: "First second", start: 0, end: 2)
        ])
        let repository = StructuralCorrectionRepositoryProbe()
        let collidingID = accepted.rows[0].id
        let timestamp = timestamp
        let useCase = RestructureMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp },
            makeID: { collidingID })

        await assertError(.invalidTarget) {
            _ = try await useCase.execute(self.request(
                accepted: accepted,
                operation: .split(
                    sourceSegmentID: collidingID,
                    firstText: "First",
                    secondText: "second",
                    splitTime: 1)))
        }
        let history = await repository.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testGeneratedIdentityCannotReuseHistoricalSplitPart() async {
        let accepted = content([
            row(1, text: "First part", start: 0, end: 2),
            row(2, text: "Noise", start: 3, end: 4),
        ])
        let partID = UUID(uuidString: "C3000000-0000-4000-9000-000000000099")!
        let split = TranscriptCorrectionEvent(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [accepted.rows[0].id],
            kind: .split([
                TranscriptCorrectionPart(
                    id: partID,
                    text: "First",
                    speakerID: speakerID,
                    language: "en",
                    startTime: 0,
                    endTime: 1),
                TranscriptCorrectionPart(
                    text: "part",
                    speakerID: speakerID,
                    language: "en",
                    startTime: 1,
                    endTime: 2),
            ]),
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp)
        let repository = StructuralCorrectionRepositoryProbe(history: [split])
        let timestamp = timestamp
        let useCase = RestructureMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp },
            makeID: { partID })

        await assertError(.invalidTarget) {
            _ = try await useCase.execute(self.request(
                accepted: accepted,
                operation: .suppress(sourceSegmentID: accepted.rows[1].id)))
        }
        let history = await repository.history()
        XCTAssertEqual(history, [split])
    }
}

private extension RestructureMeetingTranscriptTests {
    func makeUseCase(
        _ repository: StructuralCorrectionRepositoryProbe
    ) -> RestructureMeetingTranscript {
        let timestamp = timestamp
        return RestructureMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })
    }

    func request(
        accepted: MeetingTranscriptContent,
        operation: TranscriptStructuralCorrectionOperation
    ) -> RestructureMeetingTranscriptRequest {
        RestructureMeetingTranscriptRequest(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            accepted: accepted,
            operation: operation)
    }

    func row(
        _ value: Int,
        text: String,
        speakerID: SpeakerID? = nil,
        start: TimeInterval,
        end: TimeInterval
    ) -> MeetingTranscriptContent.Row {
        let id = UUID(uuidString: String(
            format: "C3000000-0000-4000-8000-%012d",
            value))!
        return MeetingTranscriptContent.Row(
            id: id,
            sourceSegmentIDs: [id],
            speakerID: speakerID ?? self.speakerID,
            channel: .system,
            text: text,
            language: "en",
            startTime: start,
            endTime: end,
            confidence: 0.9,
            isFinal: true)
    }

    func content(_ rows: [MeetingTranscriptContent.Row]) -> MeetingTranscriptContent {
        MeetingTranscriptContent(
            baseTranscriptRevision: 7,
            rows: rows,
            chapters: [],
            lineage: MeetingTranscriptLineage(
                baseMaterial: .refined,
                projection: .accepted))
    }

    func compose(
        _ accepted: MeetingTranscriptContent,
        corrections: [TranscriptCorrectionEvent]
    ) throws -> MeetingTranscriptContent {
        let segments = accepted.rows.map { row in
            TranscriptSegment(
                id: row.id,
                meetingID: meetingID,
                speakerID: row.speakerID,
                channel: row.channel,
                text: row.text,
                language: row.language,
                startTime: row.startTime,
                endTime: row.endTime,
                confidence: row.confidence,
                isFinal: row.isFinal)
        }
        return try ComposeTranscript().execute(
            baseTranscriptRevision: 7,
            baseMaterial: .refined,
            segments: segments,
            corrections: corrections).composed
    }

    func reviewModel(
        accepted: MeetingTranscriptContent,
        corrections: [TranscriptCorrectionEvent]
    ) -> MeetingReviewReadModel {
        let meeting = Meeting(
            id: meetingID,
            title: "Structural correction",
            startedAt: timestamp,
            transcriptRevision: 7)
        let speaker = Speaker(id: speakerID, meetingID: meetingID, label: "S1")
        let segments = accepted.rows.map { row in
            TranscriptSegment(
                id: row.id,
                meetingID: meetingID,
                speakerID: row.speakerID,
                channel: row.channel,
                text: row.text,
                language: row.language,
                startTime: row.startTime,
                endTime: row.endTime,
                confidence: row.confidence,
                isFinal: row.isFinal)
        }
        return MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [speaker],
                segments: segments,
                corrections: corrections,
                isRefinedTranscript: true),
            summary: nil,
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [])
    }

    func assertError(
        _ expected: RestructureMeetingTranscriptError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch let error as RestructureMeetingTranscriptError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private actor StructuralCorrectionRepositoryProbe: TranscriptCorrectionRepository {
    private var storedHistory: [TranscriptCorrectionEvent]

    init(history: [TranscriptCorrectionEvent] = []) {
        storedHistory = history
    }

    func transcriptCorrectionHistory(
        for meetingID: MeetingID
    ) -> [TranscriptCorrectionEvent] {
        storedHistory.filter { $0.meetingID == meetingID }
    }

    func appendTranscriptCorrections(
        _ events: [TranscriptCorrectionEvent]
    ) throws -> [TranscriptCorrectionEvent] {
        guard let meetingID = events.first?.meetingID else { return [] }
        try TranscriptCorrectionPolicy.validateHistory(
            storedHistory + events,
            meetingID: meetingID)
        storedHistory.append(contentsOf: events)
        return events
    }

    func history() -> [TranscriptCorrectionEvent] { storedHistory }
}
