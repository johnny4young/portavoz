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

public enum LibraryMarkdownBackupSourceEntry: Sendable {
    case content(LibraryMarkdownBackupContent)
    case failure(LibraryMarkdownBackupSourceFailure)
}

public protocol LibraryMarkdownBackupSourceSession: Sendable {
    var totalMeetings: Int { get }
    func next() async throws -> LibraryMarkdownBackupSourceEntry?
    func close() async
}

public enum LibraryMarkdownBackupSourcePreparation: Sendable {
    case ready(any LibraryMarkdownBackupSourceSession)
    case suspended
}

/// Creates one read-consistent, incrementally consumed projection of the live
/// library. Storage corruption remains isolated per aggregate.
public protocol LibraryMarkdownBackupStore: Sendable {
    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation
}

extension MeetingStore: LibraryMarkdownBackupStore {
    public func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        switch try await prepareLibraryMarkdownBackupStage(
            mayContinue: mayContinue
        ) {
        case .ready(let stage):
            return .ready(MeetingStoreLibraryMarkdownBackupSource(stage: stage))
        case .suspended:
            return .suspended
        }
    }
}

private actor MeetingStoreLibraryMarkdownBackupSource:
    LibraryMarkdownBackupSourceSession {
    nonisolated let totalMeetings: Int
    private let stage: MeetingMarkdownBackupStage

    init(stage: MeetingMarkdownBackupStage) {
        self.stage = stage
        totalMeetings = stage.totalMeetings
    }

    func next() async throws -> LibraryMarkdownBackupSourceEntry? {
        guard let entry = try await stage.next() else { return nil }
        switch entry {
        case .meeting(let snapshot):
            return .content(LibraryMarkdownBackupContent(
                meeting: snapshot.meeting,
                speakers: snapshot.speakers,
                segments: snapshot.segments,
                summary: snapshot.summary,
                summaryVersion: snapshot.summaryVersion))
        case .failure(let failure):
            return .failure(LibraryMarkdownBackupSourceFailure(
                meetingID: failure.meetingID,
                title: failure.title))
        }
    }

    func close() async {
        await stage.close()
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

/// Exports every healthy live meeting while preserving failures as typed,
/// content-free partial results. Existing files are never replaced. The actor
/// retains one staged run across capture-policy suspension.
public actor ExportLibraryMarkdownBackup: ApplicationUseCase {
    private static let workload = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .mediaExport,
        operation: .execute)

    private let store: any LibraryMarkdownBackupStore
    private let documents: any LibraryMarkdownBackupDocuments
    private let files: any LibraryMarkdownBackupFiles
    private let maintenanceGate: DurableMaintenanceGate
    private var preparedSource: PreparedLibraryMarkdownBackupSource?
    private var activeRun: ActiveLibraryMarkdownBackupRun?
    private var isExecuting = false

    public init(
        store: any LibraryMarkdownBackupStore,
        documents: any LibraryMarkdownBackupDocuments,
        files: any LibraryMarkdownBackupFiles,
        maintenanceGate: DurableMaintenanceGate = .unrestricted
    ) {
        self.store = store
        self.documents = documents
        self.files = files
        self.maintenanceGate = maintenanceGate
    }

    public func execute(
        _ request: ExportLibraryMarkdownBackupRequest
    ) async throws -> LibraryMarkdownBackupExecution {
        guard !isExecuting else {
            throw LibraryMarkdownBackupError.operationInProgress
        }
        isExecuting = true
        defer { isExecuting = false }

        await request.progress(.preparing)
        if activeRun == nil {
            guard try await prepareRun(in: request.directory) else {
                return .suspended
            }
        }
        guard var run = activeRun,
              Self.sameDirectory(run.directory, request.directory)
        else {
            throw LibraryMarkdownBackupError.operationInProgress
        }

        await publishProgress(
            total: run.totalMeetings,
            exported: run.exportedFileNames.count,
            failures: run.failures.count,
            through: request.progress)

        while shouldProceed(at: .checkpoint) {
            if let completion = try await advance(
                run: &run,
                progress: request.progress
            ) {
                return completion
            }
            activeRun = run
        }
        activeRun = run
        return .suspended
    }
}

private extension ExportLibraryMarkdownBackup {
    func shouldProceed(
        at phase: ResourceGovernorEvaluationPhase
    ) -> Bool {
        maintenanceGate.disposition(
            for: Self.workload,
            phase: phase) == .proceed
    }

    func advance(
        run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution? {
        switch run.pending {
        case nil:
            return try await loadNextEntry(
                into: &run,
                progress: progress)
        case .content(let content):
            await render(
                content,
                into: &run,
                progress: progress)
            return nil
        case .document(let content, let data):
            await publish(
                data,
                for: content,
                into: &run,
                progress: progress)
            return nil
        }
    }

    func loadNextEntry(
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution? {
        let entry: LibraryMarkdownBackupSourceEntry?
        do {
            entry = try await run.source.next()
        } catch {
            await run.source.close()
            activeRun = nil
            throw LibraryMarkdownBackupError.libraryUnavailable
        }
        guard let entry else {
            await run.source.close()
            activeRun = nil
            return .completed(LibraryMarkdownBackupResult(
                totalMeetings: run.totalMeetings,
                exportedFileNames: run.exportedFileNames,
                failures: run.failures))
        }
        switch entry {
        case .content(let content):
            run.pending = .content(content)
        case .failure(let failure):
            run.failures.append(Self.sourceFailure(failure))
            await publishProgress(for: run, through: progress)
        }
        return nil
    }

    func render(
        _ content: LibraryMarkdownBackupContent,
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async {
        do {
            run.pending = .document(
                content,
                try await documents.markdownDocument(for: content))
        } catch {
            run.pending = nil
            run.failures.append(Self.failure(
                for: content,
                stage: .document))
            await publishProgress(for: run, through: progress)
        }
    }

    func publish(
        _ data: Data,
        for content: LibraryMarkdownBackupContent,
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async {
        let outcome = await publish(
            data,
            for: content,
            to: run.directory,
            allocator: &run.allocator)
        run.pending = nil
        switch outcome {
        case .success(let fileName):
            run.exportedFileNames.append(fileName)
        case .failure(let failure):
            run.failures.append(failure)
        }
        await publishProgress(for: run, through: progress)
    }

    func prepareRun(in directory: URL) async throws -> Bool {
        if let preparedSource {
            guard Self.sameDirectory(preparedSource.directory, directory) else {
                throw LibraryMarkdownBackupError.operationInProgress
            }
        } else {
            guard shouldProceed(at: .admission) else { return false }
            let gate = maintenanceGate
            let workload = Self.workload
            let preparation: LibraryMarkdownBackupSourcePreparation
            do {
                preparation = try await store.prepareLibraryMarkdownBackupSource {
                    gate.disposition(
                        for: workload,
                        phase: .checkpoint) == .proceed
                }
            } catch {
                throw LibraryMarkdownBackupError.libraryUnavailable
            }
            switch preparation {
            case .ready(let source):
                preparedSource = PreparedLibraryMarkdownBackupSource(
                    directory: directory,
                    source: source)
            case .suspended:
                return false
            }
        }

        guard shouldProceed(at: .checkpoint) else { return false }
        guard let preparedSource else {
            preconditionFailure("prepared backup source must exist")
        }
        do {
            activeRun = ActiveLibraryMarkdownBackupRun(
                directory: preparedSource.directory,
                source: preparedSource.source,
                allocator: try await fileNameAllocator(in: directory))
            self.preparedSource = nil
            return true
        } catch {
            await preparedSource.source.close()
            self.preparedSource = nil
            throw error
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

    func publish(
        _ data: Data,
        for content: LibraryMarkdownBackupContent,
        to directory: URL,
        allocator: inout BackupFileNameAllocator
    ) async -> LibraryMarkdownBackupExportOutcome {
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

    func publishProgress(
        for run: ActiveLibraryMarkdownBackupRun,
        through handler: LibraryMarkdownBackupProgressHandler
    ) async {
        await publishProgress(
            total: run.totalMeetings,
            exported: run.exportedFileNames.count,
            failures: run.failures.count,
            through: handler)
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
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

private struct PreparedLibraryMarkdownBackupSource: Sendable {
    let directory: URL
    let source: any LibraryMarkdownBackupSourceSession
}

private struct ActiveLibraryMarkdownBackupRun: Sendable {
    let directory: URL
    let source: any LibraryMarkdownBackupSourceSession
    var allocator: BackupFileNameAllocator
    var exportedFileNames: [String] = []
    var failures: [LibraryMarkdownBackupFailure] = []
    var pending: PendingLibraryMarkdownBackupDocument?

    var totalMeetings: Int { source.totalMeetings }
}

private enum PendingLibraryMarkdownBackupDocument: Sendable {
    case content(LibraryMarkdownBackupContent)
    case document(LibraryMarkdownBackupContent, Data)
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
