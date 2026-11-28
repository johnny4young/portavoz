@testable import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
@testable import portavoz_app
import XCTest

@MainActor
final class AskWhoSaidItPresentationTests: XCTestCase {
    private let meeting = MeetingID()
    private let me = SpeakerID()
    private let marta = SpeakerID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private lazy var citations = [
        AskCitation(segmentID: UUID(), meetingID: meeting, meetingTitle: "Sprint demo", timestamp: 138, text: "I own it."),
        AskCitation(segmentID: UUID(), meetingID: meeting, meetingTitle: "Sprint demo", timestamp: 228, text: "Blocked."),
        AskCitation(segmentID: UUID(), meetingID: meeting, meetingTitle: "Sprint demo", timestamp: 300, text: "Who?")
    ]

    private func evidence() -> AskEvidence {
        let source = VoiceStripSource(columns: MeetingVoiceColumns(
            duration: 600, columns: [0, 0, 1, 1],
            voices: [
                .init(speakerID: me, isMe: true, label: "Me", displayName: nil, talkSeconds: 300, firstHeard: 0),
                .init(speakerID: marta, isMe: false, label: "S1", displayName: "Marta", talkSeconds: 300, firstHeard: 300)
            ]))
        let voices = source.voices
        return AskEvidence(
            rows: [
                .init(number: 1, citation: citations[0], voice: voices[0], meetingStartedAt: now,
                      position: 0.23, isCitedByAnswer: true),
                .init(number: 2, citation: citations[1], voice: voices[1], meetingStartedAt: now,
                      position: 0.38, isCitedByAnswer: true),
                .init(number: 3, citation: citations[2], voice: nil, meetingStartedAt: now,
                      position: 0.5, isCitedByAnswer: false)
            ],
            strips: [.init(meetingID: meeting, source: source)],
            openCommitments: [CommitmentID()])
    }

    func testMarkersPointingAtACitationLeaveTheTextAndTakeTheSpaceBeforeThem() async {
        XCTAssertEqual(
            AskEvidencePresentation.pieces(of: "You own it [1]. Blocked [2][3] until [9].", citationCount: 3),
            [.text("You own it"), .marker(1), .text(". Blocked"), .marker(2), .marker(3), .text(" until [9].")])
        XCTAssertEqual(AskEvidencePresentation.pieces(of: "No markers.", citationCount: 0), [.text("No markers.")])
        XCTAssertEqual(
            AskEvidencePresentation.pieces(of: "A web answer [1].", citationCount: 0), [.text("A web answer [1].")],
            "notes and web answers have no meeting rows, so their markers stay text")
    }

    func testRowsWaitForTheirVoiceThenNameItOnTheStripWithTheMoment() async {
        let pending = AskEvidencePresentation.rows(citations: citations, evidence: nil, now: now, calendar: calendar)
        XCTAssertEqual(pending.map(\.number), [1, 2, 3])
        XCTAssertEqual(pending.map(\.speaker), [.pending, .pending, .pending])
        XCTAssertEqual(pending.map(\.meeting), Array(repeating: "Sprint demo", count: 3))
        XCTAssertEqual(pending.map(\.time), ["02:18", "03:48", "05:00"])
        XCTAssertNil(pending.first?.strip)

        let rows = AskEvidencePresentation.rows(
            citations: citations, evidence: evidence(), now: now.addingTimeInterval(60), calendar: calendar)
        XCTAssertEqual(rows[0].speaker, .voice(name: "You", tint: .you))
        guard case .voice("Marta", .hue(_)) = rows[1].speaker else {
            return XCTFail("a named voice keeps its hue: \(rows[1].speaker)")
        }
        XCTAssertEqual(rows[2].speaker, .unknown)
        XCTAssertEqual(rows.map(\.meeting), Array(repeating: "Sprint demo · today", count: 3))
        XCTAssertEqual(rows.map(\.position), [0.23, 0.38, 0.5])
        XCTAssertNotNil(rows[0].strip)
    }

    func testEvidenceForOtherCitationsNeverLendsItsVoice() async {
        let reordered = [citations[1], citations[0], citations[2]]
        let rows = AskEvidencePresentation.rows(citations: reordered, evidence: evidence(), now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.speaker), [.unknown, .unknown, .unknown])
        XCTAssertEqual(rows.map(\.position), [nil, nil, 0.5])
    }

    func testDaysAndCountsReadAsTheBoardWrites() async {
        XCTAssertEqual(AskEvidencePresentation.day(now, now: now, calendar: calendar), "today")
        XCTAssertEqual(
            AskEvidencePresentation.day(now.addingTimeInterval(-86_400), now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(AskEvidencePresentation.generatedFrom(voices: 3, meetings: 2), "Portavoz · from 3 voices in 2 meetings")
        XCTAssertEqual(AskEvidencePresentation.generatedFrom(voices: 1, meetings: 1), "Portavoz · from 1 voice in 1 meeting")
        XCTAssertEqual(AskEvidencePresentation.generatedFrom(voices: 0, meetings: 2), "Portavoz · from 2 meetings")
        XCTAssertEqual(AskEvidencePresentation.openCommitments(1), "1 open commitment")
        XCTAssertEqual(AskEvidencePresentation.openCommitments(2), "2 open commitments")
        XCTAssertEqual(AskEvidencePresentation.moments(4), "4 moments")
    }

    func testMarkdownLeadsEachCitationWithWhoSaidIt() async {
        let rows = AskEvidencePresentation.rows(citations: citations, evidence: evidence(), now: now, calendar: calendar)
        XCTAssertEqual(
            AskEvidencePresentation.markdown(question: "Who owns it?", answer: "You [1].", rows: rows),
            """
            > Who owns it?

            You [1].

            - You · Sprint demo · 02:18
            - Marta · Sprint demo · 03:48
            - Sprint demo · 05:00
            """)
        XCTAssertEqual(
            AskMarkdown.format(question: "Q", answer: "A", citations: [citations[0]]),
            "> Q\n\nA\n\n- Sprint demo · 02:18")
    }
}
