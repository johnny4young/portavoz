import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class ExportLibraryMarkdownBackupUseCaseTests: XCTestCase {
    func testExportAllocatesPortableNamesWithoutReplacingExistingFiles() async throws {
        let first = backupContent(title: "Road/map")
        let second = backupContent(title: "road:map")
        let documents = BackupDocumentsFake()
        let files = BackupFilesFake(
            existing: ["Road-map.md"],
            collisionCount: 1)
        let recorder = BackupProgressRecorder()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [first, second]),
            documents: documents,
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: BackupRecoveryStoreFake())

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true)
            ) { event in
                await recorder.append(event)
            }))

        XCTAssertEqual(result.totalMeetings, 2)
        XCTAssertEqual(result.exportedFileNames, ["Road-map 3.md", "road-map 4.md"])
        XCTAssertTrue(result.failures.isEmpty)
        let publishedNames = await files.publishedNames
        let renderedTitles = await documents.renderedTitles
        let lastProgress = await recorder.events.last
        XCTAssertEqual(
            publishedNames,
            ["Road-map 2.md", "Road-map 3.md", "road-map 4.md"])
        XCTAssertEqual(renderedTitles, ["Road/map", "road:map"])
        XCTAssertEqual(lastProgress, .exporting(
            LibraryMarkdownBackupProgress(
                completedMeetings: 2,
                totalMeetings: 2,
                exportedMeetings: 2,
                failedMeetings: 0)))
    }

    func testExportReturnsTypedPartialFailuresAndKeepsHealthyDocuments() async throws {
        let healthy = backupContent(title: "Healthy")
        let renderFailure = backupContent(title: "Render failure")
        let writeFailure = backupContent(title: "Write failure")
        let sourceFailure = LibraryMarkdownBackupSourceFailure(
            meetingID: MeetingID(),
            title: "Unreadable")
        let documents = BackupDocumentsFake(failingTitles: ["Render failure"])
        let files = BackupFilesFake(failingNames: ["Write failure.md"])
        let recoveryStore = BackupRecoveryStoreFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(
                contents: [healthy, renderFailure, writeFailure],
                failures: [sourceFailure]),
            documents: documents,
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))

        XCTAssertEqual(result.totalMeetings, 4)
        XCTAssertEqual(result.exportedFileNames, ["Healthy.md"])
        XCTAssertEqual(result.failures.map(\.stage), [.source, .document, .publication])
        XCTAssertEqual(result.failures.map(\.title), [
            "Unreadable", "Render failure", "Write failure",
        ])
        let sourceCursors = await recoveryStore.savedStates
            .compactMap(\.sourceCursor)
        XCTAssertTrue(sourceCursors.isEmpty)
    }

    func testDocumentFailureFreezesCheckpointBeforeLaterHealthyPublication()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [
                backupContent(title: "Render failure"),
                backupContent(title: "Healthy"),
            ]),
            documents: BackupDocumentsFake(
                failingTitles: ["Render failure"]),
            files: BackupFilesFake(),
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))
        let sourceCursors = await recoveryStore.savedStates
            .compactMap(\.sourceCursor)

        XCTAssertEqual(result.exportedFileNames, ["Healthy.md"])
        XCTAssertEqual(result.failures.map(\.stage), [.document])
        XCTAssertTrue(sourceCursors.isEmpty)
    }

    func testPublicationFailureFreezesCheckpointBeforeLaterHealthyPublication()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [
                backupContent(title: "Write failure"),
                backupContent(title: "Healthy"),
            ]),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(failingNames: ["Write failure.md"]),
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))
        let sourceCursors = await recoveryStore.savedStates
            .compactMap(\.sourceCursor)

        XCTAssertEqual(result.exportedFileNames, ["Healthy.md"])
        XCTAssertEqual(result.failures.map(\.stage), [.publication])
        XCTAssertTrue(sourceCursors.isEmpty)
    }

    func testSourceFailureMapsToStableFatalError() async {
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(fails: true),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(),
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: BackupRecoveryStoreFake())

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true)))
        ) { error in
            XCTAssertEqual(error as? LibraryMarkdownBackupError, .libraryUnavailable)
        }
    }

    func testDestinationInspectionFailureMapsToStableFatalError() async {
        let destinationAccess = BackupDestinationAccessFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(failsInspection: true),
            destinationAccess: destinationAccess,
            recoveryStore: BackupRecoveryStoreFake())

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true)))
        ) { error in
            XCTAssertEqual(error as? LibraryMarkdownBackupError, .destinationUnavailable)
        }
        XCTAssertEqual(destinationAccess.closeCount, 1)
    }

    func testDestinationResolutionFailureMapsToStableFatalError() async {
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(),
            destinationAccess: BackupDestinationAccessFake(failsAcquisition: true),
            recoveryStore: BackupRecoveryStoreFake())

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true)))
        ) { error in
            XCTAssertEqual(error as? LibraryMarkdownBackupError, .destinationUnavailable)
        }
    }

    func testEmptyLibraryProducesACompleteZeroResult() async throws {
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(),
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: BackupRecoveryStoreFake())

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))

        XCTAssertEqual(result.totalMeetings, 0)
        XCTAssertEqual(result.exportedCount, 0)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testExportUsesPortableFallbacksAndCanonicalCollisionKeys() async throws {
        let decomposedResume = "Re\u{301}sume\u{301}"
        let files = BackupFilesFake(existing: ["Résumé.md"])
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [
                backupContent(title: " ... "),
                backupContent(title: "CON"),
                backupContent(title: decomposedResume),
            ]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: BackupRecoveryStoreFake())

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))

        XCTAssertEqual(result.exportedFileNames, [
            "meeting.md",
            "meeting-CON.md",
            "\(decomposedResume) 2.md",
        ])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testProtectedCaptureSuspendsBeforeReadingTheLibrary() async throws {
        let store = BackupStoreProbe()
        let documents = BackupDocumentsFake()
        let files = BackupFilesFake()
        let destinationAccess = BackupDestinationAccessFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: store,
            documents: documents,
            files: files,
            destinationAccess: destinationAccess,
            recoveryStore: BackupRecoveryStoreFake(),
            maintenanceGate: DurableMaintenanceGate { descriptor, phase in
                XCTAssertEqual(descriptor.workloadClass, .maintenance)
                XCTAssertEqual(descriptor.kind, .mediaExport)
                XCTAssertEqual(descriptor.operation, .execute)
                XCTAssertEqual(phase, .admission)
                return .pause
            })

        let execution = try await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true)))
        let storeCalls = await store.calls
        let renderedTitles = await documents.renderedTitles
        let publishedNames = await files.publishedNames

        XCTAssertEqual(execution, .suspended)
        XCTAssertEqual(storeCalls, 0)
        XCTAssertTrue(renderedTitles.isEmpty)
        XCTAssertTrue(publishedNames.isEmpty)
        XCTAssertEqual(destinationAccess.prepareCount, 0)
        XCTAssertEqual(destinationAccess.acquireCount, 0)
    }

    func testCaptureCheckpointResumesSameStageWithoutRepublishingCompletedMeetings()
        async throws {
        let gateState = BackupMaintenanceGateState()
        let store = BackupStoreProbe(contents: [
            backupContent(title: "First"),
            backupContent(title: "Second"),
        ])
        let documents = BackupDocumentsFake()
        let files = BackupFilesFake(onPublish: {
            gateState.pauseOnce()
        })
        let destinationAccess = BackupDestinationAccessFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: store,
            documents: documents,
            files: files,
            destinationAccess: destinationAccess,
            recoveryStore: BackupRecoveryStoreFake(),
            maintenanceGate: DurableMaintenanceGate { _, _ in
                gateState.disposition
            })
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        let firstExecution = try await useCase.execute(request)
        let firstStoreCalls = await store.calls
        let firstRenderedTitles = await documents.renderedTitles
        let firstPublishedNames = await files.publishedNames

        XCTAssertEqual(firstExecution, .suspended)
        XCTAssertEqual(firstStoreCalls, 1)
        XCTAssertEqual(firstRenderedTitles, ["First"])
        XCTAssertEqual(firstPublishedNames, ["First.md"])
        XCTAssertEqual(destinationAccess.prepareCount, 1)
        XCTAssertEqual(destinationAccess.acquireCount, 1)
        XCTAssertEqual(destinationAccess.closeCount, 1)

        gateState.resume()
        let result = try completedResult(from: await useCase.execute(request))
        let finalStoreCalls = await store.calls
        let finalRenderedTitles = await documents.renderedTitles
        let finalPublishedNames = await files.publishedNames

        XCTAssertEqual(result.exportedFileNames, ["First.md", "Second.md"])
        XCTAssertEqual(finalStoreCalls, 1)
        XCTAssertEqual(finalRenderedTitles, ["First", "Second"])
        XCTAssertEqual(finalPublishedNames, ["First.md", "Second.md"])
        XCTAssertEqual(destinationAccess.prepareCount, 1)
        XCTAssertEqual(destinationAccess.acquireCount, 2)
        XCTAssertEqual(destinationAccess.closeCount, 2)
    }

    func testCaptureCheckpointRetainsRenderedDocumentAcrossResume() async throws {
        let gateState = BackupMaintenanceGateState()
        let documents = BackupDocumentsFake(onRender: {
            gateState.pauseOnce()
        })
        let files = BackupFilesFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Rendered")]),
            documents: documents,
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: BackupRecoveryStoreFake(),
            maintenanceGate: DurableMaintenanceGate { _, _ in
                gateState.disposition
            })
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        let firstExecution = try await useCase.execute(request)
        let renderedBeforeResume = await documents.renderedTitles
        let publishedBeforeResume = await files.publishedNames
        XCTAssertEqual(firstExecution, .suspended)
        XCTAssertEqual(renderedBeforeResume, ["Rendered"])
        XCTAssertTrue(publishedBeforeResume.isEmpty)

        gateState.resume()
        let result = try completedResult(from: await useCase.execute(request))
        let renderedAfterResume = await documents.renderedTitles
        let publishedAfterResume = await files.publishedNames

        XCTAssertEqual(result.exportedFileNames, ["Rendered.md"])
        XCTAssertEqual(renderedAfterResume, ["Rendered"])
        XCTAssertEqual(publishedAfterResume, ["Rendered.md"])
    }

    func testPublicationJournalsReservationBeforeMoveAndCompletionAfterMove()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake()
        let files = BackupFilesFake(onPublish: {
            let state = await recoveryStore.savedStates.last
            XCTAssertEqual(state?.pendingPublication?.fileName, "Meeting.md")
            XCTAssertTrue(state?.completedPublications.isEmpty == true)
        })
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))
        let states = await recoveryStore.savedStates
        let removedIDs = await recoveryStore.removedOperationIDs

        XCTAssertEqual(result.exportedFileNames, ["Meeting.md"])
        XCTAssertEqual(states.count, 5)
        XCTAssertEqual(states[0].phase, .active)
        XCTAssertNil(states[0].pendingPublication)
        XCTAssertNil(states[0].sourceCursor)
        XCTAssertEqual(states[1].pendingPublication?.fileName, "Meeting.md")
        XCTAssertEqual(
            states[1].pendingPublication?.sha256,
            "6bac95bc3dee1a17ddc9660954f9e1d27545bbf9aaf51c96fe5b06611c167b3d")
        XCTAssertEqual(states[2].completedPublications.count, 1)
        XCTAssertNil(states[2].pendingPublication)
        XCTAssertNotNil(states[3].sourceCursor)
        XCTAssertEqual(states[3].phase, .active)
        XCTAssertEqual(states[4].phase, .completed)
        XCTAssertEqual(states[4].sourceCursor, states[3].sourceCursor)
        XCTAssertEqual(removedIDs, [states[0].operationID])
    }

    func testPostMoveJournalFailureDoesNotRepublishOnProcessLocalRetry()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake(failingSaveCalls: [3])
        let files = BackupFilesFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(request)
        ) { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupError,
                .libraryUnavailable)
        }
        let namesAfterFailure = await files.publishedNames
        XCTAssertEqual(namesAfterFailure, ["Meeting.md"])

        let result = try completedResult(from: await useCase.execute(request))
        let namesAfterRetry = await files.publishedNames
        let finalState = await recoveryStore.savedStates.last

        XCTAssertEqual(result.exportedFileNames, ["Meeting.md"])
        XCTAssertEqual(namesAfterRetry, ["Meeting.md"])
        XCTAssertEqual(finalState?.phase, .completed)
    }

    func testSourceCheckpointFailureDoesNotRepublishCompletedDocument()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake(failingSaveCalls: [4])
        let files = BackupFilesFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(request)
        ) { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupError,
                .libraryUnavailable)
        }
        let namesAfterFailure = await files.publishedNames
        XCTAssertEqual(namesAfterFailure, ["Meeting.md"])

        let result = try completedResult(from: await useCase.execute(request))
        let namesAfterRetry = await files.publishedNames
        let finalState = await recoveryStore.savedStates.last

        XCTAssertEqual(result.exportedFileNames, ["Meeting.md"])
        XCTAssertEqual(namesAfterRetry, ["Meeting.md"])
        XCTAssertNotNil(finalState?.sourceCursor)
        XCTAssertEqual(finalState?.phase, .completed)
    }

    func testFailedPublicationClearRetriesWithoutPublishingAnotherName()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake(failingSaveCalls: [3])
        let files = BackupFilesFake(failingNames: ["Write failure.md"])
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [
                backupContent(title: "Write failure"),
            ]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: BackupDestinationAccessFake(),
            recoveryStore: recoveryStore)
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(request)
        ) { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupError,
                .libraryUnavailable)
        }
        let namesAfterFailure = await files.publishedNames
        XCTAssertEqual(namesAfterFailure, ["Write failure.md"])

        let result = try completedResult(from: await useCase.execute(request))
        let namesAfterRetry = await files.publishedNames

        XCTAssertEqual(result.failures.map(\.stage), [.publication])
        XCTAssertEqual(namesAfterRetry, ["Write failure.md"])
    }

    func testRefreshedBookmarkPersistenceRetriesBeforeAdvancing()
        async throws {
        let gateState = BackupMaintenanceGateState()
        let destinationAccess = BackupDestinationAccessFake(
            refreshAfterFirstAcquisition: true)
        let recoveryStore = BackupRecoveryStoreFake(failingSaveCalls: [5])
        let files = BackupFilesFake(onPublish: {
            gateState.pauseOnce()
        })
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [
                backupContent(title: "Meeting"),
            ]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: destinationAccess,
            recoveryStore: recoveryStore,
            maintenanceGate: DurableMaintenanceGate { _, _ in
                gateState.disposition
            })
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        let suspendedExecution = try await useCase.execute(request)
        XCTAssertEqual(suspendedExecution, .suspended)
        gateState.resume()
        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(request)
        ) { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupError,
                .libraryUnavailable)
        }

        let result = try completedResult(from: await useCase.execute(request))
        let finalState = await recoveryStore.savedStates.last
        let publishedNames = await files.publishedNames

        XCTAssertEqual(result.exportedFileNames, ["Meeting.md"])
        XCTAssertEqual(publishedNames, ["Meeting.md"])
        XCTAssertEqual(
            finalState?.destinationBookmark.data,
            BackupDestinationAccessFake.refreshedBookmarkData)
    }

    func testTerminalJournalRemovalRetriesBeforeClosingTheStage()
        async throws {
        let recoveryStore = BackupRecoveryStoreFake(failingRemoveCalls: [1])
        let files = BackupFilesFake()
        let destinationAccess = BackupDestinationAccessFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: files,
            destinationAccess: destinationAccess,
            recoveryStore: recoveryStore)
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(request)
        ) { error in
            XCTAssertEqual(
                error as? LibraryMarkdownBackupError,
                .libraryUnavailable)
        }
        let namesAfterFailure = await files.publishedNames
        XCTAssertEqual(namesAfterFailure, ["Meeting.md"])

        let result = try completedResult(from: await useCase.execute(request))
        let namesAfterRetry = await files.publishedNames
        let removedIDs = await recoveryStore.removedOperationIDs

        XCTAssertEqual(result.exportedFileNames, ["Meeting.md"])
        XCTAssertEqual(namesAfterRetry, ["Meeting.md"])
        XCTAssertEqual(removedIDs.count, 1)
        XCTAssertEqual(destinationAccess.acquireCount, 1)
    }

    func testSourceFailureCleanupRetriesWithoutReacquiringDestination() async {
        let recoveryStore = BackupRecoveryStoreFake(failingRemoveCalls: [1])
        let destinationAccess = BackupDestinationAccessFake()
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(failsWhileReading: true),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(),
            destinationAccess: destinationAccess,
            recoveryStore: recoveryStore)
        let request = ExportLibraryMarkdownBackupRequest(
            directory: URL(fileURLWithPath: "/backup", isDirectory: true))

        for _ in 0..<2 {
            await XCTAssertThrowsErrorAsync(
                try await useCase.execute(request)
            ) { error in
                XCTAssertEqual(
                    error as? LibraryMarkdownBackupError,
                    .libraryUnavailable)
            }
        }

        let removedIDs = await recoveryStore.removedOperationIDs
        XCTAssertEqual(removedIDs.count, 1)
        XCTAssertEqual(destinationAccess.acquireCount, 1)
    }
}

