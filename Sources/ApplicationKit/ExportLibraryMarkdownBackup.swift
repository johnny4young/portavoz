import Foundation
import PortavozCore
import StorageKit

/// One storage-independent meeting document used by the whole-library backup.
public struct LibraryMarkdownBackupContent: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let summaryVersion: Int?

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        summaryVersion: Int?
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.summaryVersion = summaryVersion
    }
}

/// A corrupt live aggregate is reported without exposing a storage error or
/// preventing healthy meetings from being backed up.
public struct LibraryMarkdownBackupSourceFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String

    public init(meetingID: MeetingID?, title: String) {
        self.meetingID = meetingID
        self.title = title
    }
}

public struct LibraryMarkdownBackupSourceSnapshot: Sendable {
    public let contents: [LibraryMarkdownBackupContent]
    public let failures: [LibraryMarkdownBackupSourceFailure]

    public init(
        contents: [LibraryMarkdownBackupContent],
        failures: [LibraryMarkdownBackupSourceFailure]
    ) {
        self.contents = contents
        self.failures = failures
    }
}

/// One read-consistent projection of every live meeting. Storage corruption is
/// isolated per aggregate; failure to open the snapshot itself remains fatal.
public protocol LibraryMarkdownBackupStore: Sendable {
    func libraryMarkdownBackupSource() async throws
        -> LibraryMarkdownBackupSourceSnapshot
}

extension MeetingStore: LibraryMarkdownBackupStore {
    public func libraryMarkdownBackupSource() async throws
        -> LibraryMarkdownBackupSourceSnapshot {
        let snapshot = try await libraryMarkdownBackupSnapshots()
        return LibraryMarkdownBackupSourceSnapshot(
            contents: snapshot.meetings.map {
                LibraryMarkdownBackupContent(
                    meeting: $0.meeting,
                    speakers: $0.speakers,
                    segments: $0.segments,
                    summary: $0.summary,
                    summaryVersion: $0.summaryVersion)
            },
            failures: snapshot.failures.map {
                LibraryMarkdownBackupSourceFailure(
                    meetingID: $0.meetingID,
                    title: $0.title)
            })
    }
}

/// External Markdown rendering remains behind an app adapter so
/// IntegrationsKit never leaks into Settings presentation.
public protocol LibraryMarkdownBackupDocuments: Sendable {
    func markdownDocument(for content: LibraryMarkdownBackupContent) async throws -> Data
}

public enum LibraryMarkdownBackupPublication: Equatable, Sendable {
    case published
    case nameCollision
}

/// Filesystem capability. Implementations must publish complete files with a
/// same-directory atomic move and must never replace an existing destination.
public protocol LibraryMarkdownBackupFiles: Sendable {
    func existingMarkdownFileNames(in directory: URL) async throws -> Set<String>
    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) async throws -> LibraryMarkdownBackupPublication
}

public enum LibraryMarkdownBackupFailureStage: String, Equatable, Sendable {
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

/// Exports every healthy live meeting while preserving failures as typed,
/// content-free partial results. Existing files are never replaced.
public struct ExportLibraryMarkdownBackup: ApplicationUseCase {
    private let store: any LibraryMarkdownBackupStore
    private let documents: any LibraryMarkdownBackupDocuments
    private let files: any LibraryMarkdownBackupFiles

    public init(
        store: any LibraryMarkdownBackupStore,
        documents: any LibraryMarkdownBackupDocuments,
        files: any LibraryMarkdownBackupFiles
    ) {
        self.store = store
        self.documents = documents
        self.files = files
    }

