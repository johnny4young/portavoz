import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import XCTest

final class LiveVoiceStageTests: XCTestCase {
    private let meetingID = MeetingID()

    private func row(
        _ channel: AudioChannel, _ start: TimeInterval, _ end: TimeInterval, id: UUID = UUID()
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id, meetingID: meetingID, channel: channel, text: "words",
            startTime: start, endTime: end, isFinal: true)
    }

    private func source(
        _ captions: [TranscriptSegment],
        labels: [UUID: String] = [:],
        latestTurn: SpeakerTurn? = nil,
        youSpeaking: Bool = false,
        now: TimeInterval? = nil,
        notes: [ContextItem] = [],
        questions: [CompanionCard] = []
    ) -> LiveVoiceSource {
        LiveVoiceSource(
            captions: captions, labels: labels, latestTurn: latestTurn, youSpeaking: youSpeaking,
            now: now ?? (captions.map(\.endTime).max() ?? 0),
            notes: notes, questions: questions)
    }

    func testVoicesCarryTurnsTalkTimeAndLastHeard() {
        let mine = row(.microphone, 0, 4)
        let first = row(.system, 4, 10)
        let second = row(.system, 10, 12)
        let mineAgain = row(.microphone, 12, 15)
        let echo = row(.system, 15, 16)
        let open = row(.system, 17, 18)
        let stage = LiveVoiceStage.updating(.empty, with: source(
            [mine, first, second, mineAgain, echo, open],
            labels: [first.id: "S1", second.id: "S1", echo.id: "Me"]))

        XCTAssertEqual(stage.voices.map(\.key), ["you", "S1", "remote"], "first heard first")
        let you = try? XCTUnwrap(stage.voice("you"))
        XCTAssertEqual(you?.turns, [0...4, 12...16], "the voiceprint's Me joins your microphone")
        XCTAssertEqual(you?.talkSeconds, 8)
        XCTAssertEqual(you?.lastHeard, 16)
        XCTAssertEqual(stage.voice("S1")?.turns, [4...12], "back-to-back rows of one voice are one turn")
        XCTAssertEqual(stage.voice("remote")?.turns, [17...18], "the growing row waits for a label")
    }

    func testOverlappingRowsOfOneVoiceCountTheirTalkOnce() {
        let mine = row(.microphone, 0, 4)
        let echo = row(.system, 2, 5)
        let stage = LiveVoiceStage.updating(.empty, with: source(
            [mine, echo, row(.system, 6, 7)], labels: [echo.id: "Me"]))

        XCTAssertEqual(stage.voice("you")?.talkSeconds, 5)
    }

    func testCurrentSpeakerIsYouWhileTheMicrophoneSpeaksThenTheOpenRow() {
        let closed = row(.system, 0, 5)
        let open = row(.system, 5, 9)
        let captions = [closed, open]
        let turn = SpeakerTurn(voiceLabel: "S2", startTime: 4, endTime: 9)

        XCTAssertEqual(
            LiveVoiceStage.updating(.empty, with: source(captions, latestTurn: turn, youSpeaking: true)).current,
            "you")
        let remote = LiveVoiceStage.updating(
            .empty, with: source(captions, labels: [closed.id: "S1"], latestTurn: turn))
        XCTAssertEqual(remote.current, "S2", "the newest diarizer turn names the open row")
        XCTAssertEqual(remote.voice("S2")?.turns, [5...9])
        XCTAssertEqual(LiveVoiceStage.updating(.empty, with: source(captions)).current, "remote")
        XCTAssertNil(
            LiveVoiceStage.updating(
                .empty, with: source(captions, now: 9 + LiveVoiceStage.currentWindow + 0.5)).current,
            "a quiet room has no current speaker")
        let stale = SpeakerTurn(voiceLabel: "S2", startTime: 0, endTime: 4)
        XCTAssertEqual(
            LiveVoiceStage.updating(.empty, with: source(captions, latestTurn: stale)).current, "remote",
            "a turn that ended before the open row cannot name it")
    }

    /// The live diarizer keeps revising: it splits a closed row into new ids,
    /// swaps labels and labels rows it skipped. Each pass must equal a fresh
    /// build from the same captions, so churn never leaves stale turns.
    func testRelabelChurnAlwaysMatchesAFreshBuild() {
        let shared = UUID()
        let opening = row(.microphone, 0, 3)
        let long = row(.system, 3, 13, id: shared)
        let open = row(.system, 14, 15)
        let splitHead = TranscriptSegment(
            id: shared, meetingID: meetingID, channel: .system, text: "words",
            startTime: 3, endTime: 8, isFinal: true)
        let splitTail = row(.system, 8, 13)
        let passes: [LiveVoiceSource] = [
            source([opening, long, open], now: 15),
            source([opening, long, open], labels: [shared: "S1"], now: 16),
            source([opening, splitHead, splitTail, open], labels: [shared: "S1", splitTail.id: "S2"], now: 17),
            source([opening, splitHead, splitTail, open], labels: [shared: "S2", splitTail.id: "S1"], now: 18),
            source([opening, splitHead, splitTail, open], labels: [shared: "S2", splitTail.id: "Me"], now: 19),
            source([opening, splitHead, splitTail, open], labels: [:], now: 20)
        ]

        var stage = LiveVoiceStage.empty
        for pass in passes {
            stage = LiveVoiceStage.updating(stage, with: pass)
            let fresh = LiveVoiceStage.updating(.empty, with: pass)
            XCTAssertEqual(stage.voices, fresh.voices)
            XCTAssertEqual(stage.current, fresh.current)
            XCTAssertEqual(
                Self.resolved(stage.columns), Self.resolved(fresh.columns),
                "tail rebinning must agree with a full rebuild")
        }
        XCTAssertEqual(stage.voices.map(\.key), ["you", "remote"], "relabels that disappear leave no voice behind")
        XCTAssertEqual(stage.voice("you")?.talkSeconds, 3)
    }

    func testOnlyTheChangedTailRebins() {
        let first = row(.microphone, 0, 10)
        let second = row(.system, 10, 20)
        let open = row(.system, 21, 25)
        let start = LiveVoiceStage.updating(.empty, with: source([first, second, open], now: 25))
        XCTAssertEqual(start.columns.rebinnedFrom, 0)
        XCTAssertEqual(start.columns.values.count, 25)

        let grown = row(.system, 21, 30, id: open.id)
        let growth = LiveVoiceStage.updating(start, with: source([first, second, grown], now: 30))
        XCTAssertEqual(growth.columns.rebinnedFrom, 21, "the growing row rebins from its own start")
        XCTAssertEqual(Array(growth.columns.values.prefix(21)), Array(start.columns.values.prefix(21)))

        let later = LiveVoiceStage.updating(growth, with: source([first, second, grown], now: 33))
        XCTAssertEqual(later.columns.rebinnedFrom, 30, "time alone only adds columns")
        XCTAssertEqual(later.columns.values.count, 33)
        XCTAssertEqual(Array(later.columns.values.suffix(3)), Array(repeating: VoiceColumns.silence, count: 3))

        let relabel = LiveVoiceStage.updating(
            later, with: source([first, second, grown], labels: [second.id: "S1"], now: 33))
        XCTAssertEqual(relabel.columns.rebinnedFrom, 10)
        XCTAssertEqual(Self.resolved(relabel.columns).prefix(12), Array(repeating: "you", count: 10) + ["S1", "S1"])
    }

    func testIndexesNeverMoveSoTheStripKeepsItsColours() {
        let mine = row(.microphone, 0, 2)
        let theirs = row(.system, 2, 4)
        let first = LiveVoiceStage.updating(.empty, with: source([mine, theirs, row(.system, 5, 6)]))
        let relabelled = LiveVoiceStage.updating(first, with: source(
            [mine, theirs, row(.system, 5, 6)], labels: [theirs.id: "S1"]))

        XCTAssertEqual(relabelled.columns.keys, ["you", "remote", "S1"])
        let cast = relabelled.cast()
        let strip = relabelled.strip(cast: cast)
        XCTAssertEqual(strip.tints, [.you, .grey, .grey], "live voices are unnamed and grey")
        XCTAssertEqual(strip.columns, relabelled.columns.values)
        XCTAssertEqual(strip.duration, 6)
    }

    func testALongRecordingBinsPastTheSingleCallColumnLimit() {
        let hours = 3.0 * 3_600
        let captions = stride(from: 0.0, to: hours, by: 60).map {
            row(Int($0 / 60).isMultiple(of: 2) ? .microphone : .system, $0, $0 + 50)
        }
        let stage = LiveVoiceStage.updating(.empty, with: source(captions, now: hours))

        XCTAssertEqual(stage.columns.values.count, Int(hours))
        XCTAssertEqual(stage.columns.values[7_200 + 25], stage.columns.values[25], "every two minutes repeats")
        XCTAssertEqual(stage.columns.values[7_200 + 55], VoiceColumns.silence)
    }

    func testMoreVoicesThanTheColumnsCanIndexKeepTheFirstOnes() {
        let captions = (0..<300).map { row(.system, Double($0), Double($0) + 1) } + [row(.system, 300, 301)]
        let labels = Dictionary(uniqueKeysWithValues: captions.dropLast().enumerated().map { ($1.id, "S\($0)") })
        let stage = LiveVoiceStage.updating(.empty, with: source(captions, labels: labels))

        XCTAssertEqual(stage.columns.keys.count, VoiceColumns.maximumVoices)
        XCTAssertEqual(stage.columns.values.count, 301)
        XCTAssertEqual(stage.columns.values[299], VoiceColumns.silence, "a voice past the cap stays silence")
        XCTAssertEqual(stage.voices.count, 301, "every voice still has its turns")
    }

    func testNothingLiveRunsPastTheClock() {
        let growing = row(.microphone, 10, 30)
        let ahead = row(.system, 26, 28)
        let stage = LiveVoiceStage.updating(.empty, with: source([growing, ahead], now: 20))
        XCTAssertEqual(stage.columns.duration, 20, "the strip stops at now")
        XCTAssertEqual(stage.voice(LiveVoiceStage.youKey)?.talkSeconds, 10)
        XCTAssertEqual(stage.voice(LiveVoiceStage.youKey)?.lastHeard, 20)
        XCTAssertNil(stage.voice(LiveVoiceStage.unlabelledKey), "a row that starts after now is not heard yet")
    }

    func testEveryLiveSurfaceSharesOneVoiceKeyRule() {
        let mine = row(.microphone, 0, 1)
        let matched = row(.system, 1, 2)
        let labelled = row(.system, 2, 3)
        let unknown = row(.system, 3, 4)
        let labels = [mine.id: "S1", matched.id: "Me", labelled.id: "S2"]

        XCTAssertEqual(
            [mine, matched, labelled, unknown].map { LiveVoiceStage.key(for: $0, labels: labels) },
            ["you", "you", "S2", "remote"])
    }

    func testTicksMarkYourNotesAndWhoAskedYou() throws {
        let question = row(.system, 30, 34)
        let note = ContextItem(meetingID: meetingID, kind: .note, content: "follow up", timestamp: 40)
        let objective = ContextItem(meetingID: meetingID, kind: .objective, content: "agenda", timestamp: 5)
        let asked = CompanionCard(
            question: "When do the dashboards move?", answer: "", kind: .context, source: "on-device",
            directed: true, askedAt: 30)
        let card = asked.withEvidence(CompanionCardEvidence(cardID: asked.id, questionSegmentIDs: [question.id]))
        let unsourced = CompanionCard(
            question: "Anyone?", answer: "", kind: .knowledge, source: "on-device", askedAt: 50)

        let stage = LiveVoiceStage.updating(.empty, with: source(
            [question, row(.microphone, 35, 38)], labels: [question.id: "S2"],
            notes: [note, objective], questions: [unsourced, card]))

        XCTAssertEqual(stage.ticks.map(\.time), [30, 40, 50], "objectives are not notes; ticks run in time order")
        XCTAssertEqual(stage.ticks[0], .init(id: card.id, kind: .askedYou(by: "S2"), time: 30))
        XCTAssertEqual(stage.ticks[1], .init(id: note.id, kind: .note, time: 40))
        XCTAssertEqual(stage.ticks[2].kind, .askedYou(by: nil))
    }

    func testTheLiveCastLeadsWithTheCurrentSpeakerThenRecency() {
        let captions = [
            row(.system, 0, 5), row(.microphone, 5, 8), row(.system, 8, 12), row(.system, 13, 14)
        ]
        let labels = [captions[0].id: "S1", captions[2].id: "S2"]
        let stage = LiveVoiceStage.updating(.empty, with: source(captions, labels: labels, youSpeaking: true))

        XCTAssertEqual(stage.cast().voices.map(\.key), ["you", "remote", "S2", "S1"])
    }

    private static func resolved(_ columns: LiveVoiceColumns) -> [String] {
        columns.values.map { $0 == VoiceColumns.silence ? "-" : columns.keys[Int($0)] }
    }
}