private func backupContent(title: String) -> LibraryMarkdownBackupContent {
    LibraryMarkdownBackupContent(
        meeting: Meeting(title: title, startedAt: Date()),
        speakers: [],
        segments: [],
        summary: nil,
        summaryVersion: nil)
}

private enum BackupFakeError: Error {
    case expected
    case incomplete
}

private func completedResult(
    from execution: LibraryMarkdownBackupExecution
) throws -> LibraryMarkdownBackupResult {
    guard case .completed(let result) = execution else {
        XCTFail("Expected a completed backup")
        throw BackupFakeError.incomplete
    }
    return result
}

private struct BackupStoreFake: LibraryMarkdownBackupStore {
    let contents: [LibraryMarkdownBackupContent]
    let failures: [LibraryMarkdownBackupSourceFailure]
    let fails: Bool
    let failsWhileReading: Bool

    init(
        contents: [LibraryMarkdownBackupContent] = [],
        failures: [LibraryMarkdownBackupSourceFailure] = [],
        fails: Bool = false,
        failsWhileReading: Bool = false
    ) {
        self.contents = contents
        self.failures = failures
        self.fails = fails
        self.failsWhileReading = failsWhileReading
    }

    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        if fails { throw BackupFakeError.expected }
        guard mayContinue() else { return .suspended }
        return .ready(BackupSourceSessionFake(
            contents: contents,
            failures: failures,
            failsWhileReading: failsWhileReading))
    }
}

