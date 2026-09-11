import IntelligenceKit
import PortavozCore
import XCTest

final class DeterministicLiveSummaryTests: XCTestCase {
    func testBuildsExtractiveCheckpointWithoutAProvider() throws {
        let fixture = Fixture()
        let checkpoint = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: [
                fixture.segment("We agreed to ship on Friday.", at: 1),
                fixture.segment("I will publish the rollback notes.", at: 2),
                fixture.segment("What blocks the database migration?", at: 3),
            ],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "en"))

        XCTAssertEqual(checkpoint.extracts.count, 3)
        XCTAssertEqual(checkpoint.segments.map(\.id), checkpoint.extracts.map(\.id))
        XCTAssertTrue(checkpoint.markdown.contains("## Live highlights"))
        XCTAssertTrue(checkpoint.markdown.contains("We agreed to ship on Friday."))
        XCTAssertTrue(checkpoint.material.contains("Them: What blocks"))
    }

    func testIncrementalRevisionReplacesTheSameEvidenceIdentity() throws {
        let fixture = Fixture()
        let id = UUID()
        let first = fixture.segment("We agreed to ship.", id: id, at: 1)
        let initial = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: [first],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "en"))
        let revised = fixture.segment(
            "We agreed to ship on Friday after the migration.",
            id: id,
            at: 1)

        let checkpoint = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: initial,
            segments: [revised],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "en"))

        XCTAssertEqual(checkpoint.extracts.count, 1)
        XCTAssertEqual(checkpoint.extracts.first?.id, id)
        XCTAssertEqual(checkpoint.extracts.first?.text, revised.text)
    }

    func testRetainsHighSignalAndRecentEvidenceUnderFixedBounds() throws {
        let fixture = Fixture()
        var rows = (0..<80).map {
            fixture.segment("Routine update \($0) with background context.", at: Double($0))
        }
        let decision = fixture.segment(
            "We decided the rollback owner is Camila.",
            at: 0.5)
        rows.append(decision)

        let checkpoint = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: rows,
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "en"))

        XCTAssertLessThanOrEqual(
            checkpoint.extracts.count,
            DeterministicLiveSummary.maximumExtracts)
        XCTAssertLessThanOrEqual(
            checkpoint.material.count,
            DeterministicLiveSummary.maximumCharacters)
        XCTAssertTrue(checkpoint.extracts.contains { $0.id == decision.id })
        XCTAssertTrue(checkpoint.extracts.contains { $0.text.contains("Routine update 79") })
    }

    func testRecentEvidenceCannotBeStarvedByOlderHighSignalRows() throws {
        let fixture = Fixture()
        var rows = (0..<40).map {
            fixture.segment(
                "We decided action item owner ($0) will follow up on the blocker.",
                at: Double($0))
        }
        let newest = fixture.segment(
            "A new customer detail arrived without decision vocabulary.",
            at: 100)
        rows.append(newest)

        let checkpoint = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: rows,
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "en"))

        XCTAssertTrue(checkpoint.extracts.contains { $0.id == newest.id })
        XCTAssertLessThanOrEqual(
            checkpoint.extracts.count,
            DeterministicLiveSummary.maximumExtracts)
        XCTAssertLessThanOrEqual(
            checkpoint.material.count,
            DeterministicLiveSummary.maximumCharacters)
    }

    func testContextChangesRerenderWithoutNewTranscriptRows() throws {
        let fixture = Fixture()
        let initial = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: [fixture.segment("A stable meeting excerpt.", at: 1)],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "es"))
        let note = ContextItem(
            meetingID: fixture.meetingID,
            kind: .note,
            content: "Confirmar el presupuesto",
            timestamp: 2)

        let withNote = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: initial,
            segments: [],
            speakers: fixture.speakers,
            contextItems: [note],
            targetLanguage: "es"))
        let removed = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: withNote,
            segments: [],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "es"))

        XCTAssertTrue(withNote.markdown.contains("## Tus notas"))
        XCTAssertTrue(withNote.markdown.contains("Confirmar el presupuesto"))
        XCTAssertFalse(removed.markdown.contains("Confirmar el presupuesto"))
        XCTAssertEqual(removed.targetLanguage, "es")
    }

    func testInvalidLanguageAndDuplicateSpeakersFailSafe() throws {
        let fixture = Fixture()
        let initial = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: [fixture.segment("A stable meeting excerpt.", at: 1)],
            speakers: fixture.speakers + [fixture.them],
            contextItems: [],
            targetLanguage: "es"))

        let rerendered = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: initial,
            segments: [],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: ""))

        XCTAssertEqual(rerendered.targetLanguage, "es")
        XCTAssertTrue(rerendered.markdown.contains("## Puntos clave en vivo"))
    }

    func testEscapesMarkdownAndClipsOversizedEvidence() throws {
        let fixture = Fixture()
        let oversized = "*do not become formatting* [open](https://example.com) "
            + String(repeating: "x", count: 1_000)
        let checkpoint = try XCTUnwrap(DeterministicLiveSummary.advance(
            checkpoint: nil,
            segments: [fixture.segment(oversized, at: 1)],
            speakers: fixture.speakers,
            contextItems: [],
            targetLanguage: "en"))

        XCTAssertLessThanOrEqual(
            try XCTUnwrap(checkpoint.extracts.first).text.count,
            DeterministicLiveSummary.maximumExtractCharacters)
        XCTAssertTrue(checkpoint.markdown.contains("\\*do not become formatting\\*"))
        XCTAssertTrue(checkpoint.markdown.contains(
            "\\[open\\]\\(https://example.com\\)"))
        XCTAssertFalse(checkpoint.markdown.contains("[open](https://example.com)"))
        XCTAssertTrue(checkpoint.markdown.contains("…"))
    }
}

private struct Fixture {
    let meetingID: MeetingID
    let me: Speaker
    let them: Speaker

    init() {
        let meetingID = MeetingID()
        self.meetingID = meetingID
        me = Speaker(meetingID: meetingID, label: "Me", isMe: true)
        them = Speaker(meetingID: meetingID, label: "Them")
    }

    var speakers: [Speaker] { [me, them] }

    func segment(
        _ text: String,
        id: UUID = UUID(),
        at startTime: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: meetingID,
            speakerID: them.id,
            channel: .system,
            text: text,
            language: "en",
            startTime: startTime,
            endTime: startTime + 1,
            isFinal: true)
    }
}
