import Foundation
import XCTest
@testable import PortavozCore

final class DeferredMacWorkTests: XCTestCase {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000002001")!)
    private let sourceDeviceID = UUID(
        uuidString: "00000000-0000-0000-0000-000000002002")!
    private let ownerDeviceID = UUID(
        uuidString: "00000000-0000-0000-0000-000000002003")!
    private let secondOwnerDeviceID = UUID(
        uuidString: "00000000-0000-0000-0000-000000002004")!
    private let leaseToken = UUID(
        uuidString: "00000000-0000-0000-0000-000000002005")!
    private let secondLeaseToken = UUID(
        uuidString: "00000000-0000-0000-0000-000000002006")!
    private let inputFingerprint = String(repeating: "a", count: 64)
    private let resultFingerprint = String(repeating: "b", count: 64)

    func testRequestIdempotencyIgnoresTransportIdentityButFencesInput() throws {
        let first = try request()
        let retry = try request(
            id: UUID(),
            sourceDeviceID: UUID())
        let changed = try request(sourceTranscriptRevision: 8)

        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, changed.idempotencyKey)
        XCTAssertEqual(first.idempotencyKey.utf8.count, 64)
    }

    func testRequestRejectsUnboundedOrNonDigestMaterial() {
        XCTAssertThrowsError(try request(inputFingerprint: "/private/audio.caf"))
        XCTAssertThrowsError(try request(maxAttempts: 4))
        XCTAssertThrowsError(try request(sourceTranscriptRevision: -1))
        XCTAssertThrowsError(try request(
            requestedAt: Date(timeIntervalSinceReferenceDate: .infinity)))
    }

    func testClaimRunRenewAndSuccessAreRevisionedAndReplaySafe() throws {
        let queued = DeferredMacWorkSnapshot.queued(request: try request())
        let claimed = try transition(
            .claim(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                leaseExpiresAt: date(110)),
            queued,
            at: 100)
        let running = try transition(
            .start(ownerDeviceID: ownerDeviceID, leaseToken: leaseToken),
            claimed,
            at: 101)
        let renewed = try transition(
            .renew(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                leaseExpiresAt: date(120)),
            running,
            at: 105)
        let successCommand = DeferredMacWorkTransition.succeed(
            ownerDeviceID: ownerDeviceID,
            leaseToken: leaseToken,
            resultFingerprint: resultFingerprint,
            currentInputFingerprint: inputFingerprint,
            currentTranscriptRevision: 7)
        let succeeded = try transition(successCommand, renewed, at: 106)

        XCTAssertEqual(claimed.state, .claimed)
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(renewed.revision, 3)
        XCTAssertEqual(succeeded.state, .succeeded)
        XCTAssertEqual(succeeded.resultFingerprint, resultFingerprint)
        XCTAssertEqual(
            try DeferredMacWorkPolicy.apply(
                successCommand,
                to: succeeded,
                expectedRevision: renewed.revision,
                at: date(107)),
            succeeded)
        XCTAssertThrowsError(try DeferredMacWorkPolicy.apply(
            .succeed(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                resultFingerprint: resultFingerprint,
                currentInputFingerprint: String(repeating: "c", count: 64),
                currentTranscriptRevision: 7),
            to: succeeded,
            expectedRevision: renewed.revision,
            at: date(107))) { error in
                XCTAssertEqual(error as? DeferredMacWorkContractError, .staleRevision)
        }
    }

    func testOneClaimOwnerWinsAndStaleRevisionFailsClosed() throws {
        let queued = DeferredMacWorkSnapshot.queued(request: try request())
        let claimed = try transition(
            .claim(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                leaseExpiresAt: date(110)),
            queued,
            at: 100)

        XCTAssertThrowsError(try DeferredMacWorkPolicy.apply(
            .claim(
                ownerDeviceID: secondOwnerDeviceID,
                leaseToken: secondLeaseToken,
                leaseExpiresAt: date(111)),
            to: claimed,
            expectedRevision: 0,
            at: date(101))) { error in
                XCTAssertEqual(error as? DeferredMacWorkContractError, .staleRevision)
        }
        XCTAssertThrowsError(try transition(
            .start(ownerDeviceID: secondOwnerDeviceID, leaseToken: secondLeaseToken),
            claimed,
            at: 102)) { error in
                XCTAssertEqual(error as? DeferredMacWorkContractError, .leaseUnavailable)
        }
    }

    func testExpiredLeaseCanBeReclaimedButOldOwnerCannotPublish() throws {
        let first = try transition(
            .claim(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                leaseExpiresAt: date(110)),
            DeferredMacWorkSnapshot.queued(request: request()),
            at: 100)
        let reclaimed = try transition(
            .claim(
                ownerDeviceID: secondOwnerDeviceID,
                leaseToken: secondLeaseToken,
                leaseExpiresAt: date(120)),
            first,
            at: 110)

        XCTAssertEqual(reclaimed.attempt, 2)
        XCTAssertEqual(reclaimed.executionOwnerDeviceID, secondOwnerDeviceID)
        XCTAssertThrowsError(try transition(
            .start(ownerDeviceID: ownerDeviceID, leaseToken: leaseToken),
            reclaimed,
            at: 111)) { error in
                XCTAssertEqual(error as? DeferredMacWorkContractError, .leaseUnavailable)
        }
    }

    func testStaleSourceCannotPublishSuccessfulHeavyWork() throws {
        let running = try runningSnapshot()
        let command = DeferredMacWorkTransition.succeed(
            ownerDeviceID: ownerDeviceID,
            leaseToken: leaseToken,
            resultFingerprint: resultFingerprint,
            currentInputFingerprint: String(repeating: "c", count: 64),
            currentTranscriptRevision: 8)

        XCTAssertThrowsError(try transition(command, running, at: 102)) { error in
            XCTAssertEqual(error as? DeferredMacWorkContractError, .staleSource)
        }
    }

    func testFailureRetriesAreBoundedToThreeAttempts() throws {
        var current = DeferredMacWorkSnapshot.queued(request: try request())
        for attempt in 1...3 {
            let token = UUID()
            current = try transition(
                .claim(
                    ownerDeviceID: ownerDeviceID,
                    leaseToken: token,
                    leaseExpiresAt: date(TimeInterval(attempt * 20 + 110))),
                current,
                at: TimeInterval(attempt * 20 + 100))
            current = try transition(
                .start(ownerDeviceID: ownerDeviceID, leaseToken: token),
                current,
                at: TimeInterval(attempt * 20 + 101))
            current = try transition(
                .fail(ownerDeviceID: ownerDeviceID, leaseToken: token, code: "provider-down"),
                current,
                at: TimeInterval(attempt * 20 + 102))
        }

        XCTAssertEqual(current.attempt, 3)
        XCTAssertThrowsError(try transition(
            .claim(
                ownerDeviceID: secondOwnerDeviceID,
                leaseToken: secondLeaseToken,
                leaseExpiresAt: date(200)),
            current,
            at: 190)) { error in
                XCTAssertEqual(error as? DeferredMacWorkContractError, .attemptsExhausted)
        }
    }

    func testCancellationIsIdempotentAndTerminal() throws {
        let running = try runningSnapshot()
        let cancelled = try transition(.cancel, running, at: 102)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(
            try DeferredMacWorkPolicy.apply(
                .cancel,
                to: cancelled,
                expectedRevision: running.revision,
                at: date(103)),
            cancelled)
        XCTAssertThrowsError(try transition(
            .succeed(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                resultFingerprint: resultFingerprint,
                currentInputFingerprint: inputFingerprint,
                currentTranscriptRevision: 7),
            cancelled,
            at: 104))
    }

    func testStrictDecodeRejectsFutureRequestAndPartialLease() throws {
        let requestData = try JSONEncoder().encode(request())
        var requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        requestObject["formatVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            DeferredMacWorkRequest.self,
            from: JSONSerialization.data(withJSONObject: requestObject)))

        let snapshotData = try JSONEncoder().encode(
            DeferredMacWorkSnapshot.queued(request: request()))
        var snapshotObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        snapshotObject["leaseToken"] = leaseToken.uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(
            DeferredMacWorkSnapshot.self,
            from: JSONSerialization.data(withJSONObject: snapshotObject)))
    }

    private func request(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000002007")!,
        sourceDeviceID: UUID? = nil,
        sourceTranscriptRevision: Int = 7,
        inputFingerprint: String? = nil,
        maxAttempts: Int = 3,
        requestedAt: Date? = nil
    ) throws -> DeferredMacWorkRequest {
        try DeferredMacWorkRequest(
            id: id,
            meetingID: meetingID,
            sourceDeviceID: sourceDeviceID ?? self.sourceDeviceID,
            kind: .refine,
            sourceTranscriptRevision: sourceTranscriptRevision,
            inputFingerprint: inputFingerprint ?? self.inputFingerprint,
            maxAttempts: maxAttempts,
            requestedAt: requestedAt ?? date(90))
    }

    private func runningSnapshot() throws -> DeferredMacWorkSnapshot {
        let claimed = try transition(
            .claim(
                ownerDeviceID: ownerDeviceID,
                leaseToken: leaseToken,
                leaseExpiresAt: date(110)),
            DeferredMacWorkSnapshot.queued(request: request()),
            at: 100)
        return try transition(
            .start(ownerDeviceID: ownerDeviceID, leaseToken: leaseToken),
            claimed,
            at: 101)
    }

    private func transition(
        _ command: DeferredMacWorkTransition,
        _ snapshot: DeferredMacWorkSnapshot,
        at seconds: TimeInterval
    ) throws -> DeferredMacWorkSnapshot {
        try DeferredMacWorkPolicy.apply(
            command,
            to: snapshot,
            expectedRevision: snapshot.revision,
            at: date(seconds))
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
