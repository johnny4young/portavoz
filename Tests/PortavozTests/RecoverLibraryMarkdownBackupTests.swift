import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class RecoverLibraryMarkdownBackupTests: XCTestCase {
    func testNoJournalCleansUnownedStagesAndReturnsNone() async throws {
        let recovery = LaunchRecoveryStoreFake(states: [:])
        let sourceStore = LaunchRecoverySourceStoreFake(
            source: nil,
            removedDuringCleanup: [UUID()])
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery)

        let execution = try await useCase.execute(
            RecoverLibraryMarkdownBackupRequest())

        XCTAssertEqual(execution, .none)
        let preserved = await sourceStore.preservedOperationIDs
        XCTAssertEqual(preserved, [[]])
        let adoptionCalls = await sourceStore.adoptionCalls
        XCTAssertEqual(adoptionCalls, 0)
    }

    func testAmbiguousJournalsPreserveEveryMatchingStageAndFailClosed()
        async throws {
        let firstID = UUID()
        let secondID = UUID()
        let recovery = LaunchRecoveryStoreFake(states: [
            firstID: recoveryState(operationID: firstID),
            secondID: recoveryState(operationID: secondID),
        ])
        let sourceStore = LaunchRecoverySourceStoreFake(source: nil)
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery)

        await XCTAssertThrowsErrorAsync {
            _ = try await useCase.execute(
                RecoverLibraryMarkdownBackupRequest())
        } verify: { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupLaunchRecoveryError,
                .ambiguousRecovery)
        }

        let preserved = await sourceStore.preservedOperationIDs
        XCTAssertEqual(preserved, [[firstID, secondID]])
        let adoptionCalls = await sourceStore.adoptionCalls
        XCTAssertEqual(adoptionCalls, 0)
    }

    func testActiveJournalResumesAfterDurableCursorWithoutRepublishing()
        async throws {
        let operationID = UUID()
        let firstMeetingID = MeetingID()
        let secondMeeting = Meeting(
            title: "Meeting",
            startedAt: Date(timeIntervalSince1970: 1_810_000_000))
        let firstCursor = LibraryMarkdownBackupSourceCursor(
            startedAt: Date(timeIntervalSince1970: 1_810_000_100),
            recordID: firstMeetingID.rawValue.uuidString)
        let secondCursor = LibraryMarkdownBackupSourceCursor(
            startedAt: secondMeeting.startedAt,
            recordID: secondMeeting.id.rawValue.uuidString)
        let firstPublication = LibraryMarkdownBackupRecoveryPublication(
            sequence: 0,
            meetingID: firstMeetingID,
            fileName: "Meeting.md",
            sha256: String(repeating: "a", count: 64),
            byteCount: 42,
            sourceCursor: firstCursor)
        let state = LibraryMarkdownBackupRecoveryState(
            operationID: operationID,
            destinationBookmark: destinationBookmark,
            sourceCursor: firstCursor,
            completedPublications: [firstPublication])
        let source = LaunchRecoverySourceSession(
            id: operationID,
            totalMeetings: 2,
            entries: [(
                .content(backupContent(meeting: secondMeeting)),
                secondCursor
            )])
        let sourceStore = LaunchRecoverySourceStoreFake(source: source)
        let recovery = LaunchRecoveryStoreFake(states: [operationID: state])
        let files = LaunchBackupFilesFake()
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery,
            files: files)

        let execution = try await useCase.execute(
            RecoverLibraryMarkdownBackupRequest())

        guard case .completed(let result) = execution else {
            return XCTFail("Expected recovered backup completion")
        }
        XCTAssertEqual(result.totalMeetings, 2)
        XCTAssertEqual(
            result.exportedFileNames,
            ["Meeting.md", "Meeting 2.md"])
        XCTAssertTrue(result.failures.isEmpty)
        let publishedNames = await files.publishedNames
        XCTAssertEqual(publishedNames, ["Meeting 2.md"])
        let removedIDs = await recovery.removedOperationIDs
        XCTAssertEqual(removedIDs, [operationID])
        let closeCount = await source.closeCount
        let abandonCount = await source.abandonCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(abandonCount, 0)
    }

    func testCompletedJournalReconstructsTypedResultAndDeletesSource()
        async throws {
        let operationID = UUID()
        let publishedMeetingID = MeetingID()
        let failedMeetingID = MeetingID()
        let publishedCursor = LibraryMarkdownBackupSourceCursor(
            startedAt: Date(timeIntervalSince1970: 1_810_100_100),
            recordID: publishedMeetingID.rawValue.uuidString)
        let failedCursor = LibraryMarkdownBackupSourceCursor(
            startedAt: Date(timeIntervalSince1970: 1_810_100_000),
            recordID: failedMeetingID.rawValue.uuidString)
        let publication = LibraryMarkdownBackupRecoveryPublication(
            sequence: 0,
            meetingID: publishedMeetingID,
            fileName: "Published.md",
            sha256: String(repeating: "b", count: 64),
            byteCount: 84,
            sourceCursor: publishedCursor)
        let failure = LibraryMarkdownBackupRecoveryFailure(
            sequence: 0,
            sourceCursor: failedCursor,
            meetingID: failedMeetingID,
            title: "Failed",
            stage: .document)
        let state = LibraryMarkdownBackupRecoveryState(
            operationID: operationID,
            destinationBookmark: destinationBookmark,
            sourceCursor: failedCursor,
            completedPublications: [publication],
            failures: [failure],
            phase: .completed)
        let source = LaunchRecoverySourceSession(
            id: operationID,
            totalMeetings: 2,
            entries: [])
        let sourceStore = LaunchRecoverySourceStoreFake(source: source)
        let recovery = LaunchRecoveryStoreFake(states: [operationID: state])
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery)

        let execution = try await useCase.execute(
            RecoverLibraryMarkdownBackupRequest())

        XCTAssertEqual(execution, .completed(LibraryMarkdownBackupResult(
            totalMeetings: 2,
            exportedFileNames: ["Published.md"],
            failures: [failure.failure])))
        let removedIDs = await recovery.removedOperationIDs
        XCTAssertEqual(removedIDs, [operationID])
        let closeCount = await source.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testConflictingPendingPublicationNeverAdoptsOrDeletesSource()
        async throws {
        let operationID = UUID()
        let meetingID = MeetingID()
        let cursor = LibraryMarkdownBackupSourceCursor(
            startedAt: Date(timeIntervalSince1970: 1_810_200_000),
            recordID: meetingID.rawValue.uuidString)
        let pending = LibraryMarkdownBackupRecoveryPublication(
            sequence: 0,
            meetingID: meetingID,
            fileName: "Conflict.md",
            sha256: String(repeating: "c", count: 64),
            byteCount: 21,
            sourceCursor: cursor)
        let state = LibraryMarkdownBackupRecoveryState(
            operationID: operationID,
            destinationBookmark: destinationBookmark,
            pendingPublication: pending)
        let source = LaunchRecoverySourceSession(
            id: operationID,
            totalMeetings: 1,
            entries: [])
        let sourceStore = LaunchRecoverySourceStoreFake(source: source)
        let recovery = LaunchRecoveryStoreFake(states: [operationID: state])
        let files = LaunchBackupFilesFake(evidence: .conflicting)
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery,
            files: files)

        await XCTAssertThrowsErrorAsync {
            _ = try await useCase.execute(
                RecoverLibraryMarkdownBackupRequest())
        } verify: { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupLaunchRecoveryError,
                .blocked)
        }

        let adoptionCalls = await sourceStore.adoptionCalls
        let removedIDs = await recovery.removedOperationIDs
        XCTAssertEqual(adoptionCalls, 0)
        XCTAssertTrue(removedIDs.isEmpty)
    }

    func testCaptureGateSuspendsBeforeReconciliationAndAdoption() async throws {
        let operationID = UUID()
        let recovery = LaunchRecoveryStoreFake(states: [
            operationID: recoveryState(operationID: operationID)
        ])
        let sourceStore = LaunchRecoverySourceStoreFake(source: nil)
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery,
            maintenanceGate: DurableMaintenanceGate { _, _ in .pause })

        let execution = try await useCase.execute(
            RecoverLibraryMarkdownBackupRequest())

        XCTAssertEqual(execution, .suspended)
        let preserved = await sourceStore.preservedOperationIDs
        let adoptionCalls = await sourceStore.adoptionCalls
        XCTAssertEqual(preserved, [[operationID]])
        XCTAssertEqual(adoptionCalls, 0)
    }

    func testDestinationSetupFailureAbandonsAdoptedStageForRetry()
        async throws {
        let operationID = UUID()
        let source = LaunchRecoverySourceSession(
            id: operationID,
            totalMeetings: 0,
            entries: [])
        let sourceStore = LaunchRecoverySourceStoreFake(source: source)
        let recovery = LaunchRecoveryStoreFake(states: [
            operationID: recoveryState(operationID: operationID)
        ])
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery,
            destinationAccess: LaunchBackupDestinationAccess(
                failsAcquire: true))

        await XCTAssertThrowsErrorAsync {
            _ = try await useCase.execute(
                RecoverLibraryMarkdownBackupRequest())
        } verify: { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupError,
                .destinationUnavailable)
        }

        let adoptionCalls = await sourceStore.adoptionCalls
        let closeCount = await source.closeCount
        let abandonCount = await source.abandonCount
        let removedIDs = await recovery.removedOperationIDs
        XCTAssertEqual(adoptionCalls, 1)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(abandonCount, 1)
        XCTAssertTrue(removedIDs.isEmpty)
    }

    func testTerminalRecoveredSourceFailureDoesNotRestartFromLiveLibrary()
        async throws {
        let operationID = UUID()
        let source = LaunchRecoverySourceSession(
            id: operationID,
            totalMeetings: 1,
            entries: [],
            failsOnNext: true)
        let sourceStore = LaunchRecoverySourceStoreFake(source: source)
        let recovery = LaunchRecoveryStoreFake(states: [
            operationID: recoveryState(operationID: operationID)
        ])
        let useCase = makeRecoveryUseCase(
            sourceStore: sourceStore,
            recovery: recovery)

        await XCTAssertThrowsErrorAsync {
            _ = try await useCase.execute(
                RecoverLibraryMarkdownBackupRequest())
        } verify: { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupLaunchRecoveryError,
                .terminated)
        }
        let retry = try await useCase.execute(
            RecoverLibraryMarkdownBackupRequest())

        XCTAssertEqual(retry, .none)
        let removedIDs = await recovery.removedOperationIDs
        let closeCount = await source.closeCount
        let abandonCount = await source.abandonCount
        XCTAssertEqual(removedIDs, [operationID])
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(abandonCount, 0)
    }
}

