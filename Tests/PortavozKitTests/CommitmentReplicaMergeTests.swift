import XCTest
@testable import PortavozCore

final class CommitmentReplicaMergeTests: XCTestCase {
    private let commitmentID = CommitmentID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!)
    private let sourceID = CommitmentSourceID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001002")!)
    private let confirmID = CommitmentEventID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001003")!)

    func testDisjointValidHistoriesMergeCommutatively() throws {
        let reassign = event(
            id: "00000000-0000-0000-0000-000000001004",
            kind: .reassign,
            assignee: .me,
            occurredAt: 20)
        let reschedule = event(
            id: "00000000-0000-0000-0000-000000001005",
            kind: .reschedule,
            dueAt: Date(timeIntervalSince1970: 500),
            occurredAt: 30)
        let local = try envelope(events: [confirmEvent(), reassign])
        let remote = try envelope(events: [confirmEvent(), reschedule])

        let forward = try CommitmentReplicaMerge.merge(local: local, remote: remote)
        let reverse = try CommitmentReplicaMerge.merge(local: remote, remote: local)

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.events, [confirmEvent(), reassign, reschedule])
        XCTAssertEqual(forward.commitment.assignee, .me)
        XCTAssertEqual(forward.commitment.dueAt, Date(timeIntervalSince1970: 500))
    }

    func testMergeIsIdempotentAndAssociativeForAppendOnlySources() throws {
        let second = source(
            id: "00000000-0000-0000-0000-000000001006",
            firstSeenAt: 20)
        let third = source(
            id: "00000000-0000-0000-0000-000000001007",
            firstSeenAt: 30)
        let base = try envelope()
        let withSecond = try envelope(sources: [source(), second])
        let withThird = try envelope(sources: [source(), third])

        XCTAssertEqual(
            try CommitmentReplicaMerge.merge(local: base, remote: base),
            base)
        let left = try CommitmentReplicaMerge.merge(
            local: CommitmentReplicaMerge.merge(local: base, remote: withSecond),
            remote: withThird)
        let right = try CommitmentReplicaMerge.merge(
            local: base,
            remote: CommitmentReplicaMerge.merge(local: withSecond, remote: withThird))
        XCTAssertEqual(left, right)
        XCTAssertEqual(left.sources, [source(), second, third])
    }

    func testSameSourceIdentityCannotRewriteImmutableMaterial() throws {
        let local = try envelope()
        let rewritten = source(titleOrdinal: 1)
        let remote = try envelope(sources: [rewritten])

        XCTAssertThrowsError(try CommitmentReplicaMerge.merge(
            local: local,
            remote: remote)) { error in
                XCTAssertEqual(
                    error as? CommitmentReplicaMergeError,
                    .immutableSourceRewrite(self.sourceID))
            }
    }

    func testSameEventIdentityCannotRewriteImmutableMaterial() throws {
        let eventID = "00000000-0000-0000-0000-000000001008"
        let localEvent = event(id: eventID, kind: .reassign, assignee: .me, occurredAt: 20)
        let remoteEvent = event(
            id: eventID,
            kind: .reassign,
            assignee: .unassigned,
            occurredAt: 20)

        XCTAssertThrowsError(try CommitmentReplicaMerge.merge(
            local: envelope(events: [confirmEvent(), localEvent]),
            remote: envelope(events: [confirmEvent(), remoteEvent]))) { error in
                XCTAssertEqual(
                    error as? CommitmentReplicaMergeError,
                    .immutableEventRewrite(localEvent.id))
            }
    }

    func testTitleRewriteFailsClosed() throws {
        XCTAssertThrowsError(try CommitmentReplicaMerge.merge(
            local: envelope(title: "Ship the brief"),
            remote: envelope(title: "Rewrite the brief"))) { error in
                XCTAssertEqual(
                    error as? CommitmentReplicaMergeError,
                    .immutableTitleRewrite(self.commitmentID))
            }
    }

    func testConcurrentLifecycleThatCannotBeReplayedFailsClosed() throws {
        let complete = event(
            id: "00000000-0000-0000-0000-000000001009",
            kind: .complete,
            occurredAt: 20)
        let reassign = event(
            id: "00000000-0000-0000-0000-000000001010",
            kind: .reassign,
            assignee: .me,
            occurredAt: 30)

        XCTAssertThrowsError(try CommitmentReplicaMerge.merge(
            local: envelope(events: [confirmEvent(), complete]),
            remote: envelope(events: [confirmEvent(), reassign]))) { error in
                XCTAssertEqual(
                    error as? CommitmentReplicaMergeError,
                    .lifecycleConflict)
            }
    }

    func testDifferentCommitmentsNeverMerge() throws {
        let otherID = CommitmentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001011")!)
        XCTAssertThrowsError(try CommitmentReplicaMerge.merge(
            local: envelope(),
            remote: envelope(commitmentID: otherID))) { error in
                XCTAssertEqual(
                    error as? CommitmentReplicaMergeError,
                    .differentCommitment)
            }
    }

    private func envelope(
        commitmentID: CommitmentID? = nil,
        title: String = "Ship the brief",
        sources: [CommitmentSource]? = nil,
        events: [CommitmentEvent]? = nil
    ) throws -> CommitmentContinuityEnvelope {
        let id = commitmentID ?? self.commitmentID
        let history = events ?? [confirmEvent(commitmentID: id)]
        return try CommitmentContinuityEnvelope(
            commitment: CommitmentContinuityPolicy.projectedCommitment(
                id: id,
                title: title,
                events: history),
            sources: sources ?? [source(commitmentID: id)],
            events: history)
    }

    private func source(
        id: String? = nil,
        commitmentID: CommitmentID? = nil,
        firstSeenAt: TimeInterval = 10,
        titleOrdinal: Int = 0
    ) -> CommitmentSource {
        CommitmentSource(
            id: id.map { CommitmentSourceID(rawValue: UUID(uuidString: $0)!) } ?? sourceID,
            commitmentID: commitmentID ?? self.commitmentID,
            kind: .manual,
            meetingID: titleOrdinal == 0 ? nil : MeetingID(),
            firstSeenAt: Date(timeIntervalSince1970: firstSeenAt))
    }

    private func confirmEvent(
        commitmentID: CommitmentID? = nil
    ) -> CommitmentEvent {
        CommitmentEvent(
            id: confirmID,
            commitmentID: commitmentID ?? self.commitmentID,
            kind: .confirm,
            assignee: .unassigned,
            occurredAt: Date(timeIntervalSince1970: 10))
    }

    private func event(
        id: String,
        kind: CommitmentEventKind,
        assignee: CommitmentAssignee? = nil,
        dueAt: Date? = nil,
        occurredAt: TimeInterval
    ) -> CommitmentEvent {
        CommitmentEvent(
            id: CommitmentEventID(rawValue: UUID(uuidString: id)!),
            commitmentID: commitmentID,
            kind: kind,
            assignee: assignee,
            dueAt: dueAt,
            occurredAt: Date(timeIntervalSince1970: occurredAt))
    }
}
