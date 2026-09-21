import CryptoKit
import Foundation
import PortavozCore

struct AudioImportSourceMetadata: Equatable {
    let size: Int64
    let modifiedAt: Date

    static func read(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw AudioImportFileError.invalidSource }
        // Resource-value caches on a reused URL can conceal source mutation.
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
              let modified = values.contentModificationDate, modified.timeIntervalSince1970.isFinite else {
            throw AudioImportFileError.invalidSource
        }
        return Self(size: Int64(size), modifiedAt: modified)
    }

    func matches(_ input: AudioImportRequest) -> Bool {
        size == input.sourceByteCount && modifiedAt == input.sourceModifiedAt
    }
}

enum AudioImportFileTransfer {
    static func copy(from source: URL, to destination: URL, expectedSize: Int64) throws -> String {
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw AudioImportFileError.destinationOccupied
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let hash = try read(source, expectedSize: expectedSize) { try output.write(contentsOf: $0) }
        try output.synchronize()
        try output.close()
        // Read back the actual destination, not just the bytes offered to it.
        guard try digest(destination, expectedSize: expectedSize) == hash else { throw AudioImportFileError.copyFailed }
        return hash
    }

    static func digest(_ url: URL, expectedSize: Int64) throws -> String {
        try read(url, expectedSize: expectedSize) { _ in }
    }

    private static func read(_ url: URL, expectedSize: Int64, consume: (Data) throws -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let hasData = try autoreleasepool { () throws -> Bool in
                guard let data = try input.read(upToCount: 256 * 1_024), !data.isEmpty else { return false }
                guard Int64(data.count) <= expectedSize - count else { throw AudioImportFileError.sourceChanged }
                try consume(data)
                hash.update(data: data)
                count += Int64(data.count)
                return true
            }
            if !hasData { break }
        }
        guard count == expectedSize else { throw AudioImportFileError.sourceChanged }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
