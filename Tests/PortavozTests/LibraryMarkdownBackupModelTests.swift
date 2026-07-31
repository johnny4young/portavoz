import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class LibraryMarkdownBackupModelTests: XCTestCase {
    func testLaunchRecoveryCleansStagesOnlyOnce() async {
        let client = LibraryMarkdownBackupModelClientFake()
        let model = LibraryMarkdownBackupModel(client: client)

        await model.recoverAtLaunch()
        await model.recoverAtLaunch()

        XCTAssertEqual(client.cleanupCalls, 1)
        XCTAssertEqual(model.phase, .idle)
    }

    func testExportPublishesProgressAndCompletedPartialResult() async {
        let result = LibraryMarkdownBackupResult(
            totalMeetings: 2,
            exportedFileNames: ["One.md"],
            failures: [LibraryMarkdownBackupFailure(
                meetingID: nil,
                title: "Two",
                stage: .source)])
        let client = LibraryMarkdownBackupModelClientFake(result: result)
        let model = LibraryMarkdownBackupModel(client: client)

        await model.export(to: URL(fileURLWithPath: "/backup", isDirectory: true))

        XCTAssertEqual(model.phase, .completed(result))
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(client.directories.map(\.path), ["/backup"])
        XCTAssertEqual(client.observedProgress, [
            .preparing,
            .exporting(LibraryMarkdownBackupProgress(
                completedMeetings: 2,
                totalMeetings: 2,
                exportedMeetings: 1,
                failedMeetings: 1)),
        ])
    }

    func testExportMapsStableAndUnexpectedFailures() async {
        let libraryClient = LibraryMarkdownBackupModelClientFake(
            error: LibraryMarkdownBackupError.libraryUnavailable)
        let libraryModel = LibraryMarkdownBackupModel(client: libraryClient)
        await libraryModel.export(to: URL(fileURLWithPath: "/library"))
        XCTAssertEqual(libraryModel.phase, .failed(.libraryUnavailable))

        let destinationClient = LibraryMarkdownBackupModelClientFake(
            error: LibraryMarkdownBackupError.destinationUnavailable)
        let destinationModel = LibraryMarkdownBackupModel(client: destinationClient)
        await destinationModel.export(to: URL(fileURLWithPath: "/destination"))
        XCTAssertEqual(destinationModel.phase, .failed(.destinationUnavailable))

        let unexpectedClient = LibraryMarkdownBackupModelClientFake(
            error: LibraryMarkdownBackupModelTestError.expected)
        let unexpectedModel = LibraryMarkdownBackupModel(client: unexpectedClient)
        await unexpectedModel.export(to: URL(fileURLWithPath: "/unexpected"))
        XCTAssertEqual(unexpectedModel.phase, .failed(.unexpected))
    }

    func testSuspendedExportResumesFromMaintenanceSignal() async {
        let result = LibraryMarkdownBackupResult(
            totalMeetings: 1,
            exportedFileNames: ["Meeting.md"],
            failures: [])
        let client = LibraryMarkdownBackupModelClientFake(
            executions: [.suspended, .completed(result)])
        let model = LibraryMarkdownBackupModel(client: client)

        await model.export(to: URL(fileURLWithPath: "/backup", isDirectory: true))

        XCTAssertEqual(model.phase, .running(.preparing))
        XCTAssertEqual(client.calls, 1)

        model.maintenanceMayResume()
        await waitUntil { model.phase == .completed(result) }

        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(client.directories.map(\.path), ["/backup", "/backup"])
    }

    func testCaptureStopWakeIsNotLostWhileAdmissionIsSuspending() async {
        let result = LibraryMarkdownBackupResult(
            totalMeetings: 1,
            exportedFileNames: ["Meeting.md"],
            failures: [])
        let client = ControlledLibraryMarkdownBackupModelClient(result: result)
        let model = LibraryMarkdownBackupModel(client: client)
        let task = Task {
            await model.export(
                to: URL(fileURLWithPath: "/backup", isDirectory: true))
        }
        await waitUntil { client.firstCallStarted }

        model.maintenanceMayResume()
        client.releaseFirstCall()

        await task.value
        await waitUntil { model.phase == .completed(result) }
        XCTAssertEqual(client.calls, 2)
    }
}

private enum LibraryMarkdownBackupModelTestError: Error {
    case expected
}

@MainActor
private final class LibraryMarkdownBackupModelClientFake:
    LibraryMarkdownBackupModelClient {
    private var executions: [LibraryMarkdownBackupExecution]
    let error: Error?
    var cleanupCalls = 0
    var calls = 0
    var directories: [URL] = []
    var observedProgress: [LibraryMarkdownBackupProgressEvent] = []

    init(
        result: LibraryMarkdownBackupResult = LibraryMarkdownBackupResult(
            totalMeetings: 0,
            exportedFileNames: [],
            failures: []),
        error: Error? = nil
    ) {
        executions = [.completed(result)]
        self.error = error
    }

    init(executions: [LibraryMarkdownBackupExecution]) {
        self.executions = executions
        error = nil
    }

    func cleanupAbandonedLibraryMarkdownBackupStages() async {
        cleanupCalls += 1
    }

    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution {
        calls += 1
        directories.append(directory)
        await progress(.preparing)
        observedProgress.append(.preparing)
        if let error { throw error }
        let execution = executions.removeFirst()
        if case .completed(let result) = execution {
            let event = LibraryMarkdownBackupProgressEvent.exporting(
                LibraryMarkdownBackupProgress(
                    completedMeetings: result.totalMeetings,
                    totalMeetings: result.totalMeetings,
                    exportedMeetings: result.exportedCount,
                    failedMeetings: result.failures.count))
            observedProgress.append(event)
            await progress(event)
        }
        return execution
    }
}

@MainActor
private final class ControlledLibraryMarkdownBackupModelClient:
    LibraryMarkdownBackupModelClient {
    let result: LibraryMarkdownBackupResult
    private(set) var calls = 0
    private(set) var firstCallStarted = false
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    init(result: LibraryMarkdownBackupResult) {
        self.result = result
    }

    func cleanupAbandonedLibraryMarkdownBackupStages() async {}

    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution {
        calls += 1
        await progress(.preparing)
        if calls == 1 {
            firstCallStarted = true
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
            return .suspended
        }
        return .completed(result)
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<100 where !condition() {
        await Task.yield()
    }
    XCTAssertTrue(condition())
}
