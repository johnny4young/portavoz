import ApplicationKit
import Darwin
import Foundation

/// File access belongs to the selected document, never a path inside the JSON.
enum PortableSettingsFile {
    static func read(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw PortableSettingsFailure.invalidFile
        }
        let maximum = PortableSettingsValidation.maximumFileBytes
        guard attributes.st_size <= maximum else { throw PortableSettingsFailure.tooLarge }
        var data = Data()
        while data.count <= maximum {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw PortableSettingsFailure.tooLarge
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= PortableSettingsValidation.maximumFileBytes else { throw PortableSettingsFailure.tooLarge }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Same-directory staging makes publication atomic; mkdtemp creates a
        // private directory before any user vocabulary bytes are written.
        let template = url.deletingLastPathComponent().appendingPathComponent(".portavoz-settings.XXXXXX").path
        var characters = Array(template.utf8CString)
        let directory = try characters.withUnsafeMutableBufferPointer { buffer in
            guard let start = buffer.baseAddress, let path = mkdtemp(start) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("settings.json")
        try data.write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        try Task.checkCancellation()
        guard Darwin.rename(staged.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
