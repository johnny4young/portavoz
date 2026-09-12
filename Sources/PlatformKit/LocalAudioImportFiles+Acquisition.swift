import Darwin
import Foundation
import PortavozCore

extension LocalAudioImportFiles {
    public func withAcquisitionAccess<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // This content-free inode deliberately survives release. Unlinking
            // a held lock would let another process lock a different inode.
            let url = root.appendingPathComponent(".audio-import.lock")
            let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                                         mode_t(S_IRUSR | S_IWUSR))
            guard descriptor >= 0 else { throw AudioImportFileError.copyFailed }
            defer { _ = Darwin.close(descriptor) }
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw AudioImportFileError.copyFailed
            }
            guard audioImportBSDFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw AudioImportFileError.acquisitionBusy }
                throw AudioImportFileError.copyFailed
            }
            defer { _ = audioImportBSDFileLock(descriptor, LOCK_UN) }
            try Task.checkCancellation()
            return try await operation()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

// Darwin also imports struct flock. Bind the BSD operation explicitly, as in
// the existing backup and voice-identity leases, not process-scoped fcntl.
@_silgen_name("flock")
private func audioImportBSDFileLock(_ descriptor: CInt, _ operation: CInt) -> CInt
