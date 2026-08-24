import IntelligenceKit
import PortavozCore
import XCTest

@testable import portavoz_app

final class ProactiveMeetingAssistPolicyTests: XCTestCase {
    func testOpenObjectiveCarriesExactBoundedFinalizedEvidence() throws {
        let meetingID = MeetingID()
        let captions = conversation(meetingID: meetingID)
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")

        let suggestion = try XCTUnwrap(
            ProactiveMeetingAssistPolicy.nextSuggestion(
                captions: captions,
                pendingObjectives: [objective],
                emittedSignals: [],
                lastEmissionOffset: nil))

        XCTAssertEqual(suggestion.kind, .openObjective)
        XCTAssertEqual(suggestion.objective, objective)
        XCTAssertEqual(suggestion.evidence.meetingID, meetingID)
        XCTAssertEqual(suggestion.evidence.segmentIDs.count, 16)
        XCTAssertEqual(suggestion.evidence.startTime, 40)
        XCTAssertEqual(suggestion.evidence.endTime, 345)
        XCTAssertEqual(suggestion.evidence.speechSeconds, 80)
        XCTAssertEqual(suggestion.signalKey, .objective(objective.id))
    }

    func testTalkBalanceRequiresMeasuredVolumeAndExactThreshold() throws {
        let captions = conversation(meetingID: MeetingID()) { index in
            index < 14 ? .microphone : .system
        }
        let suggestion = try XCTUnwrap(
            ProactiveMeetingAssistPolicy.nextSuggestion(
                captions: captions,
                pendingObjectives: [],
                emittedSignals: [],
                lastEmissionOffset: nil))

        XCTAssertEqual(suggestion.kind, .talkBalance)
        XCTAssertEqual(suggestion.signalKey, .talkBalance)
        XCTAssertEqual(suggestion.measuredUserFraction ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(suggestion.evidence.segmentIDs.count, 16)
    }

    func testPolicyWithholdsSignalsWithoutEnoughEvidence() {
        let meetingID = MeetingID()
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: conversation(meetingID: meetingID, count: 7),
            pendingObjectives: [objective],
            emittedSignals: [],
            lastEmissionOffset: nil))
        XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: conversation(meetingID: meetingID) { _ in .system },
            pendingObjectives: [],
            emittedSignals: [],
            lastEmissionOffset: nil))
        XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: [],
            pendingObjectives: [objective],
            emittedSignals: [],
            lastEmissionOffset: nil))
    }

    func testSignalIdentityAndGlobalIntervalPreventRepeatedCards() {
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let captions = conversation(meetingID: MeetingID())
        XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: captions,
            pendingObjectives: [objective],
            emittedSignals: [.objective(objective.id)],
            lastEmissionOffset: nil))
        XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: captions,
            pendingObjectives: [objective],
            emittedSignals: [],
            lastEmissionOffset: 200))
        XCTAssertNotNil(ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: captions,
            pendingObjectives: [objective],
            emittedSignals: [],
            lastEmissionOffset: 160))
    }

    func testObjectivePriorityFallsThroughToTalkBalanceAfterObjectiveEmission() throws {
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let captions = conversation(meetingID: MeetingID()) { index in
            index < 14 ? .microphone : .system
        }
        let suggestion = try XCTUnwrap(
            ProactiveMeetingAssistPolicy.nextSuggestion(
                captions: captions,
                pendingObjectives: [objective],
                emittedSignals: [.objective(objective.id)],
                lastEmissionOffset: nil))

        XCTAssertEqual(suggestion.kind, .talkBalance)
        XCTAssertEqual(suggestion.measuredUserFraction ?? 0, 0.75, accuracy: 0.001)
    }

    func testMalformedOrCrossMeetingEvidenceFailsClosed() {
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let meetingID = MeetingID()
        var crossMeeting = conversation(meetingID: meetingID)
        crossMeeting[4] = row(
            meetingID: MeetingID(),
            index: 4,
            channel: .microphone)
        XCTAssertNil(candidate(crossMeeting, objective: objective))

        var crossMeetingTail = conversation(meetingID: meetingID)
        crossMeetingTail[crossMeetingTail.count - 1] = TranscriptSegment(
            meetingID: MeetingID(),
            channel: .system,
            text: "Foreign mutable tail",
            startTime: 360,
            endTime: 361,
            isFinal: false)
        XCTAssertNil(candidate(crossMeetingTail, objective: objective))

        var duplicateTail = conversation(meetingID: meetingID)
        duplicateTail[duplicateTail.count - 1] = TranscriptSegment(
            id: duplicateTail[3].id,
            meetingID: meetingID,
            channel: .system,
            text: "Duplicate mutable identity",
            startTime: 360,
            endTime: 361,
            isFinal: false)
        XCTAssertNil(candidate(duplicateTail, objective: objective))

        var outOfOrderTail = conversation(meetingID: meetingID)
        outOfOrderTail[outOfOrderTail.count - 1] = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Out-of-order mutable tail",
            startTime: 1,
            endTime: 2,
            isFinal: false)
        XCTAssertNil(candidate(outOfOrderTail, objective: objective))

        var duplicate = conversation(meetingID: meetingID)
        duplicate[4] = TranscriptSegment(
            id: duplicate[3].id,
            meetingID: meetingID,
            channel: .microphone,
            text: "Duplicate identity",
            startTime: 80,
            endTime: 85,
            isFinal: true)
        XCTAssertNil(candidate(duplicate, objective: objective))

        var reversed = conversation(meetingID: meetingID)
        reversed.swapAt(3, 4)
        XCTAssertNil(candidate(reversed, objective: objective))

        var oversized = conversation(meetingID: meetingID)
        oversized[3].text = String(repeating: "x", count: 4_001)
        XCTAssertNil(candidate(oversized, objective: objective))

        var oversizedBytes = conversation(meetingID: meetingID)
        oversizedBytes[3].text = String(repeating: "👩🏽‍💻", count: 1_200)
        XCTAssertLessThanOrEqual(oversizedBytes[3].text.count, 4_000)
        XCTAssertGreaterThan(oversizedBytes[3].text.utf8.count, 16_384)
        XCTAssertNil(candidate(oversizedBytes, objective: objective))
    }

    func testNonFinalInvalidTimeAndThrottleAuthorityFailClosed() {
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let meetingID = MeetingID()

        var nonFinal = conversation(meetingID: meetingID)
        nonFinal[3] = row(
            meetingID: meetingID,
            index: 3,
            channel: .microphone,
            isFinal: false)
        XCTAssertNil(candidate(nonFinal, objective: objective))

        var nonFinite = conversation(meetingID: meetingID)
        nonFinite[3] = row(
            meetingID: meetingID,
            index: 3,
            channel: .microphone,
            startTime: .nan,
            endTime: 65)
        XCTAssertNil(candidate(nonFinite, objective: objective))

        var reversedTime = conversation(meetingID: meetingID)
        reversedTime[3] = row(
            meetingID: meetingID,
            index: 3,
            channel: .microphone,
            startTime: 70,
            endTime: 65)
        XCTAssertNil(candidate(reversedTime, objective: objective))

        var pathologicalDuration = conversation(meetingID: meetingID)
        pathologicalDuration[3] = row(
            meetingID: meetingID,
            index: 3,
            channel: .microphone,
            startTime: 60,
            endTime: 361)
        XCTAssertNil(candidate(pathologicalDuration, objective: objective))

        var nonFiniteTail = conversation(meetingID: meetingID)
        nonFiniteTail[nonFiniteTail.count - 1] = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Invalid mutable tail",
            startTime: .nan,
            endTime: 361,
            isFinal: false)
        XCTAssertNil(candidate(nonFiniteTail, objective: objective))

        XCTAssertNil(candidate(
            conversation(
                meetingID: meetingID,
                timelineOffset: ProactiveMeetingAssistPolicy.maximumTimelineOffset + 1),
            objective: objective))

        for invalidOffset in [TimeInterval.nan, -TimeInterval.infinity, -1] {
            XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
                captions: conversation(meetingID: meetingID),
                pendingObjectives: [objective],
                emittedSignals: [],
                lastEmissionOffset: invalidOffset))
        }
    }

    func testObjectiveAuthorityRejectsWhitespaceOversizeAndDuplicateIdentity() {
        let captions = conversation(meetingID: MeetingID())
        let id = UUID()
        for objectives in [
            [ProactiveAssistObjective(id: id, text: " padded ")],
            [ProactiveAssistObjective(id: id, text: String(repeating: "x", count: 281))],
            [ProactiveAssistObjective(
                id: id,
                text: String(repeating: "👩🏽‍💻", count: 140))],
            [
                ProactiveAssistObjective(id: id, text: "First"),
                ProactiveAssistObjective(id: id, text: "Second")
            ],
            (0..<9).map {
                ProactiveAssistObjective(id: UUID(), text: "Objective \($0)")
            },
        ] {
            XCTAssertNil(ProactiveMeetingAssistPolicy.nextSuggestion(
                captions: captions,
                pendingObjectives: objectives,
                emittedSignals: [],
                lastEmissionOffset: nil))
        }
    }

    func testSourceWorkStaysIndependentOfMeetingLength() throws {
        let meetingID = MeetingID()
        let captions = conversation(
            meetingID: meetingID,
            count: 2_000,
            spacing: 4,
            duration: 2)
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let suggestion = try XCTUnwrap(candidate(captions, objective: objective))

        XCTAssertEqual(
            suggestion.evidence.segmentIDs.count,
            ProactiveMeetingAssistPolicy.maximumSourceRows)
        XCTAssertFalse(suggestion.evidence.segmentIDs.contains(captions[0].id))
    }

    private func candidate(
        _ captions: [TranscriptSegment],
        objective: ProactiveAssistObjective
    ) -> ProactiveAssistSuggestion? {
        ProactiveMeetingAssistPolicy.nextSuggestion(
            captions: captions,
            pendingObjectives: [objective],
            emittedSignals: [],
            lastEmissionOffset: nil)
    }

    private func conversation(
        meetingID: MeetingID,
        count: Int = 18,
        spacing: TimeInterval = 20,
        duration: TimeInterval = 5,
        timelineOffset: TimeInterval = 0,
        channel: (Int) -> AudioChannel = { $0.isMultiple(of: 2) ? .system : .microphone }
    ) -> [TranscriptSegment] {
        let closed = (0..<count).map { index in
            row(
                meetingID: meetingID,
                index: index,
                channel: channel(index),
                startTime: timelineOffset + TimeInterval(index) * spacing,
                endTime: timelineOffset + TimeInterval(index) * spacing + duration)
        }
        return closed + [TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Still growing",
            startTime: timelineOffset + TimeInterval(count) * spacing,
            endTime: timelineOffset + TimeInterval(count) * spacing + 1,
            isFinal: false)]
    }

    private func row(
        meetingID: MeetingID,
        index: Int,
        channel: AudioChannel,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        let start = startTime ?? TimeInterval(index * 20)
        return TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: "Finalized source turn \(index)",
            startTime: start,
            endTime: endTime ?? start + 5,
            isFinal: isFinal)
    }
}

