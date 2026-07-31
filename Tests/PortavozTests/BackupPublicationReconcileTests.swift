import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class BackupPublicationReconcileTests: XCTestCase {
    func testMatchingDestinationCompletesPublicationAndCheckpointsSource()
        async throws {
        let operationID = UUID()
        let pending = recoveryPublication()
        let originalBookmark = backupBookmark("original")
        let refreshedBookmark = backupBookmark("refreshed")
        let recovery = ReconciliationRecoveryStoreFake(state:
            recoveryState(
                operationID: operationID,
                bookmark: originalBookmark,
                pending: pending))
        let files = ReconciliationFilesFake(evidence: .matching)
        let destination = ReconciliationDestinationAccessFake(
            bookmark: refreshedBookmark)
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)

        let result = try await useCase.execute(
            BackupReconcileRequest(
                operationID: operationID))
        guard case .reconciled(let state) = result else {
            return XCTFail("Expected a reconciled publication")
        }

        XCTAssertEqual(state.destinationBookmark, refreshedBookmark)
        XCTAssertEqual(state.completedPublications, [pending])
        XCTAssertNil(state.pendingPublication)
        XCTAssertEqual(state.sourceCursor, pending.sourceCursor)
        let sourceCursor = try XCTUnwrap(pending.sourceCursor)
        let mutations = await recovery.mutations
        let evidenceCalls = await files.evidenceCalls
        XCTAssertEqual(mutations, [
            .updateDestinationBookmark(refreshedBookmark),
            .complete(pending),
            .checkpointSource(sourceCursor),
        ])
        XCTAssertEqual(destination.acquireCount, 1)
        XCTAssertEqual(destination.closeCount, 1)
        XCTAssertEqual(evidenceCalls, 1)
    }

    func testMissingDestinationClearsReservationForSourceRetry() async throws {
        let operationID = UUID()
        let pending = recoveryPublication()
        let recovery = ReconciliationRecoveryStoreFake(state:
            recoveryState(operationID: operationID, pending: pending))
        let files = ReconciliationFilesFake(evidence: .missing)
        let destination = ReconciliationDestinationAccessFake()
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)

        let result = try await useCase.execute(
            BackupReconcileRequest(
                operationID: operationID))
        guard case .retrySource(let state) = result else {
            return XCTFail("Expected the source row to be retried")
        }

        XCTAssertNil(state.pendingPublication)
        XCTAssertTrue(state.completedPublications.isEmpty)
        XCTAssertNil(state.sourceCursor)
        let mutations = await recovery.mutations
        XCTAssertEqual(mutations, [.clearReservation])
        XCTAssertEqual(destination.closeCount, 1)
    }

    func testConflictAndCursorlessReservationRemainBlocked() async throws {
        for (pending, evidence, expectedBlock) in [
            (recoveryPublication(), .conflicting, .destinationConflict),
            (
                recoveryPublication(includesSourceCursor: false),
                .matching,
                .missingSourceCursor
            ),
        ] as [(
            LibraryMarkdownBackupRecoveryPublication,
            BackupPublicationEvidence,
            BackupReconcileBlock
        )] {
            let operationID = UUID()
            let recovery = ReconciliationRecoveryStoreFake(state:
                recoveryState(operationID: operationID, pending: pending))
            let destination = ReconciliationDestinationAccessFake()
            let useCase = ReconcileBackupPublication(
                files: ReconciliationFilesFake(evidence: evidence),
                destinationAccess: destination,
                recoveryStore: recovery)

            let result = try await useCase.execute(
                BackupReconcileRequest(
                    operationID: operationID))
            guard case .blocked(let state, let block) = result else {
                return XCTFail("Expected reconciliation to remain blocked")
            }
            XCTAssertEqual(block, expectedBlock)
            XCTAssertEqual(state.pendingPublication, pending)
            let mutations = await recovery.mutations
            XCTAssertTrue(mutations.isEmpty)
            XCTAssertEqual(destination.closeCount, 1)
        }
    }

    func testCheckpointRetryDoesNotReinspectOrReacquireDestination()
        async throws {
        let operationID = UUID()
        let pending = recoveryPublication()
        let recovery = ReconciliationRecoveryStoreFake(
            state: recoveryState(operationID: operationID, pending: pending),
            checkpointFailures: 1)
        let files = ReconciliationFilesFake(evidence: .matching)
        let destination = ReconciliationDestinationAccessFake()
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)
        let request = BackupReconcileRequest(
            operationID: operationID)

        do {
            _ = try await useCase.execute(request)
            XCTFail("Expected checkpoint persistence to fail")
        } catch {
            XCTAssertEqual(
                error as? BackupReconcileError,
                .recoveryUnavailable)
        }
        let firstEvidenceCalls = await files.evidenceCalls
        XCTAssertEqual(destination.acquireCount, 1)
        XCTAssertEqual(firstEvidenceCalls, 1)

        let result = try await useCase.execute(request)
        guard case .reconciled(let state) = result else {
            return XCTFail("Expected checkpoint-only recovery")
        }
        XCTAssertEqual(state.sourceCursor, pending.sourceCursor)
        let finalEvidenceCalls = await files.evidenceCalls
        XCTAssertEqual(destination.acquireCount, 1)
        XCTAssertEqual(destination.closeCount, 1)
        XCTAssertEqual(finalEvidenceCalls, 1)
    }

    func testMissingRecoveryStateDoesNotTouchDestination() async throws {
        let recovery = ReconciliationRecoveryStoreFake(state: nil)
        let files = ReconciliationFilesFake(evidence: .matching)
        let destination = ReconciliationDestinationAccessFake()
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)

        let result = try await useCase.execute(
            BackupReconcileRequest(
                operationID: UUID()))

        XCTAssertEqual(result, .unavailable)
        let evidenceCalls = await files.evidenceCalls
        XCTAssertEqual(destination.acquireCount, 0)
        XCTAssertEqual(evidenceCalls, 0)
    }

    func testDestinationEvidenceFailureClosesLeaseAndPreservesReservation()
        async throws {
        let operationID = UUID()
        let pending = recoveryPublication()
        let recovery = ReconciliationRecoveryStoreFake(state:
            recoveryState(operationID: operationID, pending: pending))
        let files = ReconciliationFilesFake(outcome: .failure)
        let destination = ReconciliationDestinationAccessFake()
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)

        do {
            _ = try await useCase.execute(
                BackupReconcileRequest(operationID: operationID))
            XCTFail("Expected destination evidence to fail")
        } catch {
            XCTAssertEqual(error as? BackupReconcileError, .destinationUnavailable)
        }

        let mutations = await recovery.mutations
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertEqual(destination.closeCount, 1)
    }

    func testBookmarkSaveFailureClosesLease() async throws {
        let operationID = UUID()
        let pending = recoveryPublication()
        let recovery = ReconciliationRecoveryStoreFake(
            state: recoveryState(operationID: operationID, pending: pending),
            bookmarkFailures: 1)
        let files = ReconciliationFilesFake(evidence: .matching)
        let destination = ReconciliationDestinationAccessFake(
            bookmark: backupBookmark("refreshed"))
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)

        do {
            _ = try await useCase.execute(
                BackupReconcileRequest(operationID: operationID))
            XCTFail("Expected refreshed bookmark persistence to fail")
        } catch {
            XCTAssertEqual(error as? BackupReconcileError, .recoveryUnavailable)
        }

        let evidenceCalls = await files.evidenceCalls
        XCTAssertEqual(evidenceCalls, 0)
        XCTAssertEqual(destination.closeCount, 1)
        let loadedState = await recovery.load(operationID: operationID)
        XCTAssertEqual(loadedState?.pendingPublication, pending)
    }

    func testDestinationEvidenceCancellationPropagatesAndClosesLease()
        async throws {
        let operationID = UUID()
        let pending = recoveryPublication()
        let recovery = ReconciliationRecoveryStoreFake(state:
            recoveryState(operationID: operationID, pending: pending))
        let files = ReconciliationFilesFake(outcome: .cancellation)
        let destination = ReconciliationDestinationAccessFake()
        let useCase = ReconcileBackupPublication(
            files: files,
            destinationAccess: destination,
            recoveryStore: recovery)

        do {
            _ = try await useCase.execute(
                BackupReconcileRequest(operationID: operationID))
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let mutations = await recovery.mutations
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertEqual(destination.closeCount, 1)
    }
}