    public func execute(
        _ request: ExportLibraryMarkdownBackupRequest
    ) async throws -> LibraryMarkdownBackupResult {
        await request.progress(.preparing)
        let source = try await sourceSnapshot()
        var allocator = try await fileNameAllocator(in: request.directory)
        var failures = source.failures.map(Self.sourceFailure)
        var exportedFileNames: [String] = []
        let total = source.contents.count + failures.count
        await publishProgress(
            total: total,
            exported: exportedFileNames.count,
            failures: failures.count,
            through: request.progress)

        for content in source.contents {
            let outcome = await export(
                content,
                to: request.directory,
                allocator: &allocator)
            switch outcome {
            case .success(let fileName): exportedFileNames.append(fileName)
            case .failure(let failure): failures.append(failure)
            }
            await publishProgress(
                total: total,
                exported: exportedFileNames.count,
                failures: failures.count,
                through: request.progress)
        }
        return LibraryMarkdownBackupResult(
            totalMeetings: total,
            exportedFileNames: exportedFileNames,
            failures: failures)
    }
}

private extension ExportLibraryMarkdownBackup {
    func sourceSnapshot() async throws -> LibraryMarkdownBackupSourceSnapshot {
        do {
            return try await store.libraryMarkdownBackupSource()
        } catch {
            throw LibraryMarkdownBackupError.libraryUnavailable
        }
    }

    func fileNameAllocator(in directory: URL) async throws -> BackupFileNameAllocator {
        do {
            return BackupFileNameAllocator(
                existing: try await files.existingMarkdownFileNames(in: directory))
        } catch {
            throw LibraryMarkdownBackupError.destinationUnavailable
        }
    }

    func export(
        _ content: LibraryMarkdownBackupContent,
        to directory: URL,
        allocator: inout BackupFileNameAllocator
    ) async -> LibraryMarkdownBackupExportOutcome {
        let data: Data
        do {
            data = try await documents.markdownDocument(for: content)
        } catch {
            return .failure(Self.failure(for: content, stage: .document))
        }

        for _ in 0..<10_000 {
            let fileName = allocator.nextFileName(for: content.meeting.title)
            do {
                switch try await files.publishMarkdownDocument(
                    data,
                    named: fileName,
                    in: directory
                ) {
                case .published: return .success(fileName)
                case .nameCollision: continue
                }
            } catch {
                return .failure(Self.failure(for: content, stage: .publication))
            }
        }
        return .failure(Self.failure(for: content, stage: .publication))
    }

    func publishProgress(
        total: Int,
        exported: Int,
        failures: Int,
        through handler: LibraryMarkdownBackupProgressHandler
    ) async {
        await handler(.exporting(LibraryMarkdownBackupProgress(
            completedMeetings: exported + failures,
            totalMeetings: total,
            exportedMeetings: exported,
            failedMeetings: failures)))
    }

    static func sourceFailure(
        _ failure: LibraryMarkdownBackupSourceFailure
    ) -> LibraryMarkdownBackupFailure {
        LibraryMarkdownBackupFailure(
            meetingID: failure.meetingID,
            title: failure.title,
            stage: .source)
    }

    static func failure(
        for content: LibraryMarkdownBackupContent,
        stage: LibraryMarkdownBackupFailureStage
    ) -> LibraryMarkdownBackupFailure {
        LibraryMarkdownBackupFailure(
            meetingID: content.meeting.id,
            title: content.meeting.title,
            stage: stage)
    }
}

private enum LibraryMarkdownBackupExportOutcome {
    case success(String)
    case failure(LibraryMarkdownBackupFailure)
}

private struct BackupFileNameAllocator {
    private static let portableReservedNames: Set<String> = [
        "aux", "con", "nul", "prn",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"
    ]
    private var used: Set<String>
    private var nextSuffix: [String: Int] = [:]

    init(existing: Set<String>) {
        used = Set(existing.map(Self.collisionKey))
    }

    mutating func nextFileName(for title: String) -> String {
        let base = Self.sanitized(title)
        let key = Self.collisionKey(base)
        var suffix = nextSuffix[key] ?? 1
        while true {
            let stem = suffix == 1 ? base : "\(base) \(suffix)"
            let fileName = "\(stem).md"
            suffix += 1
            guard used.insert(Self.collisionKey(fileName)).inserted else { continue }
            nextSuffix[key] = suffix
            return fileName
        }
    }

    private static func sanitized(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        var cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = String(cleaned.prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleaned.isEmpty else { return "meeting" }

        let deviceStem = cleaned.split(separator: ".", maxSplits: 1)
            .first.map(String.init) ?? cleaned
        if portableReservedNames.contains(collisionKey(deviceStem)) {
            return "meeting-\(cleaned)"
        }
        return cleaned
    }

    private static func collisionKey(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }
}
