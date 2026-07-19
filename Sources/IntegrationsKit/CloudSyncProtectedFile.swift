import Darwin
import Foundation

/// Publishes private CloudKit transport bytes only after the complete file is
/// protected. A sibling staging file keeps partial writes reader-invisible;
/// one same-volume rename is the installation commit point.
enum CloudSyncProtectedFile {
    static func write(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).staging")
        defer { try? manager.removeItem(at: staging) }

        try Data().write(to: staging, options: .withoutOverwriting)
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

        let handle = try FileHandle(forWritingTo: staging)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let attributes = try manager.attributesOfItem(atPath: staging.path)
        guard (attributes[.size] as? NSNumber)?.intValue == data.count,
              attributes[.protectionKey] as? FileProtectionType == .complete
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try atomicRename(staging, to: destination)
    }

    private static func atomicRename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