private actor ReconciliationRecoveryStoreFake:
    LibraryMarkdownBackupRecoveryStore {
    private var state: LibraryMarkdownBackupRecoveryState?
    private var remainingCheckpointFailures: Int
    private var remainingBookmarkFailures: Int
    private(set) var mutations: [LibraryMarkdownBackupRecoveryMutation] = []

    init(
        state: LibraryMarkdownBackupRecoveryState?,
        checkpointFailures: Int = 0,
        bookmarkFailures: Int = 0
    ) {
        self.state = state
        remainingCheckpointFailures = checkpointFailures
        remainingBookmarkFailures = bookmarkFailures
    }

    func apply(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) throws {
        guard var state, state.operationID == operationID else {
            throw ReconciliationFakeError.expected
        }
        mutations.append(mutation)
        switch mutation {
        case .updateDestinationBookmark(let bookmark):
            if remainingBookmarkFailures > 0 {
                remainingBookmarkFailures -= 1
                throw ReconciliationFakeError.expected
            }
            state.destinationBookmark = bookmark
        case .clearReservation:
            state.pendingPublication = nil
        case .complete(let publication):
            guard state.pendingPublication == publication else {
                throw ReconciliationFakeError.expected
            }
            state.pendingPublication = nil
            state.completedPublications.append(publication)
        case .checkpointSource(let cursor):
            if remainingCheckpointFailures > 0 {
                remainingCheckpointFailures -= 1
                self.state = state
                throw ReconciliationFakeError.expected
            }
            state.sourceCursor = cursor
        case .begin, .reserve, .markCompleted:
            throw ReconciliationFakeError.expected
        }
        self.state = state
    }

    func load(
        operationID: UUID
    ) -> LibraryMarkdownBackupRecoveryState? {
        guard state?.operationID == operationID else { return nil }
        return state
    }

    func remove(operationID: UUID) throws {
        throw ReconciliationFakeError.expected
    }
}

