import Darwin
import Foundation

/// Protects a private sibling before writing CloudKit transport bytes, then
/// publishes only the synchronized complete file. One same-volume rename is
/// the installation commit point.
enum CloudSyncProtectedFile {
    struct PublicationCapabilities: Equatable, Sendable {
        let completeProtection: Bool
        let backupExclusion: Bool
    }

    static func write(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let capabilities = try publicationCapabilities(in: directory)
        let staging = directory
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).staging")
        defer { unlink(staging) }

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

        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: staging.path)
        if capabilities.completeProtection {
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: staging.path)
        }
        if capabilities.backupExclusion {
            var protectedStaging = staging
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedStaging.setResourceValues(values)
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

        let attributes = try manager.attributesOfItem(atPath: staging.path)
        let isExcludedFromBackup: Bool? = if capabilities.backupExclusion {
            try staging.resourceValues(
                forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        } else {
            nil
        }
        guard (attributes[.size] as? NSNumber)?.intValue == data.count,
              (((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777)
                == 0o600,
              !capabilities.completeProtection
                || attributes[.protectionKey] as? FileProtectionType == .complete,
              !capabilities.backupExclusion
                || isExcludedFromBackup == true
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try atomicRename(staging, to: destination)
    }

    static func publicationCapabilities(
        in directory: URL
    ) throws -> PublicationCapabilities {
        let completeProtection = try probeMetadataSupport(in: directory) { probe in
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: probe.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: probe.path)
            guard attributes[.protectionKey] as? FileProtectionType == .complete else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let backupExclusion = try probeMetadataSupport(in: directory) { probe in
            var mutableProbe = probe
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableProbe.setResourceValues(values)
            guard try probe.resourceValues(
                forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return PublicationCapabilities(
            completeProtection: completeProtection,
            backupExclusion: backupExclusion)
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

    private static func probeMetadataSupport(
        in directory: URL,
        operation: (URL) throws -> Void
    ) throws -> Bool {
        let probe = directory.appendingPathComponent(
            ".portavoz-metadata-probe.\(UUID().uuidString.lowercased())")
        defer { unlink(probe) }

        let descriptor = probe.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw posixError() }
        let closeResult = Darwin.close(descriptor)
        guard closeResult == 0 else { throw posixError() }

        do {
            try operation(probe)
            return true
        } catch where isUnsupportedMetadataError(error) {
            return false
        }
    }

    static func isUnsupportedMetadataError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain,
           cocoaError.code == Int(EINVAL) || cocoaError.code == Int(ENOTSUP) {
            return true
        }
        guard let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isUnsupportedMetadataError(underlying)
    }

    private static func unlink(_ url: URL) {
        _ = url.path.withCString { Darwin.unlink($0) }
    }
}
