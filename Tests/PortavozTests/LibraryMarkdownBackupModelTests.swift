import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class LibraryMarkdownBackupModelTests: XCTestCase {
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
}

private enum LibraryMarkdownBackupModelTestError: Error {
    case expected
}

@MainActor
private final class LibraryMarkdownBackupModelClientFake:
    LibraryMarkdownBackupModelClient {
    let result: LibraryMarkdownBackupResult
    let error: Error?
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
        self.result = result
        self.error = error
    }

    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupResult {
        calls += 1
        directories.append(directory)
        await progress(.preparing)
        let event = LibraryMarkdownBackupProgressEvent.exporting(
            LibraryMarkdownBackupProgress(
                completedMeetings: result.totalMeetings,
                totalMeetings: result.totalMeetings,
                exportedMeetings: result.exportedCount,
                failedMeetings: result.failures.count))
        observedProgress.append(.preparing)
        observedProgress.append(event)
        await progress(event)
        if let error { throw error }
        return result
    }
}