private actor BackupStoreProbe: LibraryMarkdownBackupStore {
    private let contents: [LibraryMarkdownBackupContent]
    private let failures: [LibraryMarkdownBackupSourceFailure]
    private(set) var calls = 0

    init(
        contents: [LibraryMarkdownBackupContent] = [],
        failures: [LibraryMarkdownBackupSourceFailure] = []
    ) {
        self.contents = contents
        self.failures = failures
    }

    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        calls += 1
        guard mayContinue() else { return .suspended }
        return .ready(BackupSourceSessionFake(
            contents: contents,
            failures: failures,
            failsWhileReading: false))
    }
}

private actor BackupSourceSessionFake: LibraryMarkdownBackupSourceSession {
    nonisolated let id = UUID()
    nonisolated let totalMeetings: Int
    private let entries: [LibraryMarkdownBackupSourceEntry]
    private let failsWhileReading: Bool
    private var index = 0
    private var didFailReading = false
    private var currentCursor: LibraryMarkdownBackupSourceCursor?

    init(
        contents: [LibraryMarkdownBackupContent],
        failures: [LibraryMarkdownBackupSourceFailure],
        failsWhileReading: Bool
    ) {
        entries = failures.map(LibraryMarkdownBackupSourceEntry.failure)
            + contents.map(LibraryMarkdownBackupSourceEntry.content)
        self.failsWhileReading = failsWhileReading
        totalMeetings = entries.count
    }

    func next() throws -> LibraryMarkdownBackupSourceEntry? {
        if failsWhileReading, !didFailReading {
            didFailReading = true
            throw BackupFakeError.expected
        }
        guard index < entries.count else { return nil }
        currentCursor = LibraryMarkdownBackupSourceCursor(
            startedAt: Date(
                timeIntervalSince1970: 1_800_000_000 - Double(index)),
            recordID: String(format: "%036d", index))
        defer { index += 1 }
        return entries[index]
    }

    func checkpoint() -> LibraryMarkdownBackupSourceCursor? {
        currentCursor
    }

    func close() {}
}

