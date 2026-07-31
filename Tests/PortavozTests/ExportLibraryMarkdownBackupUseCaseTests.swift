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
            files: files)

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
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(
                contents: [healthy, renderFailure, writeFailure],
                failures: [sourceFailure]),
            documents: documents,
            files: files)

        let result = try completedResult(from: await useCase.execute(
            ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true))))

        XCTAssertEqual(result.totalMeetings, 4)
        XCTAssertEqual(result.exportedFileNames, ["Healthy.md"])
        XCTAssertEqual(result.failures.map(\.stage), [.source, .document, .publication])
        XCTAssertEqual(result.failures.map(\.title), [
            "Unreadable", "Render failure", "Write failure",
        ])
    }

    func testSourceFailureMapsToStableFatalError() async {
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(fails: true),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake())

        await XCTAssertThrowsErrorAsync(
            try await useCase.execute(ExportLibraryMarkdownBackupRequest(
                directory: URL(fileURLWithPath: "/backup", isDirectory: true)))
        ) { error in
            XCTAssertEqual(error as? LibraryMarkdownBackupError, .libraryUnavailable)
        }
    }

    func testDestinationInspectionFailureMapsToStableFatalError() async {
        let useCase = ExportLibraryMarkdownBackup(
            store: BackupStoreFake(contents: [backupContent(title: "Meeting")]),
            documents: BackupDocumentsFake(),
            files: BackupFilesFake(failsInspection: true))

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
            files: BackupFilesFake())

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
            files: files)

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
        let useCase = ExportLibraryMarkdownBackup(
            store: store,
            documents: documents,
            files: files,
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
        let useCase = ExportLibraryMarkdownBackup(
            store: store,
            documents: documents,
            files: files,
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

        gateState.resume()
        let result = try completedResult(from: await useCase.execute(request))
        let finalStoreCalls = await store.calls
        let finalRenderedTitles = await documents.renderedTitles
        let finalPublishedNames = await files.publishedNames

        XCTAssertEqual(result.exportedFileNames, ["First.md", "Second.md"])
        XCTAssertEqual(finalStoreCalls, 1)
        XCTAssertEqual(finalRenderedTitles, ["First", "Second"])
        XCTAssertEqual(finalPublishedNames, ["First.md", "Second.md"])
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

    init(
        contents: [LibraryMarkdownBackupContent] = [],
        failures: [LibraryMarkdownBackupSourceFailure] = [],
        fails: Bool = false
    ) {
        self.contents = contents
        self.failures = failures
        self.fails = fails
    }

    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        if fails { throw BackupFakeError.expected }
        guard mayContinue() else { return .suspended }
        return .ready(BackupSourceSessionFake(
            contents: contents,
            failures: failures))
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
            failures: failures))
    }
}

private actor BackupSourceSessionFake: LibraryMarkdownBackupSourceSession {
    nonisolated let totalMeetings: Int
    private let entries: [LibraryMarkdownBackupSourceEntry]
    private var index = 0

    init(
        contents: [LibraryMarkdownBackupContent],
        failures: [LibraryMarkdownBackupSourceFailure]
    ) {
        entries = failures.map(LibraryMarkdownBackupSourceEntry.failure)
            + contents.map(LibraryMarkdownBackupSourceEntry.content)
        totalMeetings = entries.count
    }

    func next() -> LibraryMarkdownBackupSourceEntry? {
        guard index < entries.count else { return nil }
        defer { index += 1 }
        return entries[index]
    }

    func close() {}
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
    let onPublish: @Sendable () -> Void
    private var collisionCount: Int
    private(set) var publishedNames: [String] = []

    init(
        existing: Set<String> = [],
        failingNames: Set<String> = [],
        failsInspection: Bool = false,
        collisionCount: Int = 0,
        onPublish: @escaping @Sendable () -> Void = {}
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
        onPublish()
        if failingNames.contains(fileName) { throw BackupFakeError.expected }
        if collisionCount > 0 {
            collisionCount -= 1
            return .nameCollision
        }
        return .published
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