@MainActor
final class RecordingProactiveAssistModelTests: XCTestCase {
    func testExplicitOptInPauseResumeDisableAndResetAreSynchronous() {
        let model = RecordingProactiveAssistModel()
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let captions = conversation(count: 18)

        model.observe(captions: captions, pendingObjectives: [objective])
        XCTAssertTrue(model.suggestions.isEmpty)

        model.setEnabled(true, captions: captions, pendingObjectives: [objective])
        XCTAssertEqual(model.suggestions.count, 1)
        model.setPaused(true, captions: captions, pendingObjectives: [objective])
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.suggestions.count, 1)

        let second = ProactiveAssistObjective(id: UUID(), text: "Review launch risks")
        model.observe(
            captions: conversation(count: 28),
            pendingObjectives: [objective, second])
        XCTAssertEqual(model.suggestions.count, 1)
        model.setPaused(
            false,
            captions: conversation(count: 28),
            pendingObjectives: [objective, second])
        XCTAssertEqual(model.suggestions.count, 2)

        model.setEnabled(
            false,
            captions: conversation(count: 28),
            pendingObjectives: [objective, second])
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertFalse(model.isPaused)
        model.reset()
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.suggestions.isEmpty)
        model.setEnabled(true, captions: captions, pendingObjectives: [objective])
        XCTAssertEqual(
            model.suggestions.map(\.signalKey),
            [.objective(objective.id)],
            "a new recording lifecycle may emit the same objective identity again")
    }

    func testDismissAndReenableCannotRepeatTheSameSignal() throws {
        let model = RecordingProactiveAssistModel()
        let objective = ProactiveAssistObjective(id: UUID(), text: "Confirm Q3 budget")
        let captions = conversation(count: 18)
        model.setEnabled(true, captions: captions, pendingObjectives: [objective])
        let id = try XCTUnwrap(model.suggestions.first?.id)
        model.dismiss(id)

        model.setEnabled(false, captions: captions, pendingObjectives: [objective])
        model.setEnabled(true, captions: captions, pendingObjectives: [objective])
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    func testVisibleCardsStayCappedAndObjectiveClosureRetractsItsCard() {
        let model = RecordingProactiveAssistModel()
        let objectives = (0..<4).map {
            ProactiveAssistObjective(id: UUID(), text: "Objective \($0)")
        }
        model.setEnabled(
            true,
            captions: conversation(count: 18),
            pendingObjectives: objectives)
        model.observe(captions: conversation(count: 28), pendingObjectives: objectives)
        model.observe(captions: conversation(count: 38), pendingObjectives: objectives)
        model.observe(captions: conversation(count: 48), pendingObjectives: objectives)
        XCTAssertEqual(
            model.suggestions.count,
            ProactiveMeetingAssistPolicy.maximumVisibleSuggestions)

        model.setPaused(true, captions: [], pendingObjectives: objectives)
        let closedID = objectives[0].id
        model.observe(
            captions: [],
            pendingObjectives: objectives.filter { $0.id != closedID })
        XCTAssertFalse(model.suggestions.contains {
            $0.signalKey == .objective(closedID)
        })
    }

    private func conversation(count: Int) -> [TranscriptSegment] {
        let meetingID = MeetingID(rawValue: UUID(uuidString:
            "00000000-0000-0000-0000-000000000901")!)
        let closed = (0..<count).map { index in
            let start = TimeInterval(index * 20)
            return TranscriptSegment(
                meetingID: meetingID,
                channel: index.isMultiple(of: 2) ? .system : .microphone,
                text: "Finalized source turn \(index)",
                startTime: start,
                endTime: start + 5,
                isFinal: true)
        }
        return closed + [TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Still growing",
            startTime: TimeInterval(count * 20),
            endTime: TimeInterval(count * 20 + 1),
            isFinal: false)]
    }
}
