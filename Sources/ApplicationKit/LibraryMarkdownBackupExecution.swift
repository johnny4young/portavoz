import Foundation
import PortavozCore

public enum LibraryMarkdownBackupFailureStage:
    String,
    Codable,
    Equatable,
    Sendable {
    case source
    case document
    case publication
}

public struct LibraryMarkdownBackupFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String
    public let stage: LibraryMarkdownBackupFailureStage

    public init(
        meetingID: MeetingID?,
        title: String,
        stage: LibraryMarkdownBackupFailureStage
    ) {
        self.meetingID = meetingID
        self.title = title
        self.stage = stage
    }
}

public struct LibraryMarkdownBackupResult: Equatable, Sendable {
    public let totalMeetings: Int
    public let exportedFileNames: [String]
    public let failures: [LibraryMarkdownBackupFailure]

    public init(
        totalMeetings: Int,
        exportedFileNames: [String],
        failures: [LibraryMarkdownBackupFailure]
    ) {
        self.totalMeetings = totalMeetings
        self.exportedFileNames = exportedFileNames
        self.failures = failures
    }

    public var exportedCount: Int { exportedFileNames.count }
}

public enum LibraryMarkdownBackupExecution: Equatable, Sendable {
    case completed(LibraryMarkdownBackupResult)
    case suspended
}

public struct LibraryMarkdownBackupProgress: Equatable, Sendable {
    public let completedMeetings: Int
    public let totalMeetings: Int
    public let exportedMeetings: Int
    public let failedMeetings: Int

    public init(
        completedMeetings: Int,
        totalMeetings: Int,
        exportedMeetings: Int,
        failedMeetings: Int
    ) {
        self.completedMeetings = completedMeetings
        self.totalMeetings = totalMeetings
        self.exportedMeetings = exportedMeetings
        self.failedMeetings = failedMeetings
    }
}

public enum LibraryMarkdownBackupProgressEvent: Equatable, Sendable {
    case preparing
    case exporting(LibraryMarkdownBackupProgress)
}

public typealias LibraryMarkdownBackupProgressHandler =
    @Sendable (LibraryMarkdownBackupProgressEvent) async -> Void

public enum LibraryMarkdownBackupError: Error, Equatable, Sendable {
    case libraryUnavailable
    case destinationUnavailable
    case operationInProgress
}

public struct ExportLibraryMarkdownBackupRequest: Sendable {
    public let directory: URL
    public let progress: LibraryMarkdownBackupProgressHandler

    public init(
        directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler = { _ in }
    ) {
        self.directory = directory
        self.progress = progress
    }
}