private actor BackupRecoveryStoreFake:
    LibraryMarkdownBackupRecoveryStore {
    private let failingSaveCalls: Set<Int>
    private let failingRemoveCalls: Set<Int>
    private var saveCalls = 0
    private var removeCalls = 0
    private var states: [UUID: LibraryMarkdownBackupRecoveryState] = [:]
    private(set) var savedStates: [LibraryMarkdownBackupRecoveryState] = []
    private(set) var removedOperationIDs: [UUID] = []

    init(
        failingSaveCalls: Set<Int> = [],
        failingRemoveCalls: Set<Int> = []
    ) {
        self.failingSaveCalls = failingSaveCalls
        self.failingRemoveCalls = failingRemoveCalls
    }

    func apply(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) throws {
        saveCalls += 1
        if failingSaveCalls.contains(saveCalls) {
            throw BackupFakeError.expected
        }
        var state: LibraryMarkdownBackupRecoveryState
        switch mutation {
        case .begin(let bookmark):
            state = LibraryMarkdownBackupRecoveryState(
                operationID: operationID,
                destinationBookmark: bookmark)
        case .updateDestinationBookmark(let bookmark):
            state = try currentState(operationID: operationID)
            state.destinationBookmark = bookmark
        case .reserve(let publication):
            state = try currentState(operationID: operationID)
            state.pendingPublication = publication
        case .complete(let publication):
            state = try currentState(operationID: operationID)
            guard state.pendingPublication == publication else {
                throw BackupFakeError.expected
            }
            state.completedPublications.append(publication)
            state.pendingPublication = nil
        case .clearReservation:
            state = try currentState(operationID: operationID)
            state.pendingPublication = nil
        case .checkpointSource(let cursor):
            state = try currentState(operationID: operationID)
            guard state.pendingPublication == nil else {
                throw BackupFakeError.expected
            }
            state.sourceCursor = cursor
        case .markCompleted:
            state = try currentState(operationID: operationID)
            guard state.pendingPublication == nil else {
                throw BackupFakeError.expected
            }
            state.phase = .completed
        }
        states[operationID] = state
        savedStates.append(state)
    }

    func load(
        operationID: UUID
    ) -> LibraryMarkdownBackupRecoveryState? {
        states[operationID]
    }

    func remove(operationID: UUID) throws {
        removeCalls += 1
        if failingRemoveCalls.contains(removeCalls) {
            throw BackupFakeError.expected
        }
        removedOperationIDs.append(operationID)
        states[operationID] = nil
    }

    private func currentState(
        operationID: UUID
    ) throws -> LibraryMarkdownBackupRecoveryState {
        guard let state = states[operationID] else {
            throw BackupFakeError.expected
        }
        return state
    }
}