private let destinationBookmark = LibraryMarkdownBackupDestinationBookmark(
    data: Data("destination".utf8))

private func makeRecoveryUseCase(
    sourceStore: LaunchRecoverySourceStoreFake,
    recovery: LaunchRecoveryStoreFake,
    files: LaunchBackupFilesFake = LaunchBackupFilesFake(),
    destinationAccess: LaunchBackupDestinationAccess =
        LaunchBackupDestinationAccess(),
    maintenanceGate: DurableMaintenanceGate = .unrestricted
) -> RecoverLibraryMarkdownBackup {
    let exporter = ExportLibraryMarkdownBackup(
        store: LaunchBackupPreparationStore(),
        documents: LaunchBackupDocumentsFake(),
        files: files,
        destinationAccess: destinationAccess,
        recoveryStore: recovery,
        maintenanceGate: maintenanceGate)
    return RecoverLibraryMarkdownBackup(
        sourceStore: sourceStore,
        recoveryStore: recovery,
        reconciler: ReconcileBackupPublication(
            files: files,
            destinationAccess: destinationAccess,
            recoveryStore: recovery),
        exporter: exporter,
        maintenanceGate: maintenanceGate)
}

private func recoveryState(
    operationID: UUID
) -> LibraryMarkdownBackupRecoveryState {
    LibraryMarkdownBackupRecoveryState(
        operationID: operationID,
        destinationBookmark: destinationBookmark)
}

