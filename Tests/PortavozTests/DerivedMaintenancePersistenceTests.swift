import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class DerivedMaintenancePersistenceTests: XCTestCase {
    func testAdmissionIsIdempotentAndSourceMutationCreatesANewOperation() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Derived maintenance admission",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "Semantic maintenance is admitted from durable source identity.",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let profile = semanticTestProfile()

        let first = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint)
        let duplicate = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint)

        var correction = segment
        correction.text = "A corrected semantic source admits a distinct durable operation."
        try await store.save([correction])
        let corrected = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint)
        let jobs = try await store.derivedMaintenanceJobs(kind: .semanticCorpus)

        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(first.operationFingerprint, duplicate.operationFingerprint)
        XCTAssertGreaterThan(corrected.sourceGeneration, first.sourceGeneration)
        XCTAssertNotEqual(corrected.operationFingerprint, first.operationFingerprint)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.map(\.state), [.cancelled, .pending])
    }

    func testEmbeddingPublicationDoesNotAdvanceTheSourceGeneration() async throws {
        let store = try await seededStore()
        let profile = semanticTestProfile()
        let admitted = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint)
        _ = try await IndexSemanticCorpus(store: store).all(
            using: LeaseSemanticEmbedder())

        let afterPublication = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint)

        XCTAssertEqual(afterPublication.id, admitted.id)
        XCTAssertEqual(afterPublication.sourceGeneration, admitted.sourceGeneration)
    }

    func testExpiredOwnerRelaunchResumesFromNullRowsWithoutDuplicatingVectors() async throws {
        let store = try await seededStore()
        let profile = semanticTestProfile()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let admitted = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            at: start)
        let firstClaim = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: "semantic-owner-before-kill",
            leaseDuration: 1,
            at: start)
        let firstOwner = try XCTUnwrap(firstClaim)
        let partial = try await IndexSemanticCorpus(store: store).nextBatch(
            using: LeaseSemanticEmbedder(),
            limit: 1)
        let exactDuringInterruption = try await store.search(
            "durable semantic owner",
            requireAll: false)
        let beforeExpiry = start.addingTimeInterval(0.5)
        let blockedClaim = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: "semantic-owner-after-relaunch",
            leaseDuration: 60,
            at: beforeExpiry)
        let scheduledRecovery = try await store.nextScheduledSemanticCorpusMaintenanceDate(
            after: beforeExpiry)

        let relaunchedAt = start.addingTimeInterval(2)
        let recovered = try await store.recoverExpiredSemanticCorpusMaintenance(
            at: relaunchedAt)
        XCTAssertEqual(recovered, 1)
        let secondClaim = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: "semantic-owner-after-relaunch",
            leaseDuration: 60,
            at: relaunchedAt)
        let secondOwner = try XCTUnwrap(secondClaim)
        let resumed = try await IndexSemanticCorpus(store: store).all(
            using: LeaseSemanticEmbedder(),
            batchSize: 1)
        let completed = try await store.completeSemanticCorpusMaintenance(
            secondOwner.id,
            owner: "semantic-owner-after-relaunch",
            at: relaunchedAt.addingTimeInterval(1))
        let duplicate = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            at: relaunchedAt.addingTimeInterval(2))
        let duplicateClaim = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: "semantic-owner-after-completion",
            leaseDuration: 60,
            at: relaunchedAt.addingTimeInterval(2))
        let remaining = try await store.segmentsNeedingEmbeddings()
        let jobs = try await store.derivedMaintenanceJobs(kind: .semanticCorpus)

        XCTAssertEqual(firstOwner.id, admitted.id)
        XCTAssertNil(blockedClaim)
        XCTAssertEqual(scheduledRecovery, start.addingTimeInterval(1))
        XCTAssertEqual(secondOwner.id, admitted.id)
        XCTAssertEqual(partial.embeddedSegments, 1)
        XCTAssertEqual(resumed.embeddedSegments, 1)
        XCTAssertEqual(exactDuringInterruption.count, 2)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.attempt, 2)
        XCTAssertEqual(duplicate.id, completed.id)
        XCTAssertEqual(duplicate.state, .succeeded)
        XCTAssertEqual(duplicate.attempt, 2)
        XCTAssertNil(duplicateClaim)
        XCTAssertEqual(jobs.count, 1)
    }

    func testRetriesAreBoundedAndNeverChangeMeetingLifecycle() async throws {
        let store = try await seededStore()
        let profile = semanticTestProfile()
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        _ = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            maxAttempts: 2,
            at: start)
        let firstClaim = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: "semantic-retry-owner",
            leaseDuration: 60,
            at: start)
        let first = try XCTUnwrap(firstClaim)
        let retryAt = start.addingTimeInterval(5)
        let pending = try await store.failSemanticCorpusMaintenance(
            first.id,
            owner: "semantic-retry-owner",
            errorCode: "maintenance.semantic.failed",
            retryAt: retryAt,
            at: start.addingTimeInterval(1))
        let secondClaim = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: "semantic-retry-owner",
            leaseDuration: 60,
            at: retryAt)
        let second = try XCTUnwrap(secondClaim)
        let failed = try await store.failSemanticCorpusMaintenance(
            second.id,
            owner: "semantic-retry-owner",
            errorCode: "maintenance.semantic.failed",
            retryAt: retryAt.addingTimeInterval(5),
            at: retryAt.addingTimeInterval(1))
        let meetings = try await store.meetings()
        let detail = try XCTUnwrap(meetings.first)

        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.notBefore, retryAt)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attempt, 2)
        XCTAssertEqual(detail.lifecycleState, .ready)
    }

    private func seededStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Relaunch semantic maintenance",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The durable semantic owner publishes the first passage.",
                startTime: 0,
                endTime: 4,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The durable semantic owner resumes the second passage.",
                startTime: 5,
                endTime: 9,
                isFinal: true)
        ])
        return store
    }
}

private struct LeaseSemanticEmbedder: SemanticTextEmbedding {
    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile {
        semanticTestProfile()
    }

    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