private actor BackupDocumentsFake: LibraryMarkdownBackupDocuments {
    let failingTitles: Set<String>
    let onRender: @Sendable () -> Void
    private(set) var renderedTitles: [String] = []

    init(
        failingTitles: Set<String> = [],
        onRender: @escaping @Sendable () -> Void = {}
    ) {
        self.failingTitles = failingTitles
        self.onRender = onRender
    }

    func markdownDocument(for content: LibraryMarkdownBackupContent) async throws -> Data {
        renderedTitles.append(content.meeting.title)
        onRender()
        if failingTitles.contains(content.meeting.title) {
            throw BackupFakeError.expected
        }
        return Data("# \(content.meeting.title)".utf8)
    }
}

private actor BackupFilesFake: LibraryMarkdownBackupFiles {
    let existing: Set<String>
    let failingNames: Set<String>
    let failsInspection: Bool
    let onPublish: @Sendable () async -> Void
    private var collisionCount: Int
    private(set) var publishedNames: [String] = []

    init(
        existing: Set<String> = [],
        failingNames: Set<String> = [],
        failsInspection: Bool = false,
        collisionCount: Int = 0,
        onPublish: @escaping @Sendable () async -> Void = {}
    ) {
        self.existing = existing
        self.failingNames = failingNames
        self.failsInspection = failsInspection
        self.collisionCount = collisionCount
        self.onPublish = onPublish
    }

    func existingMarkdownFileNames(in directory: URL) async throws -> Set<String> {
        if failsInspection { throw BackupFakeError.expected }
        return existing
    }

    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) async throws -> LibraryMarkdownBackupPublication {
        publishedNames.append(fileName)
        await onPublish()
        if failingNames.contains(fileName) { throw BackupFakeError.expected }
        if collisionCount > 0 {
            collisionCount -= 1
            return .nameCollision
        }
        return .published
    }
}

