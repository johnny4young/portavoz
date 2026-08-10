import Foundation
import PortavozCore
import XCTest

@testable import StorageKit
@testable import portavoz_app

final class SpotlightIndexerTests: XCTestCase {
    func testBurstRequestsCoalesceIntoOneProtectedReplacement() async throws {
        let store = try await seededStore()
        let backend = SpotlightBackendSpy()
        let sleeper = SuspendedSpotlightSleep()
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .milliseconds(250),
            retryDelays: [],
            sleep: { _ in try await sleeper.sleep() })

        await indexer.requestReindex()
        await sleeper.waitUntilSuspended()
        await indexer.requestReindex()
        await indexer.requestReindex()
        await sleeper.release()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 1)
        XCTAssertEqual(snapshot.meetingCounts, [1])
        XCTAssertEqual(snapshot.personCounts, [0])
        XCTAssertEqual(snapshot.commitmentCounts, [0])
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testMatchingClientStateSkipsReplacementAndCleansLegacyIndexOnceAcrossRequests() async throws {
        let store = try await seededStore()
        let projection = try await store.spotlightIndexSnapshot()
        let backend = SpotlightBackendSpy(
            clientState: SpotlightIndexer.clientState(
                for: projection,
                mode: .appEntities))
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()
        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 0)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testLegacyCleanupFailureRetriesUntilItSucceeds() async throws {
        let store = try await seededStore()
        let projection = try await store.spotlightIndexSnapshot()
        let backend = SpotlightBackendSpy(
            clientState: SpotlightIndexer.clientState(
                for: projection,
                mode: .appEntities),
            legacyRemovalFailures: 1)
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [.zero],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()
        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 0)
        XCTAssertEqual(snapshot.legacyRemovals, 2)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testTransientFailureRetriesWithoutLosingPendingWork() async throws {
        let store = try await seededStore()
        let backend = SpotlightBackendSpy(replacementFailures: 2)
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [.zero, .zero],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 3)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testExhaustedRetriesRemainVisibleAndANewRequestCanRecover() async throws {
        let store = try await seededStore()
        let backend = SpotlightBackendSpy(replacementFailures: 2)
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [.zero],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()
        let failedStatus = await indexer.status
        XCTAssertEqual(failedStatus, .failed(attempts: 2))

        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 3)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let recoveredStatus = await indexer.status
        XCTAssertEqual(recoveredStatus, .idle)
    }

    func testSuccessfulLegacyCleanupSurvivesIndexerRecreation() async throws {
        let store = try await seededStore()
        let projection = try await store.spotlightIndexSnapshot()
        let backend = SpotlightBackendSpy(
            clientState: SpotlightIndexer.clientState(
                for: projection,
                mode: .appEntities))
        let cleanupState = SpotlightLegacyCleanupStateSpy()

        let first = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: cleanupState,
            debounce: .zero,
            retryDelays: [],
            sleep: { _ in })
        await first.requestReindex()
        await first.waitUntilIdle()

        let relaunched = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            legacyCleanupState: cleanupState,
            debounce: .zero,
            retryDelays: [],
            sleep: { _ in })
        await relaunched.requestReindex()
        await relaunched.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 0)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
    }

    func testReconciliationEmitsOnlyMaintenanceIndexBoundaries() async throws {
        let store = try await seededStore()
        let recorder = ResourceWorkloadEventRecorder()
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: SpotlightBackendSpy(),
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [],
            telemetry: ResourceWorkloadTelemetry(receiver: recorder.receive),
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        guard case .started(let started) = recorder.events.first,
              case .finished(let finished, let outcome) = recorder.events.last
        else {
            return XCTFail("Expected one matched indexing interval")
        }
        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertEqual(started, finished)
        XCTAssertEqual(
            started.descriptor,
            ResourceWorkloadDescriptor(
                workloadClass: .maintenance,
                kind: .searchIndex,
                operation: .execute))
        XCTAssertEqual(outcome, .completed)
    }

    func testDocumentAndEntityModesCannotShareClientState() async throws {
        let store = try await seededStore()
        let snapshot = try await store.spotlightIndexSnapshot()

        let documentState = SpotlightIndexer.clientState(
            for: snapshot,
            mode: .meetingDocuments)
        let entityState = SpotlightIndexer.clientState(
            for: snapshot,
            mode: .appEntities)

        XCTAssertNotEqual(documentState, entityState)
        XCTAssertTrue(String(bytes: documentState, encoding: .utf8)?.hasPrefix(
            "meeting-documents-v1:") == true)
        XCTAssertTrue(String(bytes: entityState, encoding: .utf8)?.hasPrefix(
            "app-entities-v1:") == true)
    }

    func testEntityModePublishesWholeSnapshotWhileFallbackPublishesOnlyMeetings() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        try await store.save(meeting)
        try await store.save([speaker])
        _ = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Ana",
            source: .manualName)
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Send brief",
                origin: .manual(meetingID: meeting.id)),
            at: Date(timeIntervalSince1970: 1_700_000_100))

        let entityBackend = SpotlightBackendSpy(mode: .appEntities)
        let entityIndexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: entityBackend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [],
            sleep: { _ in })
        await entityIndexer.requestReindex()
        await entityIndexer.waitUntilIdle()

        let documentBackend = SpotlightBackendSpy(mode: .meetingDocuments)
        let documentIndexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: documentBackend,
            legacyCleanupState: SpotlightLegacyCleanupStateSpy(),
            debounce: .zero,
            retryDelays: [],
            sleep: { _ in })
        await documentIndexer.requestReindex()
        await documentIndexer.waitUntilIdle()

        let entitySnapshot = await entityBackend.snapshot()
        XCTAssertEqual(entitySnapshot.meetingCounts, [1])
        XCTAssertEqual(entitySnapshot.personCounts, [1])
        XCTAssertEqual(entitySnapshot.commitmentCounts, [1])
        let documentSnapshot = await documentBackend.snapshot()
        XCTAssertEqual(documentSnapshot.meetingCounts, [1])
        XCTAssertEqual(documentSnapshot.personCounts, [0])
        XCTAssertEqual(documentSnapshot.commitmentCounts, [0])
    }

    func testEntityClientStateCoversEveryPublishedProjection() {
        let baseline = Self.clientStateBaseline()
        let meeting = baseline.meetings[0]
        let variants = [
            baseline.replacingMeeting(id: MeetingID()),
            baseline.replacingMeeting(title: "Renamed planning"),
            baseline.replacingMeeting(
                startedAt: meeting.startedAt.addingTimeInterval(1)),
            baseline.replacingMeeting(contentDescription: "Changed search body"),
            baseline.replacingPerson(id: PersonID()),
            baseline.replacingPerson(name: "Ana María"),
            baseline.replacingCommitment(id: CommitmentID()),
            baseline.replacingCommitment(title: "Send revised brief"),
            baseline.replacingCommitmentDueAt(with: nil)
        ]

        let states = ([baseline] + variants).map {
            SpotlightIndexer.clientState(for: $0, mode: .appEntities)
        }
        XCTAssertEqual(Set(states).count, states.count)
        XCTAssertEqual(
            SpotlightIndexer.clientState(for: baseline, mode: .meetingDocuments),
            SpotlightIndexer.clientState(
                for: SpotlightIndexSnapshot(
                    meetings: [meeting],
                    people: [],
                    commitments: []),
                mode: .meetingDocuments))
    }

    func testEntityFactoryPreservesIdentityAndSearchAttributes() {
        guard #available(macOS 15.0, *) else { return }
        let meeting = SpotlightDocument(
            meetingID: MeetingID(),
            title: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentDescription: "Capped searchable body")
        let person = SpotlightPersonDocument(
            personID: PersonID(),
            preferredName: "Ana")
        let commitment = SpotlightCommitmentDocument(
            commitmentID: CommitmentID(),
            title: "Send brief",
            dueAt: Date(timeIntervalSince1970: 1_700_086_400))

        let meetingEntity = SpotlightAppEntityFactory.meeting(meeting)
        let personEntity = SpotlightAppEntityFactory.person(person)
        let commitmentEntity = SpotlightAppEntityFactory.commitment(commitment)

        XCTAssertEqual(meetingEntity.id, meeting.meetingID.rawValue.uuidString)
        XCTAssertEqual(meetingEntity.attributeSet.title, meeting.title)
        XCTAssertEqual(
            meetingEntity.attributeSet.contentDescription,
            meeting.contentDescription)
        XCTAssertEqual(personEntity.id, person.personID.rawValue.uuidString)
        XCTAssertEqual(personEntity.attributeSet.title, person.preferredName)
        XCTAssertEqual(
            commitmentEntity.id,
            commitment.commitmentID.rawValue.uuidString)
        XCTAssertEqual(commitmentEntity.attributeSet.title, commitment.title)
        XCTAssertEqual(commitmentEntity.attributeSet.dueDate, commitment.dueAt)
    }

    private func seededStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(
            title: "Searchable",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        return store
    }

    private static func clientStateBaseline() -> SpotlightIndexSnapshot {
        SpotlightIndexSnapshot(
            meetings: [SpotlightDocument(
                meetingID: MeetingID(),
                title: "Planning",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentDescription: "Search body")],
            people: [SpotlightPersonDocument(
                personID: PersonID(),
                preferredName: "Ana")],
            commitments: [SpotlightCommitmentDocument(
                commitmentID: CommitmentID(),
                title: "Send brief",
                dueAt: Date(timeIntervalSince1970: 1_700_086_400))])
    }
}

