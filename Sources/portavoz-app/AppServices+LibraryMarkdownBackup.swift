import ApplicationKit
import CryptoKit
import Darwin
import Foundation
import IntegrationsKit
import PlatformKit
import PortavozCore
import StorageKit

struct AppLibraryMarkdownBackupClient: LibraryMarkdownBackupModelClient {
    private let store: MeetingStore
    private let recoveryStore: AppLibraryMarkdownBackupRecoveryStore
    private let useCase: ExportLibraryMarkdownBackup
    private let cleanupOnLaunch: Bool

    init(
        store: MeetingStore,
        maintenanceGate: DurableMaintenanceGate,
        cleanupOnLaunch: Bool,
        recoveryRoot: URL
    ) {
        self.store = store
        self.cleanupOnLaunch = cleanupOnLaunch
        let recoveryStore = AppLibraryMarkdownBackupRecoveryStore(
            root: recoveryRoot)
        self.recoveryStore = recoveryStore
        useCase = ExportLibraryMarkdownBackup(
            store: store,
            documents: AppLibraryMarkdownBackupDocuments(),
            files: AppLibraryMarkdownBackupFiles(),
            destinationAccess: AppBackupDestinationAccess(),
            recoveryStore: recoveryStore,
            maintenanceGate: maintenanceGate)
    }

    func cleanupAbandonedLibraryMarkdownBackupStages() async {
        guard cleanupOnLaunch else { return }
        let removedStageIDs =
            await store.cleanupAbandonedLibraryMarkdownBackupStages()
        for stageID in removedStageIDs {
            try? await recoveryStore.remove(operationID: stageID)
        }
    }

    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution {
        try await useCase.execute(ExportLibraryMarkdownBackupRequest(
            directory: directory,
            progress: progress))
    }
}

struct AppBackupDestinationAccess: LibraryMarkdownBackupDestinationAccess {
    func prepare(
        directory: URL
    ) async throws -> LibraryMarkdownBackupDestinationBookmark {
        try await Task.detached(priority: .utility) {
            LibraryMarkdownBackupDestinationBookmark(
                data: try PersistentFileBookmark().make(for: directory))
        }.value
    }

    func acquire(
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) async throws -> any LibraryMarkdownBackupDestinationLease {
        try await Task.detached(priority: .utility) {
            let resolution = try PersistentFileBookmark().resolve(bookmark.data)
            return AppBackupDestinationLease(
                directory: resolution.url,
                bookmark: LibraryMarkdownBackupDestinationBookmark(
                    data: resolution.bookmarkData))
        }.value
    }
}

private final class AppBackupDestinationLease:
    LibraryMarkdownBackupDestinationLease,
    @unchecked Sendable {
    let directory: URL
    let bookmark: LibraryMarkdownBackupDestinationBookmark

    init(
        directory: URL,
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) {
        self.directory = directory
        self.bookmark = bookmark
    }

    func close() {}
}

struct AppLibraryMarkdownBackupDocuments: LibraryMarkdownBackupDocuments {
    func markdownDocument(
        for content: LibraryMarkdownBackupContent
    ) async throws -> Data {
        await Task.detached(priority: .utility) {
            Data(MeetingExporter.markdown(
                meeting: content.meeting,
                speakers: content.speakers,
                segments: content.segments,
                summary: content.summary,
                summaryVersion: content.summaryVersion).utf8)
        }.value
    }
}

struct AppLibraryMarkdownBackupFiles: LibraryMarkdownBackupFiles {
    func existingMarkdownFileNames(in directory: URL) async throws -> Set<String> {
        try await Task.detached(priority: .utility) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            return Set(urls.compactMap { url in
                url.pathExtension.lowercased() == "md" ? url.lastPathComponent : nil
            })
        }.value
    }

    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) async throws -> LibraryMarkdownBackupPublication {
        try await Task.detached(priority: .utility) {
            guard Self.isSafeFileName(fileName) else {
                throw AppLibraryMarkdownBackupFileError.invalidFileName
            }
            let fileManager = FileManager.default
            let temporary = directory.appendingPathComponent(
                ".portavoz-backup-\(UUID().uuidString).tmp")
            let destination = directory.appendingPathComponent(fileName)
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                return .published
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                return .nameCollision
            }
        }.value
    }

    func evidence(
        for publication: LibraryMarkdownBackupRecoveryPublication,
        in directory: URL
    ) async throws -> BackupPublicationEvidence {
        let task = Task.detached(priority: .utility) {
            () throws -> BackupPublicationEvidence in
            guard Self.isSafeFileName(publication.fileName) else {
                return .conflicting
            }
            let directoryDescriptor = Darwin.open(
                directory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard directoryDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(directoryDescriptor) }

            let descriptor = Darwin.openat(
                directoryDescriptor,
                publication.fileName,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                if errno == ENOENT { return .missing }
                if errno == ELOOP { return .conflicting }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true)
            defer { try? handle.close() }

            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard information.st_mode & S_IFMT == S_IFREG,
                  information.st_size == Int64(publication.byteCount)
            else { return .conflicting }

            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1 << 20),
                  !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            let digest = hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
            return digest == publication.sha256 ? .matching : .conflicting
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func isSafeFileName(_ fileName: String) -> Bool {
        let portableInvalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let fileURL = URL(fileURLWithPath: fileName)
        return !fileName.isEmpty
            && !fileName.hasPrefix(".")
            && fileURL.pathExtension.lowercased() == "md"
            && fileName.unicodeScalars.allSatisfy { !portableInvalid.contains($0) }
            && fileURL.lastPathComponent == fileName
    }
}

private enum AppLibraryMarkdownBackupFileError: Error {
    case invalidFileName
}

extension AppServices {
    static func makeLibraryMarkdownBackupModel(
        store: MeetingStore,
        captureState: AppResourceCaptureState,
        usesTemporaryStore: Bool
    ) -> LibraryMarkdownBackupModel {
        let recoveryRoot = usesTemporaryStore
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Portavoz-\(UUID().uuidString)",
                    isDirectory: true)
                .appendingPathComponent(
                    "LibraryMarkdownBackupRecovery",
                    isDirectory: true)
            : supportRoot.appendingPathComponent(
                "LibraryMarkdownBackupRecovery",
                isDirectory: true)
        return LibraryMarkdownBackupModel(client: AppLibraryMarkdownBackupClient(
            store: store,
            maintenanceGate: AppResourceGovernorMaintenanceGate.make(
                captureState: captureState),
            cleanupOnLaunch: !usesTemporaryStore,
            recoveryRoot: recoveryRoot))
    }
}