private final class BackupDestinationAccessFake:
    LibraryMarkdownBackupDestinationAccess,
    @unchecked Sendable {
    static let refreshedBookmarkData = Data("refreshed-bookmark".utf8)

    private let lock = NSLock()
    private let failsAcquisition: Bool
    private let refreshAfterFirstAcquisition: Bool
    private var storedPrepareCount = 0
    private var storedAcquireCount = 0
    private var storedCloseCount = 0
    private var storedDirectory: URL?

    init(
        failsAcquisition: Bool = false,
        refreshAfterFirstAcquisition: Bool = false
    ) {
        self.failsAcquisition = failsAcquisition
        self.refreshAfterFirstAcquisition = refreshAfterFirstAcquisition
    }

    var prepareCount: Int {
        lock.withLock { storedPrepareCount }
    }

    var acquireCount: Int {
        lock.withLock { storedAcquireCount }
    }

    var closeCount: Int {
        lock.withLock { storedCloseCount }
    }

    func prepare(
        directory: URL
    ) async throws -> LibraryMarkdownBackupDestinationBookmark {
        lock.withLock {
            storedPrepareCount += 1
            storedDirectory = directory.standardizedFileURL
        }
        return LibraryMarkdownBackupDestinationBookmark(
            data: Data(directory.standardizedFileURL.path.utf8))
    }

    func acquire(
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) async throws -> any LibraryMarkdownBackupDestinationLease {
        let acquisition = lock.withLock {
            storedAcquireCount += 1
            return (
                count: storedAcquireCount,
                directory: storedDirectory)
        }
        if failsAcquisition { throw BackupFakeError.expected }
        let directory = try acquisition.directory ?? Self.directory(from: bookmark)
        let resolvedBookmark = refreshAfterFirstAcquisition && acquisition.count > 1
            ? LibraryMarkdownBackupDestinationBookmark(
                data: Self.refreshedBookmarkData)
            : bookmark
        return BackupDestinationLeaseFake(
            directory: directory,
            bookmark: resolvedBookmark
        ) { [self] in
            lock.withLock { storedCloseCount += 1 }
        }
    }

    private static func directory(
        from bookmark: LibraryMarkdownBackupDestinationBookmark
    ) throws -> URL {
        guard let path = String(data: bookmark.data, encoding: .utf8) else {
            throw BackupFakeError.expected
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private final class BackupDestinationLeaseFake:
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
        let shouldNotify = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        if shouldNotify { onClose() }
    }
}

private final class BackupMaintenanceGateState: @unchecked Sendable {
    private let lock = NSLock()
    private var isPaused = false
    private var didPause = false

    var disposition: DurableMaintenanceDisposition {
        lock.withLock { isPaused ? .pause : .proceed }
    }

    func pauseOnce() {
        lock.withLock {
            guard !didPause else { return }
            didPause = true
            isPaused = true
        }
    }

    func resume() {
        lock.withLock { isPaused = false }
    }
}

private actor BackupProgressRecorder {
    private(set) var events: [LibraryMarkdownBackupProgressEvent] = []

    func append(_ event: LibraryMarkdownBackupProgressEvent) {
        events.append(event)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