private func backupContent(
    meeting: Meeting
) -> LibraryMarkdownBackupContent {
    LibraryMarkdownBackupContent(
        meeting: meeting,
        speakers: [],
        segments: [],
        summary: nil,
        summaryVersion: nil)
}

private actor LaunchRecoverySourceStoreFake:
    LibraryMarkdownBackupRecoverySourceStore {
    private let source: LaunchRecoverySourceSession?
    private let removedDuringCleanup: Set<UUID>
    private(set) var preservedOperationIDs: [Set<UUID>] = []
    private(set) var adoptionCalls = 0

    init(
        source: LaunchRecoverySourceSession?,
        removedDuringCleanup: Set<UUID> = []
    ) {
        self.source = source
        self.removedDuringCleanup = removedDuringCleanup
    }

    func adoptLibraryMarkdownBackupSource(
        id: UUID,
        cursor: LibraryMarkdownBackupSourceCursor?
    ) async throws -> LibraryMarkdownBackupSourceAdoption {
        adoptionCalls += 1
        guard let source, source.id == id else { return .unavailable }
        return .ready(source)
    }

    func cleanupAbandonedLibraryMarkdownBackupSources(
        preserving operationIDs: Set<UUID>
    ) -> Set<UUID> {
        preservedOperationIDs.append(operationIDs)
        return removedDuringCleanup
    }
}

