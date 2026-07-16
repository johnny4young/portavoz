import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class InsightsObservationTests: XCTestCase {
    func testInsightsObservationsRefreshTheirIndependentFactsThroughLifecycle() async throws {
        let store = try MeetingStore.inMemory()
        let now = Date()
        let interval = DateInterval(
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(3_600))
        var meetings = store.observeInsightsMeetings().makeAsyncIterator()
        var facts = store.observeInsightsFacts().makeAsyncIterator()
        var balance = store.observeInsightsVoiceBalance().makeAsyncIterator()
        var findings = store.observeInsightsFindingInputs(in: interval).makeAsyncIterator()

        let initialMeetings = try await nextMeetings(&meetings)
        let initialFacts = try await nextFacts(&facts)
        let initialBalance = try await nextBalance(&balance)
        let initialFindings = try await nextFindingInputs(&findings)
        XCTAssertTrue(initialMeetings.isEmpty)
        XCTAssertEqual(initialFacts.openActionItems, 0)
        XCTAssertFalse(initialBalance.hasData)
        XCTAssertTrue(initialFindings.isEmpty)

        let meeting = Meeting(
            title: "Planning",
            startedAt: now,
            endedAt: now.addingTimeInterval(600))
        try await store.save(meeting)
        let insertedMeetings = try await nextMeetings(&meetings) {
            $0.map(\.id) == [meeting.id]
        }
        XCTAssertEqual(insertedMeetings.first?.id, meeting.id)
        _ = try await nextFacts(&facts)
        _ = try await nextBalance(&balance)
        _ = try await nextFindingInputs(&findings)

        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana",
            isMe: false)
        try await store.save([me, ana])
        let named = try await nextFacts(&facts) {
            $0.topParticipants.map(\.name) == ["Ana"]
        }
        XCTAssertEqual(named.topParticipants.first?.meetings, 1)
        _ = try await nextBalance(&balance)

        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: me.id,
                channel: .microphone,
                text: "Revisemos Qord2M",
                startTime: 0,
                endTime: 4,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: ana.id,
                channel: .system,
                text: "Qord2M sale el viernes",
                startTime: 4,
                endTime: 10,
                isFinal: true),
        ])
        let attributed = try await nextBalance(&balance) { $0.hasData }
        XCTAssertEqual(attributed.participants.map(\.name), ["Ana"])
        let transcript = try await nextFindingInputs(&findings) {
            $0[meeting.id]?.transcript.contains("Qord2M") == true
        }
        XCTAssertEqual(transcript[meeting.id]?.actionItemCount, 0)

        let action = ActionItem(text: "Enviar propuesta")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "## Resumen\n- Pendiente",
            actionItems: [action]))
        let committed = try await nextFacts(&facts) { $0.openActionItems == 1 }
        XCTAssertEqual(committed.doneActionItems, 0)
        let evidence = try await nextFindingInputs(&findings) {
            $0[meeting.id]?.actionItemCount == 1
        }
        XCTAssertNotNil(evidence[meeting.id]?.summaryMarkdown)

        try await store.delete(meeting.id)
        let deletedMeetings = try await nextMeetings(&meetings) { $0.isEmpty }
        let deletedFacts = try await nextFacts(&facts) { $0.topParticipants.isEmpty }
        let deletedBalance = try await nextBalance(&balance) { !$0.hasData }
        let deletedFindings = try await nextFindingInputs(&findings) { $0.isEmpty }
        XCTAssertTrue(deletedMeetings.isEmpty)
        XCTAssertTrue(deletedFacts.topParticipants.isEmpty)
        XCTAssertFalse(deletedBalance.hasData)
        XCTAssertTrue(deletedFindings.isEmpty)

        try await store.restore(meeting.id)
        let restoredMeetings = try await nextMeetings(&meetings) {
            $0.map(\.id) == [meeting.id]
        }
        let restoredFacts = try await nextFacts(&facts) { $0.openActionItems == 1 }
        let restoredBalance = try await nextBalance(&balance) { $0.hasData }
        let restoredFindings = try await nextFindingInputs(&findings) {
            $0[meeting.id] != nil
        }
        XCTAssertEqual(restoredMeetings.first?.id, meeting.id)
        XCTAssertEqual(restoredFacts.topParticipants.map(\.name), ["Ana"])
        XCTAssertTrue(restoredBalance.hasData)
        XCTAssertEqual(restoredFindings.keys.first, meeting.id)
    }

    func testFindingObservationBoundsEvidenceToTheActiveScope() async throws {
        let store = try MeetingStore.inMemory()
        let now = Date()
        let current = Meeting(title: "Current", startedAt: now)
        let previous = Meeting(
            title: "Previous",
            startedAt: now.addingTimeInterval(-14 * 86_400))
        try await store.save(current)
        try await store.save(previous)
        try await store.save([
            TranscriptSegment(
                meetingID: current.id,
                channel: .system,
                text: "Current evidence",
                startTime: 0,
                endTime: 1,
                isFinal: true),
            TranscriptSegment(
                meetingID: previous.id,
                channel: .system,
                text: "Previous evidence",
                startTime: 0,
                endTime: 1,
                isFinal: true),
        ])

        let interval = DateInterval(
            start: now.addingTimeInterval(-7 * 86_400),
            end: now.addingTimeInterval(86_400))
        var findings = store.observeInsightsFindingInputs(in: interval).makeAsyncIterator()
        let value = try await nextFindingInputs(&findings)

        XCTAssertEqual(Set(value.keys), [current.id])
        XCTAssertEqual(value[current.id]?.transcript, "Current evidence")
    }
}

private func nextMeetings(
    _ iterator: inout AsyncThrowingStream<[Meeting], Error>.Iterator,
    until predicate: ([Meeting]) -> Bool = { _ in true }
) async throws -> [Meeting] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw InsightsObservationTestError.expectedValue
}

private func nextFacts(
    _ iterator: inout AsyncThrowingStream<MeetingStore.LibraryFacts, Error>.Iterator,
    until predicate: (MeetingStore.LibraryFacts) -> Bool = { _ in true }
) async throws -> MeetingStore.LibraryFacts {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw InsightsObservationTestError.expectedValue
}

private func nextBalance(
    _ iterator: inout AsyncThrowingStream<MeetingStore.VoiceBalance, Error>.Iterator,
    until predicate: (MeetingStore.VoiceBalance) -> Bool = { _ in true }
) async throws -> MeetingStore.VoiceBalance {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw InsightsObservationTestError.expectedValue
}

private func nextFindingInputs(
    _ iterator: inout AsyncThrowingStream<[MeetingID: MeetingStore.FindingInput], Error>.Iterator,
    until predicate: ([MeetingID: MeetingStore.FindingInput]) -> Bool = { _ in true }
) async throws -> [MeetingID: MeetingStore.FindingInput] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw InsightsObservationTestError.expectedValue
}

private enum InsightsObservationTestError: Error {
    case expectedValue
}
