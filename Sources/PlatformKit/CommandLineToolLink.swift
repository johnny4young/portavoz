import Foundation

/// A user-requested link that puts the app's bundled `portavoz-cli` on the
/// shell path. It only ever creates, replaces or removes a symbolic link; a
/// file or directory already at the destination is never touched, and shell
/// configuration is never edited.
public struct CommandLineToolLink: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// The destination links to this app's tool.
        case installed
        /// The destination links somewhere else, such as an older copy.
        case linkedElsewhere(String)
        /// A file or directory Portavoz did not create sits at the destination.
        case blocked
    }

    public enum LinkError: Error, Equatable {
        case toolMissing
        case destinationBlocked
        case notOurLink
    }

    public let tool: URL
    public let destination: URL

    public init(tool: URL, destination: URL) {
        self.tool = tool
        self.destination = destination
    }

    /// The tool inside `appBundle`, linked from `~/.local/bin`, a per-user
    /// directory that needs no administrator rights.
    public static func standard(appBundle: URL, home: URL) -> Self {
        Self(
            tool: appBundle.appendingPathComponent("Contents/Helpers/portavoz-cli"),
            destination: home.appendingPathComponent(".local/bin/portavoz-cli"))
    }

    public var toolExists: Bool {
        FileManager.default.isExecutableFile(atPath: tool.path)
    }

    public func state() -> State {
        let manager = FileManager.default
        if let target = try? manager.destinationOfSymbolicLink(atPath: destination.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent())
            return resolved.standardizedFileURL.path == tool.standardizedFileURL.path
                ? .installed : .linkedElsewhere(resolved.standardizedFileURL.path)
        }
        return manager.fileExists(atPath: destination.path) ? .blocked : .notInstalled
    }

    /// Creates the link, replacing only an existing symbolic link.
    public func install() throws {
        guard toolExists else { throw LinkError.toolMissing }
        let manager = FileManager.default
        switch state() {
        case .blocked:
            throw LinkError.destinationBlocked
        case .installed, .linkedElsewhere:
            try manager.removeItem(at: destination)
        case .notInstalled:
            break
        }
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: destination, withDestinationURL: tool)
    }

    /// Removes the link only when it points at this app's tool.
    public func remove() throws {
        guard state() == .installed else { throw LinkError.notOurLink }
        try FileManager.default.removeItem(at: destination)
    }
}
