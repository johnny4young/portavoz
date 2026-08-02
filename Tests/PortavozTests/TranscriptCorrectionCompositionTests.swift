import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class TranscriptCorrectionCompositionTests: XCTestCase {
    private let meetingID = MeetingID()
    private let firstSpeaker = SpeakerID()
    private let secondSpeaker = SpeakerID()
    private let sourceDeviceID = UUID(
        uuidString: "00000000-0000-4000-9000-000000000001")!
    private let composer = ComposeTranscript()

    func testReadingPolicyKeepsRawRefinedAndComposedMaterialExplicit() throws {
        let source = segment(1, text: "Original", start: 0, end: 4)
        let correction = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "Corrected", language: "en"))

        let result = try compose(
            material: .refined,
            segments: [source],
            corrections: [correction])

        XCTAssertEqual(result.accepted.lineage.baseMaterial, .refined)
        XCTAssertEqual(result.accepted.lineage.projection, .accepted)
        XCTAssertFalse(result.accepted.lineage.isComposed)
        XCTAssertEqual(result.composed.lineage.baseMaterial, .refined)
        XCTAssertEqual(result.composed.lineage.projection, .composed)
        XCTAssertTrue(result.composed.lineage.isComposed)
        XCTAssertEqual(result.composed.lineage.activeCorrectionIDs, [correction.id])
        XCTAssertEqual(result.content(for: .accepted).rows.map(\.text), ["Original"])
        XCTAssertEqual(result.content(for: .composed).rows.map(\.text), ["Corrected"])
    }

    func testComposedProjectionRemainsExplicitWithoutActiveCorrections() throws {
        let source = segment(1, text: "Original", start: 0, end: 4)

        let result = try compose(segments: [source], corrections: [])

        XCTAssertEqual(result.accepted.rows, result.composed.rows)
        XCTAssertEqual(result.accepted.lineage.projection, .accepted)
        XCTAssertEqual(result.composed.lineage.projection, .composed)
        XCTAssertTrue(result.composed.lineage.activeCorrectionIDs.isEmpty)
        XCTAssertNotEqual(result.accepted, result.composed)
    }

    func testEveryCorrectionKindComposesDeterministicallyFromSourceOrder() throws {
        let segments = [
            segment(1, text: "Wrong word", start: 0, end: 4),
            segment(2, text: "Other speaker", start: 5, end: 9),
            segment(3, text: "One sentence. Another sentence.", start: 10, end: 18),
            segment(4, text: "Merge", start: 19, end: 22),
            segment(5, text: "these", start: 23, end: 26),
            segment(6, text: "Background noise", start: 27, end: 29)
        ]
        let splitParts = [
            part(301, text: "One sentence.", start: 10, end: 14),
            part(302, text: "Another sentence.", start: 14, end: 18)
        ]
        let corrections = [
            edit(106, targets: [segments[5].id], kind: .suppress),
            edit(
                104,
                targets: [segments[3].id, segments[4].id],
                kind: .merge(replacementText: nil, language: nil)),
            edit(103, targets: [segments[2].id], kind: .split(splitParts)),
            edit(102, targets: [segments[1].id], kind: .changeSpeaker(secondSpeaker)),
            edit(
                101,
                targets: [segments[0].id],
                kind: .replaceText(text: "Right word", language: "en"))
        ]

        let forward = try compose(segments: segments.reversed(), corrections: corrections)
        let reverse = try compose(segments: segments, corrections: corrections.reversed())

        XCTAssertEqual(forward.composed, reverse.composed)
        XCTAssertEqual(
            forward.composed.rows.map(\.text),
            ["Right word", "Other speaker", "One sentence.", "Another sentence.", "Merge these"])
        XCTAssertEqual(forward.composed.rows[1].speakerID, secondSpeaker)
        XCTAssertEqual(forward.composed.rows[2].id, splitParts[0].id)
        XCTAssertEqual(
            forward.composed.rows[4].sourceSegmentIDs,
            [segments[3].id, segments[4].id])
        XCTAssertNil(forward.composed.rowID(containingSourceSegmentID: segments[5].id))
    }

    func testStaleAndMissingTargetsFailClosed() throws {
        let source = segment(1, text: "Source", start: 0, end: 4)
        let stale = TranscriptCorrectionEvent(
            id: id(101),
            meetingID: meetingID,
            baseTranscriptRevision: 6,
            targetSegmentIDs: [source.id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(1))
        assertComposeError(
            .staleCorrection(stale.id, expected: 7, actual: 6),
            segments: [source],
            corrections: [stale])

        let missing = edit(102, targets: [id(999)], kind: .suppress)
        assertComposeError(
            .missingTarget(missing.id, id(999)),
            segments: [source],
            corrections: [missing])
    }

    func testMergeRejectsOverlappingAcceptedEvidence() {
        let first = segment(1, text: "First", start: 0, end: 3)
        let second = segment(2, text: "Second", start: 2, end: 4)
        let merge = edit(
            101,
            targets: [first.id, second.id],
            kind: .merge(replacementText: nil, language: "en"))

        assertComposeError(
            .invalidMerge(merge.id),
            segments: [first, second],
            corrections: [merge])
    }

    func testTextAndSpeakerCorrectionsComposeIndependently() throws {
        let source = segment(1, text: "Source", start: 0, end: 4)
        let text = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "Corrected", language: "en"))
        let speaker = edit(
            102,
            targets: [source.id],
            kind: .changeSpeaker(secondSpeaker))

        let result = try compose(
            segments: [source],
            corrections: [speaker, text])

        XCTAssertEqual(result.composed.rows.map(\.text), ["Corrected"])
        XCTAssertEqual(result.composed.rows.map(\.speakerID), [secondSpeaker])
        XCTAssertEqual(result.composed.rows.map(\.id), [speaker.id])
        XCTAssertEqual(
            result.composed.lineage.activeCorrectionIDs,
            [text.id, speaker.id])
    }

    func testSameDomainCorrectionsCannotOverlap() {
        let source = segment(1, text: "Source", start: 0, end: 4)
        let first = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "First", language: "en"))
        let second = edit(
            102,
            targets: [source.id],
            kind: .replaceText(text: "Second", language: "en"))

        assertComposeError(
            .overlappingTarget(source.id, first.id, second.id),
            segments: [source],
            corrections: [second, first])
    }

    func testStructuralCorrectionConflictsWithPropertyCorrection() {
        let source = segment(1, text: "Source", start: 0, end: 4)
        let text = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "Corrected", language: "en"))
        let suppression = edit(
            102,
            targets: [source.id],
            kind: .suppress)

        assertComposeError(
            .overlappingTarget(source.id, text.id, suppression.id),
            segments: [source],
            corrections: [suppression, text])
    }

    func testTextRestorePreservesIndependentSpeakerCorrection() throws {
        let source = segment(1, text: "Original", start: 0, end: 4)
        let text = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "Corrected", language: "en"),
            at: 1)
        let speaker = edit(
            102,
            targets: [source.id],
            kind: .changeSpeaker(secondSpeaker),
            at: 2)
        let restoreText = edit(
            103,
            targets: [source.id],
            kind: .restore,
            at: 3,
            supersedes: text.id)

        let result = try compose(
            segments: [source],
            corrections: [speaker, restoreText, text])

        XCTAssertEqual(result.composed.rows.map(\.text), ["Original"])
        XCTAssertEqual(result.composed.rows.map(\.speakerID), [secondSpeaker])
        XCTAssertEqual(result.composed.rows.map(\.id), [speaker.id])
        XCTAssertEqual(
            result.composed.lineage.activeCorrectionIDs,
            [speaker.id, restoreText.id])
    }

    func testRestoredPropertyLaneDoesNotBlockLaterStructuralCorrection() throws {
        let source = segment(1, text: "Original evidence", start: 0, end: 4)
        let replacement = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "Temporary correction", language: "en"),
            at: 1)
        let restore = edit(
            102,
            targets: [source.id],
            kind: .restore,
            at: 2,
            supersedes: replacement.id)
        let split = edit(
            103,
            targets: [source.id],
            kind: .split([
                part(301, text: "Original", start: 0, end: 2),
                part(302, text: "evidence", start: 2, end: 4),
            ]),
            at: 3)

        XCTAssertNoThrow(try TranscriptCorrectionPolicy.validateHistory(
            [replacement, restore, split],
            meetingID: meetingID))
        let result = try compose(
            segments: [source],
            corrections: [split, restore, replacement])

        XCTAssertEqual(result.composed.rows.map(\.text), ["Original", "evidence"])
        XCTAssertEqual(
            result.composed.lineage.activeCorrectionIDs,
            [restore.id, split.id],
            "restore remains terminal lineage but not a visible correction owner")
    }

    func testSupersedingEditAndRestoreLeaveOneDeterministicActiveEvent() throws {
        let source = segment(1, text: "Original", start: 0, end: 4)
        let first = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "First", language: "en"),
            at: 1)
        let replacement = edit(
            102,
            targets: [source.id],
            kind: .replaceText(text: "Second", language: "en"),
            at: 2,
            supersedes: first.id)
        let restore = edit(
            103,
            targets: [source.id],
            kind: .restore,
            at: 3,
            supersedes: replacement.id)

        let edited = try compose(segments: [source], corrections: [replacement, first])
        XCTAssertEqual(edited.composed.rows.map(\.text), ["Second"])
        XCTAssertEqual(edited.composed.lineage.activeCorrectionIDs, [replacement.id])

        let restored = try compose(
            segments: [source],
            corrections: [restore, first, replacement])
        XCTAssertEqual(restored.composed.rows.map(\.text), ["Original"])
        XCTAssertEqual(restored.composed.rows.map(\.id), [source.id])
        XCTAssertEqual(restored.composed.lineage.activeCorrectionIDs, [restore.id])
    }

    func testTombstonedTerminalEventDoesNotReactivateItsPredecessor() throws {
        let source = segment(1, text: "Original", start: 0, end: 4)
        let replacement = edit(
            101,
            targets: [source.id],
            kind: .replaceText(text: "Replacement", language: "en"),
            at: 1)
        let tombstonedRestore = TranscriptCorrectionEvent(
            id: id(102),
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [source.id],
            kind: .restore,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(2),
            updatedAt: date(3),
            deletedAt: date(3),
            supersedesCorrectionID: replacement.id)

        let result = try compose(
            segments: [source],
            corrections: [replacement, tombstonedRestore])

        XCTAssertEqual(result.composed.rows.map(\.text), ["Original"])
        XCTAssertTrue(result.composed.lineage.activeCorrectionIDs.isEmpty)
    }

    func testCorrectionMeetingAndPortableMetadataMustMatchBase() {
        let source = segment(1, text: "Original", start: 0, end: 4)
        let wrongMeeting = TranscriptCorrectionEvent(
            id: id(101),
            meetingID: MeetingID(),
            baseTranscriptRevision: 7,
            targetSegmentIDs: [source.id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(1))
        assertComposeError(
            .wrongMeeting(wrongMeeting.id),
            segments: [source],
            corrections: [wrongMeeting])

        let invalidTombstone = TranscriptCorrectionEvent(
            id: id(102),
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [source.id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(3),
            updatedAt: date(2),
            deletedAt: date(2))
        assertComposeError(
            .invalidEventMetadata(invalidTombstone.id),
            segments: [source],
            corrections: [invalidTombstone])
    }

    func testInvalidSplitAndNonAdjacentMergeFailClosed() {
        let segments = [
            segment(1, text: "First", start: 0, end: 4),
            segment(2, text: "Middle", start: 5, end: 9),
            segment(3, text: "Last", start: 10, end: 14)
        ]
        let badSplit = edit(
            101,
            targets: [segments[0].id],
            kind: .split([
                part(301, text: "Later", start: 2, end: 4),
                part(302, text: "Earlier", start: 0, end: 2)
            ]))
        assertComposeError(
            .invalidSplit(badSplit.id),
            segments: segments,
            corrections: [badSplit])

        let badMerge = edit(
            102,
            targets: [segments[0].id, segments[2].id],
            kind: .merge(replacementText: nil, language: nil))
        assertComposeError(
            .invalidMerge(badMerge.id),
            segments: segments,
            corrections: [badMerge])

        let reversedMerge = edit(
            103,
            targets: [segments[1].id, segments[0].id],
            kind: .merge(replacementText: nil, language: nil))
        assertComposeError(
            .invalidMerge(reversedMerge.id),
            segments: segments,
            corrections: [reversedMerge])

        let multiRowSuppression = edit(
            104,
            targets: [segments[0].id, segments[1].id],
            kind: .suppress)
        assertComposeError(
            .invalidTargets(multiRowSuppression.id),
            segments: segments,
            corrections: [multiRowSuppression])
    }

    func testSplitMustPartitionTheEntireSourceTimeline() {
        let source = segment(1, text: "One two", start: 0, end: 4)
        let gap = edit(
            101,
            targets: [source.id],
            kind: .split([
                part(301, text: "One", start: 0, end: 1),
                part(302, text: "Two", start: 2, end: 4)
            ]))
        assertComposeError(.invalidSplit(gap.id), segments: [source], corrections: [gap])

        let zeroDuration = edit(
            102,
            targets: [source.id],
            kind: .split([
                part(303, text: "One", start: 0, end: 0),
                part(304, text: "Two", start: 0, end: 4)
            ]))
        assertComposeError(
            .invalidSplit(zeroDuration.id),
            segments: [source],
            corrections: [zeroDuration])

        let truncated = edit(
            103,
            targets: [source.id],
            kind: .split([
                part(305, text: "One", start: 0, end: 1),
                part(306, text: "Two", start: 1, end: 3)
            ]))
        assertComposeError(
            .invalidSplit(truncated.id),
            segments: [source],
            corrections: [truncated])
    }

    func testCompositionRequiresExplicitAcceptedMaterial() {
        let source = segment(1, text: "Source", start: 0, end: 4)

        XCTAssertThrowsError(
            try compose(material: .unspecified, segments: [source], corrections: [])
        ) { error in
            XCTAssertEqual(error as? ComposeTranscriptError, .unspecifiedBaseMaterial)
        }
    }

    func testMergeDoesNotInventLanguageAcrossMissingProvenance() throws {
        let first = segment(
            1,
            text: "Hola",
            language: nil,
            start: 0,
            end: 2,
            confidence: nil)
        let second = segment(2, text: "there", language: "en", start: 2, end: 4)
        let merge = edit(
            101,
            targets: [first.id, second.id],
            kind: .merge(replacementText: nil, language: nil))

        let result = try compose(segments: [first, second], corrections: [merge])

        XCTAssertEqual(result.composed.rows.map(\.text), ["Hola there"])
        XCTAssertNil(result.composed.rows.first?.language)
        XCTAssertNil(result.composed.rows.first?.confidence)
    }

    func testSupersessionMustBeLinearAndKeepTheSameTargets() {
        let firstSource = segment(1, text: "First", start: 0, end: 4)
        let secondSource = segment(2, text: "Second", start: 5, end: 9)
        let original = edit(101, targets: [firstSource.id], kind: .suppress, at: 1)
        let successor = edit(
            102,
            targets: [firstSource.id],
            kind: .restore,
            at: 2,
            supersedes: original.id)
        let branch = edit(
            103,
            targets: [firstSource.id],
            kind: .restore,
            at: 3,
            supersedes: original.id)
        assertComposeError(
            .branchedSupersession(original.id),
            segments: [firstSource, secondSource],
            corrections: [original, successor, branch])

        let mismatched = edit(
            104,
            targets: [secondSource.id],
            kind: .restore,
            at: 2,
            supersedes: original.id)
        assertComposeError(
            .supersessionTargetMismatch(mismatched.id),
            segments: [firstSource, secondSource],
            corrections: [original, mismatched])

        let orderedMerge = edit(
            105,
            targets: [firstSource.id, secondSource.id],
            kind: .merge(replacementText: nil, language: nil),
            at: 1)
        let reorderedRestore = edit(
            106,
            targets: [secondSource.id, firstSource.id],
            kind: .restore,
            at: 2,
            supersedes: orderedMerge.id)
        assertComposeError(
            .supersessionTargetMismatch(reorderedRestore.id),
            segments: [firstSource, secondSource],
            corrections: [orderedMerge, reorderedRestore])
    }

    func testCorrectionOrderingRequiresFiniteCreationTimes() {
        let source = segment(1, text: "Source", start: 0, end: 4)
        let firstInvalid = TranscriptCorrectionEvent(
            id: id(101),
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [source.id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: .infinity))
        let secondInvalid = TranscriptCorrectionEvent(
            id: id(102),
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [source.id],
            kind: .suppress,
            sourceDeviceID: sourceDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: -.infinity))

        assertComposeError(
            .invalidCreatedAt(firstInvalid.id),
            segments: [source],
            corrections: [secondInvalid, firstInvalid])
        assertComposeError(
            .invalidCreatedAt(firstInvalid.id),
            segments: [source],
            corrections: [firstInvalid, secondInvalid])
    }

    func testDuplicateCorrectionIdentityFailureIsDeterministic() {
        let source = segment(1, text: "Source", start: 0, end: 4)
        let lowerIDFirst = edit(101, targets: [source.id], kind: .suppress, at: 1)
        let lowerIDSecond = edit(101, targets: [source.id], kind: .suppress, at: 2)
        let higherIDFirst = edit(102, targets: [source.id], kind: .suppress, at: 1)
        let higherIDSecond = edit(102, targets: [source.id], kind: .suppress, at: 2)

        assertComposeError(
            .duplicateCorrectionID(lowerIDFirst.id),
            segments: [source],
            corrections: [higherIDSecond, lowerIDSecond, higherIDFirst, lowerIDFirst])
    }

    func testGeneratedRowIdentitiesCannotCollide() {
        let first = segment(1, text: "First", start: 0, end: 4)
        let second = segment(2, text: "Second", start: 5, end: 9)
        let sourceCollision = TranscriptCorrectionEvent(
            id: second.id,
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [first.id],
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: sourceDeviceID,
            createdAt: date(1))
        assertComposeError(
            .duplicateComposedRowID(second.id),
            segments: [first, second],
            corrections: [sourceCollision])

        let sharedPartID = id(301)
        let firstSplit = edit(
            101,
            targets: [first.id],
            kind: .split([
                partWithID(sharedPartID, text: "A", start: 0, end: 2),
                part(302, text: "B", start: 2, end: 4)
            ]))
        let secondSplit = edit(
            102,
            targets: [second.id],
            kind: .split([
                partWithID(sharedPartID, text: "C", start: 5, end: 7),
                part(303, text: "D", start: 7, end: 9)
            ]))
        assertComposeError(
            .duplicateComposedRowID(sharedPartID),
            segments: [first, second],
            corrections: [firstSplit, secondSplit])
    }

    func testCompositionRejectsProvisionalOrInvalidConfidenceBaseRows() {
        let provisional = segment(
            1,
            text: "Still changing",
            start: 0,
            end: 4,
            isFinal: false)
        XCTAssertThrowsError(try compose(segments: [provisional], corrections: [])) { error in
            XCTAssertEqual(error as? ComposeTranscriptError, .invalidBaseSegments)
        }

        let invalidConfidence = segment(
            2,
            text: "Invalid confidence",
            start: 0,
            end: 4,
            confidence: 1.5)
        XCTAssertThrowsError(try compose(segments: [invalidConfidence], corrections: [])) { error in
            XCTAssertEqual(error as? ComposeTranscriptError, .invalidBaseSegments)
        }
    }

    private func compose<S: Sequence, C: Sequence>(
        material: MeetingTranscriptBaseMaterial = .raw,
        segments: S,
        corrections: C
    ) throws -> TranscriptComposition
    where S.Element == TranscriptSegment, C.Element == TranscriptCorrectionEvent {
        try composer.execute(
            baseTranscriptRevision: 7,
            baseMaterial: material,
            segments: Array(segments),
            corrections: Array(corrections))
    }

    private func assertComposeError(
        _ expected: ComposeTranscriptError,
        segments: [TranscriptSegment],
        corrections: [TranscriptCorrectionEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try compose(segments: segments, corrections: corrections),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ComposeTranscriptError, expected, file: file, line: line)
        }
    }

    private func segment(
        _ value: Int,
        text: String,
        language: String? = "en",
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double? = 0.9,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id(value),
            meetingID: meetingID,
            speakerID: firstSpeaker,
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: end,
            confidence: confidence,
            isFinal: isFinal)
    }

    private func edit(
        _ value: Int,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        at: TimeInterval? = nil,
        supersedes: UUID? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: id(value),
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(at ?? Double(value)),
            supersedesCorrectionID: supersedes)
    }

    private func part(
        _ value: Int,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptCorrectionPart {
        partWithID(id(value), text: text, start: start, end: end)
    }

    private func partWithID(
        _ id: UUID,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptCorrectionPart {
        TranscriptCorrectionPart(
            id: id,
            text: text,
            speakerID: firstSpeaker,
            language: "en",
            startTime: start,
            endTime: end)
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
