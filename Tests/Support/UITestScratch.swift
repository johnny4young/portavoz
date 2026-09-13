import Darwin
import Foundation

/// Synthetic data shared by the UI runner and app must not inherit either
/// process's protected app container. Ownership is created atomically, not
/// inferred from a caller-supplied directory name during cleanup.
struct UITestScratch: Sendable {
    enum Failure: Error, Equatable {
        case allocation(Int32)
        case inspection(Int32)
        case ownershipChanged
        case unsafeSharedBase
    }

    let url: URL
    private let identity: Identity

    static let sharedBase = URL(fileURLWithPath: "/private/tmp/portavoz-ui-tests", isDirectory: true)

    init(parent: URL? = nil) throws {
        let parent = try parent ?? Self.prepareSharedBase(at: Self.sharedBase)
        var template = Array(parent.appendingPathComponent("portavoz-ui-XXXXXX").path.utf8CString)
        let path = try template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, let created = mkdtemp(base) else {
                throw Failure.allocation(errno)
            }
            return String(cString: created)
        }
        url = URL(fileURLWithPath: path, isDirectory: true)
        var information = stat()
        guard lstat(path, &information) == 0 else { throw Failure.inspection(errno) }
        identity = Identity(information)
    }

    static func prepareSharedBase(at url: URL) throws -> URL {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw Failure.allocation(errno) }
        var information = stat()
        guard lstat(url.path, &information) == 0 else { throw Failure.inspection(errno) }
        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & 0o777 == 0o700,
              information.st_uid == getuid() else { throw Failure.unsafeSharedBase }
        return url
    }

    func remove() throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return }
            throw Failure.inspection(errno)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              Identity(information) == identity else { throw Failure.ownershipChanged }
        try FileManager.default.removeItem(at: url)
    }

    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
            owner = information.st_uid
        }
    }
}