private actor LaunchRecoverySourceSession:
    LibraryMarkdownBackupSourceSession {
    nonisolated let id: UUID
    nonisolated let totalMeetings: Int
    private let entries: [(
        LibraryMarkdownBackupSourceEntry,
        LibraryMarkdownBackupSourceCursor
    )]
    private let failsOnNext: Bool
    private var index = 0
    private var cursor: LibraryMarkdownBackupSourceCursor?
    private(set) var closeCount = 0
    private(set) var abandonCount = 0

    init(
        id: UUID,
        totalMeetings: Int,
        entries: [(
            LibraryMarkdownBackupSourceEntry,
            LibraryMarkdownBackupSourceCursor
        )],
        failsOnNext: Bool = false
    ) {
        self.id = id
        self.totalMeetings = totalMeetings
        self.entries = entries
        self.failsOnNext = failsOnNext
    }

    func next() throws -> LibraryMarkdownBackupSourceEntry? {
        if failsOnNext {
            throw LaunchRecoveryFakeError.expected
        }
        guard index < entries.count else { return nil }
        let entry = entries[index]
        index += 1
        cursor = entry.1
        return entry.0
    }

    func checkpoint() -> LibraryMarkdownBackupSourceCursor? {
        cursor
    }

    func close() {
        closeCount += 1
    }

    func abandon() {
        abandonCount += 1
    }
}

private struct LaunchBackupPreparationStore: LibraryMarkdownBackupStore {
    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        throw LaunchRecoveryFakeError.expected
    }
}

private struct LaunchBackupDocumentsFake: LibraryMarkdownBackupDocuments {
    func markdownDocument(
        for content: LibraryMarkdownBackupContent
    ) async throws -> Data {
        Data("# \(content.meeting.title)".utf8)
    }
}

private actor LaunchBackupFilesFake: LibraryMarkdownBackupFiles {
    private let destinationEvidence: BackupPublicationEvidence
    private(set) var publishedNames: [String] = []

    init(evidence: BackupPublicationEvidence = .matching) {
        destinationEvidence = evidence
    }

    func existingMarkdownFileNames(in directory: URL) -> Set<String> {
        []
    }

    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) -> LibraryMarkdownBackupPublication {
        publishedNames.append(fileName)
        return .published
    }

    func evidence(
        for publication: LibraryMarkdownBackupRecoveryPublication,
        in directory: URL
    ) -> BackupPublicationEvidence {
        destinationEvidence
    }
}

private struct LaunchBackupDestinationAccess:
    LibraryMarkdownBackupDestinationAccess {
    let failsAcquire: Bool

    init(failsAcquire: Bool = false) {
        self.failsAcquire = failsAcquire
    }

    func prepare(
        directory: URL
    ) async throws -> LibraryMarkdownBackupDestinationBookmark {
        destinationBookmark
    }

    func acquire(
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) async throws -> any LibraryMarkdownBackupDestinationLease {
        if failsAcquire {
            throw LaunchRecoveryFakeError.expected
        }
        return LaunchBackupDestinationLease(bookmark: bookmark)
    }
}

private final class LaunchBackupDestinationLease:
    LibraryMarkdownBackupDestinationLease,
    @unchecked Sendable {
    let directory = URL(fileURLWithPath: "/recovered-backup", isDirectory: true)
    let bookmark: LibraryMarkdownBackupDestinationBookmark

    init(bookmark: LibraryMarkdownBackupDestinationBookmark) {
        self.bookmark = bookmark
    }

    func close() {}
}

private actor LaunchRecoveryStoreFake:
    LibraryMarkdownBackupRecoveryStore {
    private var states: [UUID: LibraryMarkdownBackupRecoveryState]
    private(set) var mutations: [LibraryMarkdownBackupRecoveryMutation] = []
    private(set) var removedOperationIDs: [UUID] = []

    init(states: [UUID: LibraryMarkdownBackupRecoveryState]) {
        self.states = states
    }

    func operationIDs() -> Set<UUID> {
        Set(states.keys)
    }

    func apply(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) throws {
        guard var state = states[operationID] else {
            throw LaunchRecoveryFakeError.expected
        }
        mutations.append(mutation)
        switch mutation {
        case .begin:
            throw LaunchRecoveryFakeError.expected
        case .updateDestinationBookmark(let bookmark):
            state.destinationBookmark = bookmark
        case .reserve(let publication):
            state.pendingPublication = publication
        case .complete(let publication):
            guard state.pendingPublication == publication else {
                throw LaunchRecoveryFakeError.expected
            }
            state.pendingPublication = nil
            state.completedPublications.append(publication)
        case .clearReservation:
            state.pendingPublication = nil
        case .recordFailure(let failure):
            state.failures.append(failure)
        case .checkpointSource(let cursor):
            state.sourceCursor = cursor
        case .markCompleted:
            state.phase = .completed
        }
        states[operationID] = state
    }

    func load(
        operationID: UUID
    ) -> LibraryMarkdownBackupRecoveryState? {
        states[operationID]
    }

    func remove(operationID: UUID) {
        states[operationID] = nil
        removedOperationIDs.append(operationID)
    }
}

private enum LaunchRecoveryFakeError: Error {
    case expected
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