private actor ReconciliationFilesFake: LibraryMarkdownBackupFiles {
    private let outcome: ReconciliationEvidenceOutcome
    private(set) var evidenceCalls = 0

    init(evidence: BackupPublicationEvidence) {
        outcome = .evidence(evidence)
    }

    init(outcome: ReconciliationEvidenceOutcome) {
        self.outcome = outcome
    }

    func existingMarkdownFileNames(in directory: URL) -> Set<String> { [] }

    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) -> LibraryMarkdownBackupPublication {
        .published
    }

    func evidence(
        for publication: LibraryMarkdownBackupRecoveryPublication,
        in directory: URL
    ) throws -> BackupPublicationEvidence {
        evidenceCalls += 1
        switch outcome {
        case .evidence(let evidence):
            return evidence
        case .failure:
            throw ReconciliationFakeError.expected
        case .cancellation:
            throw CancellationError()
        }
    }
}

private enum ReconciliationEvidenceOutcome: Sendable {
    case evidence(BackupPublicationEvidence)
    case failure
    case cancellation
}

private final class ReconciliationDestinationAccessFake:
    LibraryMarkdownBackupDestinationAccess,
    @unchecked Sendable {
    private let lock = NSLock()
    private let acquiredBookmark: LibraryMarkdownBackupDestinationBookmark
    private var storedAcquireCount = 0
    private var storedCloseCount = 0

    init(bookmark: LibraryMarkdownBackupDestinationBookmark = backupBookmark()) {
        acquiredBookmark = bookmark
    }

    var acquireCount: Int { lock.withLock { storedAcquireCount } }
    var closeCount: Int { lock.withLock { storedCloseCount } }

    func prepare(
        directory: URL
    ) throws -> LibraryMarkdownBackupDestinationBookmark {
        throw ReconciliationFakeError.expected
    }

    func acquire(
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) -> any LibraryMarkdownBackupDestinationLease {
        lock.withLock { storedAcquireCount += 1 }
        return ReconciliationDestinationLeaseFake(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true),
            bookmark: acquiredBookmark,
            onClose: { [weak self] in
                self?.recordClose()
            })
    }

    private func recordClose() {
        lock.withLock { storedCloseCount += 1 }
    }
}

private final class ReconciliationDestinationLeaseFake:
    LibraryMarkdownBackupDestinationLease,
    @unchecked Sendable {
    let directory: URL
    let bookmark: LibraryMarkdownBackupDestinationBookmark
    private let lock = NSLock()
    private let onClose: @Sendable () -> Void
    private var isClosed = false

    init(
        directory: URL,
        bookmark: LibraryMarkdownBackupDestinationBookmark,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.directory = directory
        self.bookmark = bookmark
        self.onClose = onClose
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            onClose()
        }
    }
}

private enum ReconciliationFakeError: Error {
    case expected
}

private func recoveryPublication(
    includesSourceCursor: Bool = true
) -> LibraryMarkdownBackupRecoveryPublication {
    let meetingID = MeetingID()
    let sourceCursor = includesSourceCursor
        ? LibraryMarkdownBackupSourceCursor(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            recordID: meetingID.rawValue.uuidString)
        : nil
    return LibraryMarkdownBackupRecoveryPublication(
        sequence: 0,
        meetingID: meetingID,
        fileName: "Meeting.md",
        sha256: String(repeating: "a", count: 64),
        byteCount: 42,
        sourceCursor: sourceCursor)
}

private func recoveryState(
    operationID: UUID,
    bookmark: LibraryMarkdownBackupDestinationBookmark = backupBookmark(),
    pending: LibraryMarkdownBackupRecoveryPublication? = nil
) -> LibraryMarkdownBackupRecoveryState {
    LibraryMarkdownBackupRecoveryState(
        operationID: operationID,
        destinationBookmark: bookmark,
        pendingPublication: pending)
}

private func backupBookmark(
    _ value: String = "bookmark"
) -> LibraryMarkdownBackupDestinationBookmark {
    LibraryMarkdownBackupDestinationBookmark(data: Data(value.utf8))
}
