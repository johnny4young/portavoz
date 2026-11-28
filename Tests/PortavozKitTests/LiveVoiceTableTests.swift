import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class LiveVoiceTableTests: XCTestCase {
    private let meetingID = MeetingID()

    /// Twelve voices: you, then S1…S11 in turn, voice n speaking n + 1 seconds.
    private func stage(youSpeaking: Bool = false, now: TimeInterval? = nil) -> LiveVoiceStage {
        var captions: [TranscriptSegment] = []
        var labels: [UUID: String] = [:]
        var clock: TimeInterval = 0
        for index in 0..<12 {
            let length = TimeInterval(index + 1)
            let row = TranscriptSegment(
                meetingID: meetingID, channel: index == 0 ? .microphone : .system, text: "words",
                startTime: clock, endTime: clock + length, isFinal: true)
            if index > 0 { labels[row.id] = "S\(index)" }
            captions.append(row)
            clock += length + 1
        }
        // A last, still-open row from you keeps the closed S11 row labelled.
        captions.append(TranscriptSegment(
            meetingID: meetingID, channel: .microphone, text: "words",
            startTime: clock, endTime: clock + 2, isFinal: true))
        return LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: captions, labels: labels, latestTurn: nil, youSpeaking: youSpeaking,
            now: now ?? clock + 2))
    }

    private func table(_ stage: LiveVoiceStage) -> LiveVoiceTable {
        LiveVoiceTable(stage: stage, cast: stage.cast())
    }

    func testTheCurrentSpeakerLeadsThenTheMostRecentAndTheRestFold() {
        let table = table(stage())

        XCTAssertEqual(table.rows.map(\.id), ["you", "S11", "S10", "S9", "S8", "S7"])
        XCTAssertEqual(table.rows.map(\.isSpeaking), [true, false, false, false, false, false])
        XCTAssertEqual(table.others.map(\.id), ["S6", "S5", "S4", "S3", "S2", "S1"], "folded by talk share")
        XCTAssertEqual(table.rows.count + table.others.count, 12)
        XCTAssertTrue(table.others.allSatisfy { $0.voice.tint == .grey })
    }

    func testAShortStageFoldsTheOldestRowsAndKeepsEveryVoice() {
        let full = table(stage())
        let short = full.folding(to: 3)

        XCTAssertEqual(short.rows.map(\.id), ["you", "S11", "S10"])
        XCTAssertEqual(short.others.map(\.id), ["S9", "S8", "S7", "S6", "S5", "S4", "S3", "S2", "S1"])
        XCTAssertEqual(short.othersShare + short.rows.reduce(0) { $0 + $1.voice.share }, 1, accuracy: 1e-9)
        XCTAssertEqual(short.widestShare, short.othersShare)
        XCTAssertEqual(full.folding(to: 6), full)
        XCTAssertEqual(full.folding(to: 0).rows.map(\.id), ["you"])
    }

    func testOneVoiceIsNeverFoldedAlone() {
        let captions = [0.0, 2, 4].map { start in
            TranscriptSegment(
                meetingID: meetingID, channel: start == 0 ? .microphone : .system, text: "words",
                startTime: start, endTime: start + 1, isFinal: true)
        }
        let three = LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: captions, labels: [captions[1].id: "S1", captions[2].id: "S2"], latestTurn: nil,
            youSpeaking: false, now: 6))
        let table = table(three)

        XCTAssertEqual(table.rows.count, 3)
        XCTAssertTrue(table.others.isEmpty)
        XCTAssertEqual(table.folding(to: table.rows.count - 1), table, "its fold row would take the same room")
    }

    func testSharesAndBarsScaleToTheWidestOnScreen() {
        let table = table(stage())
        // You: 1 s + the open 2 s; S1…S11 spoke 2…12 s; S1…S6 fold.
        let total = Double((1...12).reduce(0, +) + 2)

        XCTAssertEqual(table.othersShare, Double(2 + 3 + 4 + 5 + 6 + 7) / total, accuracy: 1e-9)
        XCTAssertEqual(table.widestShare, table.othersShare, "Others outweighs any single voice here")
        XCTAssertEqual(table.barFraction(table.othersShare), 1)
        XCTAssertEqual(table.barFraction(0), 0)
    }

    func testTheCurrentTurnCountsFromItsStartUntilItGoesStale() throws {
        let you = try XCTUnwrap(table(stage()).rows.first)
        let turn = try XCTUnwrap(you.currentTurn)

        XCTAssertEqual(you.speakingFor(at: turn.upperBound), turn.upperBound - turn.lowerBound)
        XCTAssertNil(
            you.speakingFor(at: turn.upperBound + LiveVoiceStage.currentWindow + 2),
            "an old turn no longer times a new one the microphone just opened")
        XCTAssertNil(try XCTUnwrap(table(stage()).rows.last).speakingFor(at: 0))
    }

    func testAQuietRecordingHasNoCurrentSpeaker() {
        let quiet = stage(now: 500)

        XCTAssertNil(quiet.current)
        XCTAssertFalse(table(quiet).rows.contains(where: \.isSpeaking))
        XCTAssertEqual(table(stage(youSpeaking: true, now: 500)).rows.first?.isSpeaking, true)
    }

    func testAnEmptyStageMakesAnEmptyTable() {
        XCTAssertTrue(LiveVoiceTable(stage: .empty, cast: LiveVoiceStage.empty.cast()).isEmpty)
    }
}
