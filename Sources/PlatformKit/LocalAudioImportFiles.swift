import Foundation
import PortavozCore

/// Native file operations for the nonsandboxed Mac app. Every supplied URL
/// comes from explicit selection or the application's recording root.
public struct LocalAudioImportFiles: AudioImportFiles {
    let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func prepareSelection(
        _ source: URL, meetingID: MeetingID, title: String,
        preferences: ImportMeetingPreferencesSnapshot
    ) async throws -> AudioImportRequest {
        try await Self.offMainActor {
            try Task.checkCancellation()
            let source = source.standardizedFileURL.resolvingSymlinksInPath()
            let metadata = try AudioImportSourceMetadata.read(source)
            let fileExtension = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
            guard AudioImportRequest.isSafeFileExtension(fileExtension) else {
                throw AudioImportFileError.invalidSource
            }
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withoutImplicitSecurityScope]
            #else
            let options: URL.BookmarkCreationOptions = []
            #endif
            let bookmark = try source.bookmarkData(
                options: options, includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
            return AudioImportRequest(
                meetingID: meetingID, title: title, fileExtension: fileExtension,
                sourceByteCount: metadata.size, sourceModifiedAt: metadata.modifiedAt,
                sourceBookmark: bookmark, preferences: preferences)
        }
    }

    public func copySelectedAudio(_ input: AudioImportRequest) async throws -> AudioImportCopy {
        try await Self.offMainActor {
            try Task.checkCancellation()
            guard let bookmark = input.sourceBookmark,
                  input.copiedAudioDirectory == nil, input.copiedAudioDigest == nil else {
                throw AudioImportFileError.invalidSource
            }
            var stale = false
            let source: URL
            do {
                source = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw AudioImportFileError.sourceUnavailable
            }
            let before = try AudioImportSourceMetadata.read(source)
            guard before.matches(input) else { throw AudioImportFileError.sourceChanged }
            let identityKeys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
            let selectedValues = URL.resourceValues(forKeys: identityKeys, fromBookmarkData: bookmark)
            guard let admitted = selectedValues?.fileResourceIdentifier,
                  let current = try source.resourceValues(forKeys: identityKeys).fileResourceIdentifier,
                  admitted.isEqual(current) else { throw AudioImportFileError.sourceChanged }
            let relative = input.copyDirectory
            let directory = try ownedDirectory(relative, meetingID: input.meetingID, createParents: true)
            let files = FileManager.default
            // Only an unpublished, durably reserved stage reaches this method.
            // Source validation precedes reclamation so an unavailable source
            // does not destroy the last, possibly complete staged bytes.
            if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                let destination = try audioURL(in: directory, fileExtension: input.fileExtension)
                let digest = try AudioImportFileTransfer.copy(from: source, to: destination, expectedSize: before.size)
                let afterIdentity = try URL(fileURLWithPath: source.path)
                    .resourceValues(forKeys: identityKeys).fileResourceIdentifier
                guard try AudioImportSourceMetadata.read(source) == before,
                      let afterIdentity, admitted.isEqual(afterIdentity) else {
                    throw AudioImportFileError.sourceChanged
                }
                return AudioImportCopy(fileURL: destination, relativeDirectory: relative, digest: digest)
            } catch {
                try? files.removeItem(at: directory)
                throw error
            }
        }
    }

    public func verifyOwnedAudio(_ input: AudioImportRequest) async throws -> AudioImportCopy {
        try await Self.offMainActor {
            try Task.checkCancellation()
            guard input.sourceBookmark == nil, let relative = input.copiedAudioDirectory,
                  let expected = input.copiedAudioDigest else { throw AudioImportFileError.invalidOwnedCopy }
            let directory = try ownedDirectory(relative, meetingID: input.meetingID, createParents: false)
            let file = try audioURL(in: directory, fileExtension: input.fileExtension)
            let metadata = try AudioImportSourceMetadata.read(file)
            guard metadata.size == input.sourceByteCount else { throw AudioImportFileError.invalidOwnedCopy }
            let digest = try AudioImportFileTransfer.digest(file, expectedSize: metadata.size)
            guard digest == expected, try AudioImportSourceMetadata.read(file) == metadata else {
                throw AudioImportFileError.invalidOwnedCopy
            }
            return AudioImportCopy(fileURL: file, relativeDirectory: relative, digest: digest)
        }
    }

    static func offMainActor<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func ownedDirectory(_ relative: String, meetingID: MeetingID, createParents: Bool) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, parts.count == 4, parts[0] == "Audio",
              parts[1] == Substring(meetingID.rawValue.uuidString), parts[2] == "Imports",
              let attempt = UUID(uuidString: String(parts[3])), attempt.uuidString == parts[3] else {
            throw AudioImportFileError.invalidOwnedCopy
        }
        var directory = root
        for (index, part) in parts.enumerated() {
            directory.appendPathComponent(String(part), isDirectory: true)
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
                throw AudioImportFileError.invalidOwnedCopy
            }
            if createParents, index < parts.count - 1 {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        return directory
    }

    private func audioURL(in directory: URL, fileExtension: String) throws -> URL {
        guard AudioImportRequest.isSafeFileExtension(fileExtension) else {
            throw AudioImportFileError.invalidSource
        }
        let url = directory.appendingPathComponent("system.\(fileExtension)")
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw AudioImportFileError.invalidOwnedCopy
        }
        return url
    }
}
