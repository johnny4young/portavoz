import Foundation

/// A persistent file-system identity without an implicit cross-process
/// capability. Portavoz is not sandboxed today; a future sandbox composition
/// can replace the application adapter with security-scoped access while
/// preserving the ApplicationKit contract.
public struct PersistentFileBookmark: Sendable {
    public struct Resolution: Equatable, Sendable {
        public let url: URL
        public let bookmarkData: Data
        public let wasStale: Bool

        public init(
            url: URL,
            bookmarkData: Data,
            wasStale: Bool
        ) {
            self.url = url
            self.bookmarkData = bookmarkData
            self.wasStale = wasStale
        }
    }

    public init() {}

    public func make(for directory: URL) throws -> Data {
        let directory = directory.standardizedFileURL
        try Self.requireDirectory(directory)
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withoutImplicitSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        return try directory.bookmarkData(
            options: options,
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil)
    }

    public func resolve(_ bookmarkData: Data) throws -> Resolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
            .standardizedFileURL
        try Self.requireDirectory(url)
        return Resolution(
            url: url,
            bookmarkData: isStale ? try make(for: url) : bookmarkData,
            wasStale: isStale)
    }

    private static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else {
            throw PersistentFileBookmarkError.notDirectory
        }
        do {
            guard try url.resourceValues(
                forKeys: [.isDirectoryKey]).isDirectory == true
            else {
                throw PersistentFileBookmarkError.notDirectory
            }
        } catch {
            throw PersistentFileBookmarkError.notDirectory
        }
    }
}

public enum PersistentFileBookmarkError: Error, Equatable, Sendable {
    case notDirectory
}
