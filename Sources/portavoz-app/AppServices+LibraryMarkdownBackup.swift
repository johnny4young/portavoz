import ApplicationKit
import Foundation
import IntegrationsKit
import StorageKit

struct AppLibraryMarkdownBackupClient: LibraryMarkdownBackupModelClient {
    private let useCase: ExportLibraryMarkdownBackup

    init(store: MeetingStore) {
        useCase = ExportLibraryMarkdownBackup(
            store: store,
            documents: AppLibraryMarkdownBackupDocuments(),
            files: AppLibraryMarkdownBackupFiles())
    }

    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupResult {
        try await useCase.execute(ExportLibraryMarkdownBackupRequest(
            directory: directory,
            progress: progress))
    }
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
