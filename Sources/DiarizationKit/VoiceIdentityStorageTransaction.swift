import Darwin
import Foundation

/// Serializes one encrypted identity file across store values and processes.
/// The sidecar contains no identity data and intentionally survives deletion
/// of the encrypted payload so a reset and a concurrent save cannot cross.
enum VoiceIdentityStorageTransaction {
    static func withExclusiveAccess<Result>(
        to fileURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let lockURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("lock")
        let lease = try VoiceIdentityStorageLease.acquire(at: lockURL)
        return try withExtendedLifetime(lease) {
            try operation()
        }
    }
}

private final class VoiceIdentityStorageLease {
    private let fileDescriptor: CInt

    private init(fileDescriptor: CInt) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = portavozVoiceIdentityBSDFileLock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }

    static func acquire(at url: URL) throws -> VoiceIdentityStorageLease {
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw posixError(errno)
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw posixError(code)
        }

        while portavozVoiceIdentityBSDFileLock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            _ = Darwin.close(descriptor)
            throw posixError(code)
        }
        return VoiceIdentityStorageLease(fileDescriptor: descriptor)
    }

    private static func posixError(_ code: CInt) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Darwin imports `struct flock` under the same Swift name as `flock(2)`.
/// Bind the BSD symbol explicitly to retain open-file-description semantics.
@_silgen_name("flock")
private func portavozVoiceIdentityBSDFileLock(
    _ fileDescriptor: CInt,
    _ operation: CInt
) -> CInt
