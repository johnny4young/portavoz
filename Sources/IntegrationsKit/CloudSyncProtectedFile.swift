import Darwin
import Foundation

/// Publishes private CloudKit transport bytes only after the complete file is
/// protected. A private sibling keeps partial writes reader-invisible; one
/// same-volume rename is the installation commit point.
enum CloudSyncProtectedFile {
    static func write(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).staging")
        defer { try? manager.removeItem(at: staging) }

        var descriptor = staging.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
        }

        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError()
        }
        let closeResult = Darwin.close(descriptor)
        let closeError = errno
        descriptor = -1
        guard closeResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: closeError) ?? .EIO)
        }

        try manager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.complete
            ],
            ofItemAtPath: staging.path)
        var protectedStaging = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedStaging.setResourceValues(values)

        let attributes = try manager.attributesOfItem(atPath: staging.path)
        guard (attributes[.size] as? NSNumber)?.intValue == data.count,
              attributes[.protectionKey] as? FileProtectionType == .complete
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try atomicRename(staging, to: destination)
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    throw posixError()
                }
            }
        }
    }

    private static func atomicRename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