private extension SpotlightIndexSnapshot {
    func replacingMeeting(
        id: MeetingID? = nil,
        title: String? = nil,
        startedAt: Date? = nil,
        contentDescription: String? = nil
    ) -> SpotlightIndexSnapshot {
        let current = meetings[0]
        return SpotlightIndexSnapshot(
            meetings: [SpotlightDocument(
                meetingID: id ?? current.meetingID,
                title: title ?? current.title,
                startedAt: startedAt ?? current.startedAt,
                contentDescription: contentDescription ?? current.contentDescription)],
            people: people,
            commitments: commitments)
    }

    func replacingPerson(
        id: PersonID? = nil,
        name: String? = nil
    ) -> SpotlightIndexSnapshot {
        let current = people[0]
        return SpotlightIndexSnapshot(
            meetings: meetings,
            people: [SpotlightPersonDocument(
                personID: id ?? current.personID,
                preferredName: name ?? current.preferredName)],
            commitments: commitments)
    }

    func replacingCommitment(
        id: CommitmentID? = nil,
        title: String? = nil
    ) -> SpotlightIndexSnapshot {
        let current = commitments[0]
        return SpotlightIndexSnapshot(
            meetings: meetings,
            people: people,
            commitments: [SpotlightCommitmentDocument(
                commitmentID: id ?? current.commitmentID,
                title: title ?? current.title,
                dueAt: current.dueAt)])
    }

    func replacingCommitmentDueAt(with dueAt: Date?) -> SpotlightIndexSnapshot {
        let current = commitments[0]
        return SpotlightIndexSnapshot(
            meetings: meetings,
            people: people,
            commitments: [SpotlightCommitmentDocument(
                commitmentID: current.commitmentID,
                title: current.title,
                dueAt: dueAt)])
    }
}

private actor SpotlightLegacyCleanupStateSpy: SpotlightLegacyCleanupState {
    private var complete = false

    func isComplete() -> Bool { complete }

    func markComplete() {
        complete = true
    }
}

private actor SpotlightBackendSpy: SpotlightIndexBackend {
    struct Snapshot: Sendable {
        let replacements: Int
        let meetingCounts: [Int]
        let personCounts: [Int]
        let commitmentCounts: [Int]
        let legacyRemovals: Int
    }

    nonisolated let mode: SpotlightIndexer.IndexMode
    private var clientState: Data?
    private var remainingReplacementFailures: Int
    private var remainingLegacyRemovalFailures: Int
    private var replacementCount = 0
    private var meetingCounts: [Int] = []
    private var personCounts: [Int] = []
    private var commitmentCounts: [Int] = []
    private var legacyRemovalCount = 0

    init(
        mode: SpotlightIndexer.IndexMode = .appEntities,
        clientState: Data? = nil,
        replacementFailures: Int = 0,
        legacyRemovalFailures: Int = 0
    ) {
        self.mode = mode
        self.clientState = clientState
        remainingReplacementFailures = replacementFailures
        remainingLegacyRemovalFailures = legacyRemovalFailures
    }

    func lastClientState() async throws -> Data? { clientState }

    func replace(_ snapshot: SpotlightIndexSnapshot, clientState: Data) async throws {
        replacementCount += 1
        meetingCounts.append(snapshot.meetings.count)
        personCounts.append(snapshot.people.count)
        commitmentCounts.append(snapshot.commitments.count)
        if remainingReplacementFailures > 0 {
            remainingReplacementFailures -= 1
            throw SpotlightBackendSpyError.injectedFailure
        }
        self.clientState = clientState
    }

    func removeLegacyItems() async throws {
        legacyRemovalCount += 1
        if remainingLegacyRemovalFailures > 0 {
            remainingLegacyRemovalFailures -= 1
            throw SpotlightBackendSpyError.injectedFailure
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            replacements: replacementCount,
            meetingCounts: meetingCounts,
            personCounts: personCounts,
            commitmentCounts: commitmentCounts,
            legacyRemovals: legacyRemovalCount)
    }
}

private actor SuspendedSpotlightSleep {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep() async throws {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        while continuations.isEmpty { await Task.yield() }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum SpotlightBackendSpyError: Error {
    case injectedFailure
}
